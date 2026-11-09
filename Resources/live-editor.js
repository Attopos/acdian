import { EditorState, EditorSelection, StateField, StateEffect, Compartment, Transaction, findClusterBreak } from '@codemirror/state';
import { EditorView, ViewPlugin, Decoration, WidgetType, keymap, placeholder, drawSelection } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { markdown, markdownKeymap } from '@codemirror/lang-markdown';
import { syntaxTree, ensureSyntaxTree, syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
import { GFM } from '@lezer/markdown';
import { slashCommands } from './slash-commands.js';
import { formatToolbar } from './format-toolbar.js';
import { markdownInput } from './markdown-input.js';
import { editorLanguage, normalizeLanguage, messagesForLanguage, uiText } from './ui-language.js';
import { tableDecorations, tableKeymap, tableSelectionFilter } from './rich-table.js';
import { configureRichText, codeLanguages, codeHighlight, codeTools, inlineHTML, safeBlockStyle, MermaidWidget, folding, startFolded, frameImage, parseEmbed, imageWidthless, InlineImageWidget, CalloutIconWidget, calloutHeader, TocWidget, keepWords, wordRanges } from './rich-text.js';

const metadata = { currentPath: '', documentID: '', tabID: '', title: '', pageTitle: '', editable: true, resetToken: null, language:'en' };
// Every message names the document it came from, so the native side can drop
// a late message from a page that has since been swapped out of the editor.
const post = message => window.webkit?.messageHandlers?.acdian?.postMessage({...message,documentID:metadata.documentID});
let rawSource = '', lastSource = '', lineBreak = '\n', applyingExternal = false, revision = 0;
const insertions = new Set();
let rawSnapshots = new Map();
const editability = new Compartment();
const localization = new Compartment();
// A saved page's title is its file name, in a block of its own above the text.
// It scrolls with the page but is not part of the document, so a page always
// has one and the file holds only the text. Return goes on to the text; leaving
// the block renames the file, and an empty title goes back to the file name.
const titleBlock=document.createElement('h1');
titleBlock.className='cm-page-title';titleBlock.spellcheck=false;
const typedTitle=()=>titleBlock.textContent.replace(/\s+/g,' ').trim();
function showTitle(force){
  if(force||document.activeElement!==titleBlock)titleBlock.textContent=metadata.pageTitle;
  titleBlock.hidden=!metadata.pageTitle;
  titleBlock.contentEditable=metadata.editable?'plaintext-only':'false';
}
function intoText(){view.focus();view.dispatch({selection:{anchor:0},scrollIntoView:true});}
function intoTitle(view){
  const range=view.state.selection.main;
  if(!metadata.pageTitle||!range.empty||view.coordsAtPos(range.head)?.top!==view.coordsAtPos(0)?.top)return false;
  titleBlock.focus();
  const caret=getSelection();caret.selectAllChildren(titleBlock);caret.collapseToEnd();
  return true;
}
titleBlock.addEventListener('keydown',event=>{
  if(event.isComposing)return;
  if(event.key==='Enter'){event.preventDefault();intoText();}
  else if(event.key==='Escape'){event.preventDefault();titleBlock.textContent=metadata.pageTitle;post({type:'titleTyped',title:metadata.pageTitle,currentPath:metadata.currentPath});intoText();}
  else if(event.key==='ArrowDown'){const caret=getSelection();if(caret.isCollapsed&&caret.anchorOffset===(caret.anchorNode?.textContent.length??0)&&!event.shiftKey){event.preventDefault();intoText();}}
});
titleBlock.addEventListener('input',()=>post({type:'titleTyped',title:typedTitle(),currentPath:metadata.currentPath}));
titleBlock.addEventListener('blur',()=>{if(!typedTitle())titleBlock.textContent=metadata.pageTitle;post({type:'titleEnded',currentPath:metadata.currentPath});});
const localeExtensions=()=>{
  const strings=messagesForLanguage(metadata.language);
  return [editorLanguage.of(metadata.language),placeholder(strings.placeholder),EditorView.contentAttributes.of({lang:metadata.language,'aria-label':strings.editorLabel})];
};
const isImageTarget = target => /\.(?:png|jpe?g|gif|webp|svg|avif|bmp|heic|tiff?)(?:#|$)/i.test(target);
const escapeHTML = text => String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const decode = text => { try { return decodeURIComponent(text); } catch { return text; } };
const canonical = text => text.replace(/\r\n|\r/g, '\n');

function rawOffset(source, pos) {
  let index = 0, count = 0;
  while (index < source.length && count < pos) {
    if (source[index] === '\r' && source[index + 1] === '\n') index++;
    index++; count++;
  }
  return index;
}
function applyRawChanges(transaction) {
  // A note with plain \n line breaks is its own raw text: no offsets to
  // translate and no snapshots to keep, so typing costs the same in any length.
  if(!rawSource.includes('\r')&&lineBreak==='\n'){
    let result='',end=0;
    transaction.changes.iterChanges((from,to,_newFrom,_newTo,inserted)=>{result+=rawSource.slice(end,from)+inserted.toString();end=to;});
    rawSource=result+rawSource.slice(end);return;
  }
  const snapshot=rawSnapshots.get(transaction.newDoc.toString());
  if((transaction.isUserEvent('undo')||transaction.isUserEvent('redo'))&&snapshot!==undefined){rawSource=snapshot;return;}
  const source = rawSource; let result = '', end = 0;
  transaction.changes.iterChanges((from, to, _newFrom, _newTo, inserted) => {
    const start = rawOffset(source, from), stop = rawOffset(source, to);
    result += source.slice(end, start) + inserted.toString().replace(/\n/g, lineBreak); end = stop;
  });
  rawSource = result + source.slice(end);
  rawSnapshots.set(transaction.newDoc.toString(),rawSource);
  if(rawSnapshots.size>200)rawSnapshots.delete(rawSnapshots.keys().next().value);
}
function resourceURL(target) {
  if (/^https?:\/\//i.test(target)) return target;
  if (/^data:image\/(?:png|jpe?g|gif|webp|avif);/i.test(target)) return target;
  if (/^[a-z][a-z\d+.-]*:/i.test(target)) return '';
  const [path, ...anchor] = target.split('#');
  return `acdian-resource://vault/${encodeURIComponent(decode(path))}?from=${encodeURIComponent(metadata.currentPath)}${anchor.length ? '#' + anchor.join('#') : ''}`;
}
function navigate(target) {
  if (target.startsWith('#')) { window.acdianScrollTo(target); return; }
  if (/^(?:https?:|mailto:)/i.test(target)) post({type:'external',target,from:metadata.currentPath});
  else if (!/^[a-z][a-z\d+.-]*:/i.test(target)) post({type:'navigate',target,from:metadata.currentPath});
}

// Width of source text in ems of the editor font, where a tab reaches the next
// stop of four spaces. Line decorations turn this into a hanging indent, so it
// has to be known before the line is drawn. It is measured at the current size
// because the system font's spacing changes with size.
const sourceEms=new Map();
let measureContext;
function textEms(text) {
  const size=parseFloat(document.documentElement.style.getPropertyValue('--editor-font-size'))||16,key=size+'|'+text;
  if(sourceEms.has(key))return sourceEms.get(key);
  measureContext??=document.createElement('canvas').getContext('2d');
  const expanded=text.replace(/ {0,3}\t/g,'    ');
  if(measureContext)measureContext.font=size+'px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif';
  const ems=measureContext?measureContext.measureText(expanded).width/size:expanded.length*.25;
  sourceEms.set(key,ems);return ems;
}
function listLineStyle(hang,marker) {
  return `--cm-list-hang:${hang.toFixed(3)}em`+(marker?`;--cm-list-marker:${marker.toFixed(3)}em`:'');
}

class BulletWidget extends WidgetType {
  constructor(label) { super(); this.label = label; }
  eq(other) { return this.label === other.label; }
  toDOM() { const span = document.createElement('span'); span.className = 'cm-list-bullet'; span.textContent = this.label; span.setAttribute('aria-hidden','true'); return span; }
}
class TaskWidget extends WidgetType {
  constructor(from, checked, language) { super(); Object.assign(this,{from,checked,language}); }
  eq(other) { return this.from === other.from && this.checked === other.checked && this.language===other.language; }
  toDOM(view) {
    const span = document.createElement('span'); span.className = 'cm-task-widget';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = this.checked; checkbox.disabled = !metadata.editable; checkbox.setAttribute('aria-label',uiText(view.state,'completeTask'));
    checkbox.addEventListener('mousedown', event => event.stopPropagation());
    checkbox.addEventListener('change', () => {
      if (!metadata.editable) return;
      const line = view.state.doc.lineAt(Math.min(this.from,view.state.doc.length));
      const match = /^\s*[-+*]\s+\[([ xX])\]/.exec(line.text);
      if (match) { const pos = line.from + match[0].lastIndexOf('[') + 1; view.dispatch({changes:{from:pos,to:pos+1,insert:checkbox.checked?'x':' '},userEvent:'input'}); }
    });
    span.append(checkbox); return span;
  }
  ignoreEvent() { return true; }
}

function fragment(source,state,kind='') {
  const html=kind==='html';
  const holder = document.createElement('div'); holder.className = 'markdown-body cm-rendered-content';
  let prepared = source.replace(/!\[\[([^\]\n]+)\]\]/g, (_,value) => {
    const {target,width,caption} = parseEmbed(value),alias = caption;
    if (/\.pdf(?:#|$)/i.test(target)) return `<a data-live-target="${escapeHTML(target)}">PDF · ${escapeHTML(alias || target.split('/').pop())} ↗</a>`;
    if (isImageTarget(target)) return `<img data-live-resource="${escapeHTML(target)}" alt="${escapeHTML(caption)}"${width?` width="${width}"`:''}>`;
    return `<a data-live-target="${escapeHTML(target)}">${escapeHTML(alias||target)}</a>`;
  }).replace(/\[\[([^\]\n]+)\]\]/g, (_,value) => {
    const [target,alias] = value.split('|'); return `<a data-live-target="${escapeHTML(target)}">${escapeHTML(alias||target)}</a>`;
  });
  // In an HTML block Markdown and formulas still work inside the tags.
  if(html) prepared = prepared
    .replace(/(?<!\\)\$\$([\s\S]+?)\$\$|(?<![\\$\d])\$(?![\s$])([^$\n]+?)(?<![\s\\])\$(?![$\d])/g,(_,display,inline)=>`<span data-tex="${escapeHTML(display??inline)}"${display===undefined?'':' data-display="1"'}></span>`)
    .replace(/(<\/summary>)[ \t]*\n?/gi,'$1\n\n').replace(/\n?[ \t]*(<\/details>)/gi,'\n\n$1');
  holder.innerHTML = DOMPurify.sanitize(marked.parse(prepared,{gfm:true}), {USE_PROFILES:{html:true},FORBID_TAGS:['script','style','iframe','object','embed','form','input'],FORBID_ATTR:html?['srcset']:['style','srcset'],ALLOW_DATA_ATTR:true});
  if(html) {
    holder.querySelectorAll('[style]').forEach(element => { const style=safeBlockStyle(element.getAttribute('style')); if(style)element.setAttribute('style',style); else element.removeAttribute('style'); });
    holder.querySelectorAll('[data-tex]').forEach(element => { try { katex.render(element.dataset.tex,element,{displayMode:!!element.dataset.display,throwOnError:false,trust:false}); } catch { element.textContent=element.dataset.tex; } });
  }
  holder.querySelectorAll('img').forEach(image => {
    const target = image.dataset.liveResource || image.getAttribute('src') || '';
    if(/\.pdf(?:#|$)/i.test(target)){const link=document.createElement('a');link.dataset.liveTarget=target;link.textContent='PDF · '+(image.alt||target.split('/').pop())+' ↗';image.replaceWith(link);return;}
    const url = resourceURL(target); image.removeAttribute('src');
    // ![caption|300](file) gives a width too, as ![[file|300]] does.
    const sized=/^(.*?)\|?(\d+)(?:x\d+)?$/.exec(image.alt);
    if(sized&&!image.getAttribute('width')){image.alt=sized[1];image.width=Math.min(3000,Number(sized[2]));}
    if(!image.dataset.liveResource)image.dataset.liveResource=target;
    if (url) {
      image.src = url; image.loading = 'lazy';
      // Text given with a picture is its caption.
      const caption=image.alt&&!html?document.createElement('span'):null;
      if (kind==='image') frameImage(image,state);
      if (caption) { caption.className='cm-image-caption'; caption.textContent=image.alt; (image.closest('.cm-image-frame')||image).after(caption); }
    }
    else image.replaceWith(document.createTextNode(image.alt));
  });
  holder.querySelectorAll('a').forEach(link => { const target = link.dataset.liveTarget || link.getAttribute('href'); link.href='#'; link.title=uiText(state,'openLinkShort'); link.addEventListener('click',event=>{event.preventDefault(); navigate(target||'');}); });
  const quote = holder.querySelector('blockquote');
  if (quote && /^>\s*\[!/.test(source)) {
    quote.className='callout';
    const first = quote.querySelector('p');
    if(first) first.innerHTML = first.innerHTML.replace(/^\[!([^\]]+)\][+-]?(?:[ \t]*([^\n]*))?/,(_,kind,title)=>`<strong class="callout-title">✦ ${escapeHTML(title||kind)}</strong>`);
  }
  return holder;
}
// CodeMirror measures a block widget by its border box, so a margin on it is
// invisible to the height map and every line below lands lower than CodeMirror
// thinks: clicks then hit the next line. The space around a block is padding on
// a plain wrapper instead.
function spacedBlock(holder) { const wrap=document.createElement('div'); wrap.className='cm-live-block-wrap'; wrap.append(holder); return wrap; }
class BlockWidget extends WidgetType {
  constructor(source,from,kind,language,selected=false) { super(); Object.assign(this,{source,from,kind,language,selected}); }
  // The position is read from the DOM when needed, so text typed above the
  // block moves it without redrawing it.
  eq(other) { return this.source===other.source && this.kind===other.kind && this.language===other.language && this.selected===other.selected; }
  toDOM(view) {
    const holder=document.createElement('div'); holder.className='cm-live-block cm-block-'+this.kind+(this.selected?' cm-block-selected':'');
    if(this.kind==='math') {
      // Formulas written back to back, $$a$$$$b$$, are separate display formulas.
      for(const tex of this.source.trim().replace(/^\$\$\s*|\s*\$\$$/g,'').split(/\s*\$\$\s*\$\$\s*/)) {
        const math=document.createElement('div'); try { katex.render(tex,math,{displayMode:true,throwOnError:false,trust:false}); } catch {math.textContent=tex;} holder.append(math);
      }
    }
    else holder.append(fragment(this.source,view.state,this.kind));
    holder.dataset.source=this.source;
    if(this.kind!=='image') {
      holder.title=uiText(view.state,'doubleClickEdit');
      holder.addEventListener('dblclick',event=>{ if(!metadata.editable)return; event.preventDefault(); view.dispatch({selection:{anchor:view.posAtDOM(holder)+1}}); view.focus(); });
    }
    holder.addEventListener('mousedown',event=>{
      // A link inside the block opens on click instead of selecting the block,
      // and a folding block keeps its place when opened or closed.
      if(event.metaKey||event.ctrlKey||!metadata.editable||event.target.closest?.('a,details')) return;
      const from=view.posAtDOM(holder);
      event.preventDefault(); view.dispatch({selection:{anchor:from,head:Math.min(from+this.source.length,view.state.doc.length)}}); view.focus();
    }); return spacedBlock(holder);
  }
  // Being selected, or a new width, changes the block in place, so its picture
  // does not load again and a drag can go on.
  updateDOM(dom) {
    const holder=dom.querySelector?.('.cm-live-block');
    if(!holder||!holder.classList.contains('cm-block-'+this.kind))return false;
    const old=holder.dataset.source??'';
    if(old!==this.source&&(this.kind!=='image'||imageWidthless(old)!==imageWidthless(this.source)))return false;
    holder.classList.toggle('cm-block-selected',this.selected);
    if(old!==this.source) {
      const image=holder.querySelector('img'),width=/\|(\d+)(?:x\d+)?(?=\]\]|\]\()/.exec(this.source)?.[1];
      if(image){image.style.width='';if(width)image.width=Number(width);else image.removeAttribute('width');}
      holder.dataset.source=this.source;
    }
    return true;
  }
  ignoreEvent() { return true; }
}

// An acdian-interactive block runs its HTML in a sandboxed frame: scripts only,
// no same origin, and the frame's own policy blocks the network. The frame is
// rebuilt only when the block's source changes, never as text moves around it.
const interactiveFrameURL='acdian-resource://interactive/frame.html';
const currentAppearance=()=>document.documentElement.classList.contains('light')?'light':'dark';
function interactiveInfo(state,node) {
  const info=node.node.getChild('CodeInfo');
  if(!info)return null;
  const words=state.doc.sliceString(info.from,info.to).trim().split(/\s+/);
  if(words[0]!=='acdian-interactive')return null;
  const height=/^height=(\d+)$/.exec(words.find(word=>/^height=/.test(word))||'');
  return {height:height?Math.max(60,Math.min(1600,Number(height[1]))):0};
}
class InteractiveWidget extends WidgetType {
  constructor(code,height,language) { super(); Object.assign(this,{code,height,language}); }
  eq(other) { return this.code===other.code&&this.height===other.height&&this.language===other.language; }
  get estimatedHeight() { return (this.height||240)+36+16; }
  toDOM(view) {
    const holder=document.createElement('div');holder.className='cm-live-block cm-block-interactive';
    const bar=document.createElement('div');bar.className='cm-interactive-bar';
    const label=document.createElement('span');label.className='cm-interactive-label';label.textContent='✦ '+uiText(view.state,'interactive');
    const button=(text,action)=>{const element=document.createElement('button');element.type='button';element.textContent=text;element.addEventListener('mousedown',event=>event.preventDefault());element.addEventListener('click',event=>{event.preventDefault();action();});return element;};
    const frame=document.createElement('iframe');frame.className='cm-interactive-frame';
    frame.setAttribute('sandbox','allow-scripts');frame.setAttribute('referrerpolicy','no-referrer');frame.title=uiText(view.state,'interactive');
    if(this.height){frame.dataset.fixedHeight='true';frame.style.height=this.height+'px';}
    frame.addEventListener('load',()=>frame.contentWindow?.postMessage({type:'acdian-interactive:run',source:this.code,theme:currentAppearance(),language:metadata.language},'*'));
    frame.src=interactiveFrameURL;
    const rerun=button(uiText(view.state,'rerun'),()=>{frame.src='about:blank';requestAnimationFrame(()=>{frame.src=interactiveFrameURL;});});
    // Editing puts the caret inside the block, which then shows its source.
    const source=button(uiText(view.state,'editSource'),()=>{
      if(!metadata.editable)return;
      const pos=view.posAtDOM(holder),line=view.state.doc.lineAt(pos);
      const target=line.number<view.state.doc.lines?view.state.doc.line(line.number+1).to:line.to;
      view.dispatch({selection:EditorSelection.cursor(target),scrollIntoView:true});view.focus();
    });
    bar.append(label,rerun,source);holder.append(bar,frame);
    return spacedBlock(holder);
  }
  ignoreEvent() { return true; }
}
const interactiveFrames=()=>document.querySelectorAll('iframe.cm-interactive-frame');
window.addEventListener('message',event=>{
  if(event.data?.type!=='acdian-interactive:size')return;
  for(const frame of interactiveFrames()) {
    if(frame.contentWindow!==event.source||frame.dataset.fixedHeight)continue;
    const height=Math.max(60,Math.min(1600,Math.ceil(Number(event.data.height)||0)));
    if(Math.abs(height-frame.offsetHeight)>1){frame.style.height=height+'px';window.acdianEditor?.requestMeasure();}
  }
});
new MutationObserver(()=>{const theme=currentAppearance();for(const frame of interactiveFrames())frame.contentWindow?.postMessage({type:'acdian-interactive:theme',theme},'*');}).observe(document.documentElement,{attributes:true,attributeFilter:['class']});

// The last line of the HTML block that starts on line n, or 0 if none does. The
// tags are matched up, so a block may hold blank lines and Markdown.
function htmlBlockEnd(doc,n) {
  const text=doc.line(n).text;
  if(/^\s*<img\b[^<>]*>\s*$/i.test(text))return n;
  const name=/^\s*<(details|table|div|center|figure|aside|section|dl)\b/i.exec(text)?.[1];
  if(!name)return 0;
  const tag=new RegExp('<(/?)'+name+'\\b[^<>]*>','gi');
  let depth=0;
  for(let end=n;end<=doc.lines;end++) {
    for(const match of doc.line(end).text.matchAll(tag))depth+=match[1]?-1:1;
    if(depth<=0)return end;
  }
  return 0;
}
const calloutGroups={idea:['idea'],info:['info','todo','abstract','summary','tldr'],tip:['tip','hint','important','success','check','done'],warning:['warning','caution','attention'],danger:['danger','error','bug','failure','fail','missing'],question:['question','help','faq'],quote:['quote','cite','example']};
const calloutIcons={note:'📝',idea:'💡',info:'ℹ️',tip:'✅',warning:'⚠️',danger:'❗',question:'❓',quote:'💬'};
const calloutGroup=kind=>Object.keys(calloutGroups).find(group=>calloutGroups[group].includes(kind.toLowerCase()))||'note';
// The last line of the display formula that starts on line n, or 0 if none does.
// The closing $$ may share a line with the formula, on either side, and formulas
// may follow each other on one line. A formula never spans a blank line, so a
// stray $$ stays plain text instead of swallowing the page down to the next one.
function mathBlockEnd(doc,n) {
  const marks=text=>[...text.matchAll(/(?<!\\)\$\$/g)].map(match=>match.index);
  const first=doc.line(n).text,at=marks(first);
  for(let i=1;i+1<at.length;i+=2)if(first.slice(at[i]+2,at[i+1]).trim())return 0;
  if(at.length%2===0)return first.slice(at[at.length-1]+2).trim()||!first.slice(at[0]+2,at[1]).trim()?0:n;
  for(let end=n+1;end<=doc.lines;end++) {
    const text=doc.line(end).text,close=marks(text);
    if(!text.trim())return 0;
    if(close.length)return close.length===1&&!text.slice(close[0]+2).trim()?end:0;
  }
  return 0;
}
class FootnoteWidget extends WidgetType {
  constructor(label) { super(); this.label=label; }
  eq(other) { return this.label===other.label; }
  toDOM(view) {
    const mark=document.createElement('sup'); mark.className='cm-footnote-mark'; mark.textContent=this.label;
    mark.addEventListener('mousedown',event=>{
      event.preventDefault();
      const key='[^'+this.label+']:';
      for(let n=1;n<=view.state.doc.lines;n++){const line=view.state.doc.line(n);if(line.text.startsWith(key)){view.dispatch({selection:{anchor:line.to},scrollIntoView:true});view.focus();return;}}
    });
    return mark;
  }
  ignoreEvent() { return true; }
}
class InlineMathWidget extends WidgetType {
  constructor(tex) { super(); this.tex=tex; }
  eq(other) { return other.tex===this.tex; }
  toDOM() { const span=document.createElement('span'); span.className='cm-inline-math'; try { katex.render(this.tex,span,{throwOnError:false,trust:false}); } catch { span.textContent='$'+this.tex+'$'; } return span; }
  ignoreEvent() { return false; }
}
class HeadingHintWidget extends WidgetType {
  constructor(level) { super(); this.level = level; }
  eq(other) { return this.level === other.level; }
  toDOM() { const span = document.createElement('span'); span.className = 'cm-heading-hint'; span.textContent = 'H' + this.level; span.setAttribute('aria-hidden','true'); return span; }
  ignoreEvent() { return false; }
}
class DividerWidget extends WidgetType {
  constructor(from,to,language) { super(); Object.assign(this,{from,to,language}); }
  eq(other) { return this.from===other.from&&this.to===other.to&&this.language===other.language; }
  toDOM(view) {
    const holder=document.createElement('span');holder.className='cm-live-divider';holder.setAttribute('role','separator');holder.setAttribute('aria-label',uiText(view.state,'divider'));
    holder.append(document.createElement('hr'));
    holder.addEventListener('mousedown',event=>{
      if(!metadata.editable)return;
      event.preventDefault();
      view.dispatch({selection:EditorSelection.cursor(Math.min(this.to,view.state.doc.length))});view.focus();
    });
    return holder;
  }
  ignoreEvent() { return true; }
}

// Stops at the first text, so a long note costs nothing here.
function blankDocument(doc) { for(const iter=doc.iter();!iter.next().done;)if(iter.value.trim())return false; return true; }

// A long note is decorated only near the screen. Line and inline decorations
// (lists, headings, bold, links, blank lines) cost time for every line they
// cover, so they are built for the window around the viewport and around the
// caret; blocks that change height (formulas, images, interactive blocks) are
// found in the whole note, so the scroll height and jumps stay right far away.
const WINDOW_LINES=300, WINDOW_SLACK=100, CARET_LINES=60;
const setWindow=StateEffect.define();
const windowField=StateField.define({
  create:state=>({from:0,to:state.doc.line(Math.min(state.doc.lines,2*WINDOW_LINES)).to}),
  update(value,tr) {
    for(const effect of tr.effects)if(effect.is(setWindow))return effect.value;
    return tr.docChanged?{from:tr.changes.mapPos(value.from,-1),to:tr.changes.mapPos(value.to,1)}:value;
  }
});
// The ranges to decorate: the window, plus the lines around each selection
// end, each widened to whole top-level blocks so a list, quote or table is
// never cut in half; overlapping ranges are merged.
function decorationRanges(state) {
  const doc=state.doc,tree=syntaxTree(state),ranges=[];
  const around=pos=>{const n=doc.lineAt(pos).number;return [doc.line(Math.max(1,n-CARET_LINES)).from,doc.line(Math.min(doc.lines,n+CARET_LINES)).to];};
  const window=state.field(windowField,false);
  ranges.push(window?[Math.min(window.from,doc.length),Math.min(window.to,doc.length)]:[0,doc.length]);
  for(const range of state.selection.ranges){ranges.push(around(range.head));if(range.anchor!==range.head)ranges.push(around(range.anchor));}
  const topLevel=(pos,side)=>{let node=tree.resolve(pos,side);while(node.parent&&node.parent.parent)node=node.parent;return node.parent?node:null;};
  for(const range of ranges){const first=topLevel(range[0],1),last=topLevel(range[1],-1);if(first)range[0]=Math.min(range[0],doc.lineAt(first.from).from);if(last)range[1]=Math.max(range[1],doc.lineAt(last.to).to);}
  ranges.sort((a,b)=>a[0]-b[0]);
  const merged=[];
  for(const range of ranges){const top=merged.at(-1);if(top&&range[0]<=top[1]+1)top[1]=Math.max(top[1],range[1]);else merged.push([...range]);}
  return merged;
}
// After the viewport moves near the edge of the window, a new window is set
// around it. It goes out in a microtask, before the next paint.
const windowTracker=ViewPlugin.fromClass(class {
  constructor(view){this.view=view;this.queued=false;this.schedule();}
  update(update){if(update.viewportChanged||update.docChanged)this.schedule();}
  schedule() {
    if(this.queued)return;this.queued=true;
    queueMicrotask(()=>{
      this.queued=false;const view=this.view,doc=view.state.doc,current=view.state.field(windowField,false);
      if(!current||!view.dom.isConnected)return;
      const first=doc.lineAt(Math.min(view.viewport.from,doc.length)).number,last=doc.lineAt(Math.min(view.viewport.to,doc.length)).number;
      if(current.from<=doc.line(Math.max(1,first-WINDOW_SLACK)).from&&current.to>=doc.line(Math.min(doc.lines,last+WINDOW_SLACK)).to)return;
      view.dispatch({effects:setWindow.of({from:doc.line(Math.max(1,first-WINDOW_LINES)).from,to:doc.line(Math.min(doc.lines,last+WINDOW_LINES)).to})});
    });
  }
});
const inRanges=(ranges,from,to=from)=>ranges.some(([a,b])=>from<=b&&to>=a);

// Markdown's separator lines have no visual paragraph of their own. A newly
// created empty paragraph remains available for typing until the caret leaves.
const inputBlankField=StateField.define({
  create:state=>blankDocument(state.doc)?state.doc.lineAt(state.selection.main.head).from:null,
  update(value,tr) {
    const range=tr.state.selection.main,line=tr.state.doc.lineAt(range.head);
    if(!range.empty||line.text.trim())return null;
    if(tr.docChanged||blankDocument(tr.state.doc))return line.from;
    const mapped=value===null?null:tr.changes.mapPos(value,1);
    return mapped===line.from?mapped:null;
  }
});
function editableBlank(state,line) {
  const selection=state.selection.main;
  return state.field(inputBlankField)===line.from||line.number===state.doc.lines&&selection.empty&&selection.head>=line.from;
}
// Markdown needs one blank line between blocks, and that separator stays
// hidden. Every further blank line in a run is an empty line the writer left
// on purpose, so it keeps the height of a line: in a run, all but the last
// show. Runs before the first or after the last text stay hidden.
function keptBlank(state,line) {
  const doc=state.doc;
  if(line.text.trim()||line.number>=doc.lines||doc.line(line.number+1).text.trim())return false;
  let next=line.number+1;while(next<=doc.lines&&!doc.line(next).text.trim())next++;
  if(next>doc.lines)return false;
  let prev=line.number-1;while(prev>=1&&!doc.line(prev).text.trim())prev--;
  return prev>=1;
}
// Two Enters leave an empty line. When text is typed into a blank line, the
// blank lines just above it would become Markdown's hidden separator, and a
// list item, quote or table right above would take the text in as its own.
// Either way one more newline above keeps what the writer saw: the empty
// line stays, and the new text starts its own paragraph.
function needsSeparatorAbove(state,number) {
  if(number<=1)return false;
  const above=state.doc.line(number-1);
  if(above.text.trim())return /^\s*(?:[-+*]\s|\d+[.)]\s|>|\|)/.test(above.text)&&!literalCodeLine(state,above);
  let n=number-1;while(n>=1&&!state.doc.line(n).text.trim())n--;
  return n>=1&&!literalCodeLine(state,state.doc.line(n));
}
// The position, in the transaction's new document, where that newline goes:
// the transaction must type text into a line that was blank.
function typedIntoBlank(tr) {
  if(!tr.docChanged||tr.startState.selection.ranges.length!==1)return null;
  let found=null,count=0;
  tr.changes.iterChanges((fromA,toA,_fromB,_toB,inserted)=>{count++;if(fromA===toA&&inserted.length&&inserted.line(1).text.trim())found=fromA;});
  if(count!==1||found===null)return null;
  const line=tr.startState.doc.lineAt(found);
  if(line.text.trim()||literalCodeLine(tr.startState,line)||!needsSeparatorAbove(tr.startState,line.number))return null;
  return tr.changes.mapPos(line.from,-1);
}
// The newlines that set typed text apart: one above it, and one below it too
// when the next block follows right away, so the text does not run into it.
function separatorChanges(doc,pos) {
  const line=doc.lineAt(pos),newline=line.text.includes('\r')?'\r\n':'\n',changes=[{from:pos,insert:newline}];
  if(line.number<doc.lines&&doc.line(line.number+1).text.trim())changes.push({from:line.to-(line.text.endsWith('\r')?1:0),insert:newline});
  return changes;
}
const blankTypingFilter=EditorState.transactionFilter.of(tr=>{
  if(!tr.isUserEvent('input')||tr.isUserEvent('input.type.compose'))return tr;
  const pos=typedIntoBlank(tr);
  return pos===null?tr:[tr,{changes:separatorChanges(tr.newDoc,pos),sequential:true}];
});
// An input method changes the line while it composes, so the newline waits
// until the composition ends.
const blankTypingComposition=ViewPlugin.fromClass(class {
  constructor(view){this.view=view;this.pending=null;}
  update(update) {
    for(const tr of update.transactions) {
      if(this.pending!==null)this.pending=tr.changes.mapPos(this.pending,-1);
      if(this.pending===null&&tr.isUserEvent('input.type.compose'))this.pending=typedIntoBlank(tr);
    }
    if(this.pending!==null&&!update.view.composing)setTimeout(()=>this.flush(),0);
  }
  flush() {
    const view=this.view,pos=this.pending;
    if(pos===null||view.composing)return;
    this.pending=null;
    if(pos>view.state.doc.length)return;
    const line=view.state.doc.lineAt(pos);
    if(line.from!==pos||!line.text.trim()||!needsSeparatorAbove(view.state,line.number))return;
    view.dispatch({changes:separatorChanges(view.state.doc,pos),userEvent:'input.type'});
  }
},{eventHandlers:{compositionend(){setTimeout(()=>this.flush(),0);}}});
function literalCodeLine(state,line) {
  const tree=ensureSyntaxTree(state,line.to,40)||syntaxTree(state);
  for(let node=tree.resolveInner(line.from+Math.min(line.length,1),1);node;node=node.parent) {
    if(node.name==='FencedCode'||node.name==='CodeBlock')return true;
  }
  return false;
}
function hiddenSourceLine(state,line) {
  let hidden=false;
  state.field(liveField).between(line.from,line.from,(_from,_to,decoration)=>{
    if(/(?:^| )(?:cm-code-fence|cm-table-separator|cm-callout-empty)(?: |$)/.test(decoration.spec.class||''))hidden=true;
  });
  return hidden;
}
const blankSelectionFilter=EditorState.transactionFilter.of(tr=>{
  if(tr.docChanged||!tr.selection||tr.newSelection.ranges.length!==1||!tr.newSelection.main.empty)return tr;
  const state=tr.state,range=tr.newSelection.main,line=state.doc.lineAt(range.head);
  if(!hiddenSourceLine(state,line)&&(line.text.trim()||editableBlank(state,line)||keptBlank(state,line)||literalCodeLine(state,line)))return tr;
  const direction=range.head<tr.startState.selection.main.head?-1:1;
  for(const step of [direction,-direction])for(let n=line.number+step;n>=1&&n<=state.doc.lines;n+=step) {
    const next=state.doc.line(n);
    if(!hiddenSourceLine(state,next)&&(next.text.trim()||literalCodeLine(state,next)||editableBlank(state,next)||keptBlank(state,next)))return [tr,{selection:EditorSelection.cursor(step>0?(visiblePrefixEnd(state,next.from)??next.from):next.to),sequential:true}];
  }
  return tr;
});

const containerNodes=new Set(['Document','BulletList','OrderedList','ListItem','Blockquote']);
// Block widgets of the last build, by position, so a block whose text a
// change did not touch keeps its widget without reading its text again.
const blockWidgets=new WeakMap();
function reusableBlocks(value,tr) {
  const previous=value&&blockWidgets.get(value),reuse=new Map();
  if(!previous)return reuse;
  for(const block of previous) {
    if(tr&&tr.docChanged){if(tr.changes.touchesRange(block.from,block.to))continue;reuse.set(tr.changes.mapPos(block.from,1)+':'+tr.changes.mapPos(block.to,-1),block.widget);}
    else reuse.set(block.from+':'+block.to,block.widget);
  }
  return reuse;
}
function decorations(state,reuse=new Map(),blocks=[]) {
  const list=[], covered=[],quoteLines=new Set(),codeRanges=[],inlineCodeRanges=[],tableRanges=[];
  const tree=ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state);
  const interactive=[],ranges=decorationRanges(state);
  // Code blocks in the whole note: only containers are entered, so this
  // touches each block once, not every word.
  tree.iterate({enter(node){if(node.name==='FencedCode'||node.name==='CodeBlock'){codeRanges.push([node.from,node.to]);if(node.name==='FencedCode')interactive.push(node.node);return false;}return containerNodes.has(node.name);}});
  for(const [from,to] of ranges)tree.iterate({from,to,enter(node){if(node.name==='FencedCode'||node.name==='CodeBlock')return false;if(node.name==='InlineCode')inlineCodeRanges.push([node.from,node.to]);}});
  const addBlock=(from,to,kind)=>{
    if(from===to) return false;
    // Formulas and HTML blocks show their source while the caret is inside.
    if(kind!=='image'&&metadata.editable&&state.selection.ranges.some(range=>range.empty&&range.head>from&&range.head<to)) return false;
    // A block inside a selection is marked, so its content can be highlighted like text.
    const selected=state.selection.ranges.some(range=>!range.empty&&range.from<to&&range.to>from),language=state.facet(editorLanguage),old=reuse.get(from+':'+to);
    const widget=old instanceof BlockWidget&&old.kind===kind&&old.selected===selected&&old.language===language?old:new BlockWidget(state.doc.sliceString(from,to),from,kind,language,selected);
    list.push(Decoration.replace({widget,block:true}).range(from,to)); covered.push([from,to]); blocks.push({from,to,widget}); return true;
  };
  // A closed interactive block runs unless the caret is inside it, where its source shows.
  for(const node of interactive) {
    const firstLine=state.doc.lineAt(node.from);
    if(/^\s*(?:`{3,}|~{3,})\s*mermaid\s*$/i.test(firstLine.text)) {
      const lastLine=state.doc.lineAt(node.to),closing=node.lastChild;
      if(closing?.name!=='CodeMark'||state.doc.lineAt(closing.from).number!==lastLine.number||lastLine.number<=firstLine.number)continue;
      const from=firstLine.from,to=lastLine.to;
      if(metadata.editable&&state.selection.ranges.some(range=>range.head>from&&range.head<to||range.anchor>from&&range.anchor<to))continue;
      const language=state.facet(editorLanguage),old=reuse.get(from+':'+to);
      const widget=old instanceof MermaidWidget&&old.language===language?old:new MermaidWidget(firstLine.number+1<lastLine.number?state.doc.sliceString(state.doc.line(firstLine.number+1).from,state.doc.line(lastLine.number-1).to):'',language);
      list.push(Decoration.replace({widget,block:true}).range(from,to));covered.push([from,to]);blocks.push({from,to,widget});
      continue;
    }
    const info=interactiveInfo(state,node);if(!info)continue;
    const first=state.doc.lineAt(node.from),last=state.doc.lineAt(node.to),close=node.lastChild;
    if(!(close?.name==='CodeMark'&&state.doc.lineAt(close.from).number===last.number&&last.number>first.number))continue;
    const from=first.from,to=last.to;
    if(metadata.editable&&state.selection.ranges.some(range=>range.head>from&&range.head<to||range.anchor>from&&range.anchor<to))continue;
    const language=state.facet(editorLanguage),old=reuse.get(from+':'+to);
    const widget=old instanceof InteractiveWidget&&old.height===info.height&&old.language===language?old:
      new InteractiveWidget(first.number+1<last.number?state.doc.sliceString(state.doc.line(first.number+1).from,state.doc.line(last.number-1).to):'',info.height,language);
    list.push(Decoration.replace({widget,block:true}).range(from,to));covered.push([from,to]);blocks.push({from,to,widget});
  }
  // Rendering is independent of selection. Textual blocks stay in the main
  // editor, and non-text widgets remain rendered when selected. Formulas and
  // images are found in the whole note; callouts only in the decorated ranges.
  let code=0;
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n);
    while(code<codeRanges.length&&codeRanges[code][1]<=line.from)code++;
    if(code<codeRanges.length&&line.from>=codeRanges[code][0])continue;
    if(!/^\s*[$!><[]/.test(line.text))continue;
    if(calloutHeader.test(line.text)) {
      let end=n; while(end<state.doc.lines && /^>/.test(state.doc.line(end+1).text)) end++;
      if(!inRanges(ranges,line.from,state.doc.line(end).to)){n=end;continue;}
      // The icon sits on the first line with text. An empty header line is
      // hidden unless it carries the arrow of a folding callout.
      const match=calloutHeader.exec(line.text),body=line.text.slice(match[0].length),group=calloutGroup(match[1]);
      const hidden=!body&&end>n&&!/[+-]$/.test(match[0].trimEnd()),top=hidden?n+1:n;
      const titled=!!body&&end>n&&match[2]===undefined;
      if(hidden)list.push(Decoration.line({class:'cm-callout-empty'}).range(line.from));
      for(let row=top;row<=end;row++)list.push(Decoration.line({class:'cm-callout-line cm-callout-'+group+(row===top?' cm-callout-first'+(titled?' cm-callout-titled':''):'')+(row===end?' cm-callout-last':'')}).range(state.doc.line(row).from));
      list.push(Decoration.widget({widget:new CalloutIconWidget(match[2]||calloutIcons[group],match[1]),side:-1}).range(state.doc.line(top).from));
      n=end;
    } else if(/^\s*\[toc\]\s*$/i.test(line.text)) {
      if(metadata.editable&&state.selection.ranges.some(range=>range.empty&&range.head>line.from&&range.head<line.to))continue;
      const entries=headingStarts(state).map(pos=>{const text=state.doc.lineAt(pos).text,level=/^#+/.exec(text)[0].length;return {level,text:text.replace(/^#+\s+/,'').replace(/<[^>]+>|\*\*|__|~~|==|[*`]/g,'').trim()};});
      const widget=new TocWidget(entries);
      list.push(Decoration.replace({widget,block:true}).range(line.from,line.to));covered.push([line.from,line.to]);
    } else if(/^\s*\$\$/.test(line.text)) {
      const end=mathBlockEnd(state.doc,n);
      if(end) {addBlock(line.from,state.doc.line(end).to,'math');n=end;}
    } else if(/^\s*</.test(line.text)) {
      const end=htmlBlockEnd(state.doc,n);
      if(end) {addBlock(line.from,state.doc.line(end).to,'html');n=end;}
    } else if(/^\s*(?:!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]+\))\s*$/.test(line.text)) addBlock(line.from,line.to,'image');
  }
  covered.sort((a,b)=>a[0]-b[0]);
  const within=(from,to)=>{let lo=0,hi=covered.length-1;while(lo<=hi){const mid=(lo+hi)>>1;if(covered[mid][0]>from)hi=mid-1;else{if(to<=covered[mid][1])return true;lo=mid+1;}}return false;};
  for(const [rangeFrom,rangeTo] of ranges)tree.iterate({from:rangeFrom,to:rangeTo,enter(node){
    if(within(node.from,node.to)) return false;
    const name=node.name;
    if(name==='Blockquote') {
      const first=state.doc.lineAt(node.from).number,last=state.doc.lineAt(node.to).number;
      // Block markers need a following space, so ">" alone stays plain text.
      if(/^ {0,3}>[ \t]/.test(state.doc.line(first).text))for(let n=first;n<=last;n++)quoteLines.add(n);
      else list.push(Decoration.mark({class:'cm-plain-syntax'}).range(state.doc.line(first).from,state.doc.line(first).to));
    }
    if(name==='HorizontalRule'||name==='ThematicBreak') {
      const line=state.doc.lineAt(node.from);
      // A selected divider fills its whole line, as selected text would.
      const selected=state.selection.ranges.some(range=>range.from<=line.to&&range.to>=line.from);
      list.push(Decoration.line({class:'cm-divider-line'+(selected?' cm-divider-selected':'')}).range(line.from));
      list.push(Decoration.mark({class:'cm-divider-syntax'}).range(line.from,line.to));
      list.push(Decoration.widget({widget:new DividerWidget(line.from,line.to,state.facet(editorLanguage)),side:-1}).range(line.from));
      covered.push([line.from,line.to]);covered.sort((a,b)=>a[0]-b[0]);return false;
    }
    if(name==='Table') {list.push(...tableDecorations(state,node.node));tableRanges.push([node.from,node.to]);}
    if(/^ATXHeading[1-6]$/.test(name)) {
      const level=name.slice(-1),line=state.doc.lineAt(node.from);
      // "#" without a space stays plain text; an empty "# " shows a grey H1 hint.
      if(/^ {0,3}#{1,6}[ \t]/.test(line.text)) {
        list.push(Decoration.line({class:'cm-heading cm-heading-'+level}).range(line.from));
        if(/^ {0,3}#{1,6}[ \t]+$/.test(line.text))list.push(Decoration.widget({widget:new HeadingHintWidget(level),side:1}).range(line.to));
      } else list.push(Decoration.mark({class:'cm-plain-syntax'}).range(line.from,line.to));
    }
    if(/^SetextHeading[12]$/.test(name)) {
      const first=state.doc.lineAt(node.from),last=state.doc.lineAt(node.to),level=name.slice(-1);
      list.push(Decoration.line({class:'cm-heading cm-heading-'+level}).range(first.from));
      if(last.number!==first.number)list.push(Decoration.line({class:'cm-code-fence'}).range(last.from));
    }
    if(['StrongEmphasis','Emphasis','Strikethrough','InlineCode'].includes(name)) {
      list.push(Decoration.mark({class:({StrongEmphasis:'cm-live-strong',Emphasis:'cm-live-em',Strikethrough:'cm-live-strike',InlineCode:'cm-live-code'})[name]}).range(node.from,node.to));
    }
    if(name==='FencedCode') {
      const first=state.doc.lineAt(node.from).number,last=state.doc.lineAt(node.to).number;
      const closed=node.node.lastChild?.name==='CodeMark'&&state.doc.lineAt(node.node.lastChild.from).number===last&&last>first;
      for(let n=first;n<=last;n++)list.push(Decoration.line({class:n===first||closed&&n===last?'cm-code-fence':'cm-code-line'+(n===first+1?' cm-code-first':'')+(n===(closed?last-1:last)?' cm-code-last':'')}).range(state.doc.line(n).from));
      if(first+1<=(closed?last-1:last))list.push(codeTools(/^\s*(?:`{3,}|~{3,})\s*([^\s`]*)/.exec(state.doc.line(first).text)?.[1]||'').range(state.doc.line(first+1).from));
      return false;
    }
  }});
  for(const [rangeFrom,rangeTo] of ranges)for(let n=state.doc.lineAt(rangeFrom).number,end=state.doc.lineAt(rangeTo).number;n<=end;n++) {
    const line=state.doc.line(n); if(within(line.from,line.to))continue;
    const insideCode=tree.resolveInner(line.from+Math.min(line.length,1),1); let code=false;
    for(let node=insideCode;node;node=node.parent)if(node.name==='FencedCode'||node.name==='CodeBlock')code=true;
    if(code)continue;
    if(quoteLines.has(n)) {
      list.push(Decoration.line({class:'cm-quote-line'}).range(line.from));
      // The quote prefix is hidden and the list marker stays as text here.
      const quoted=/^ {0,3}(?:>[ \t]+)+(\s*(?:[-+*]|\d+[.)])[ \t]+)/.exec(line.text);
      if(quoted)list.push(Decoration.line({class:'cm-quote-list-line',attributes:{style:listLineStyle(textEms(quoted[1]))}}).range(line.from));
    }
    const task=/^(\s*)[-+*]\s+\[([ xX])\]\s*/.exec(line.text);
    const bullet=/^(\s*)(?:([-+*])\s+|(\d+)[.)]\s+)/.exec(line.text);
    if(task||bullet) {
      const marker=task?1.55:bullet[3]?Math.max(1.25,textEms(bullet[3]+'.')+.35):1.25;
      list.push(Decoration.line({class:'cm-list-line',attributes:{style:listLineStyle(textEms((task||bullet)[1])+marker,marker)}}).range(line.from));
    }
    if(task)list.push(Decoration.replace({widget:new TaskWidget(line.from,task[2].toLowerCase()==='x',state.facet(editorLanguage))}).range(line.from+task[1].length,line.from+task[0].length));
    else if(bullet)list.push(Decoration.replace({widget:new BulletWidget(bullet[3]?bullet[3]+'.':'•')}).range(line.from+bullet[1].length,line.from+bullet[0].length));
    const links=/(!?)\[\[([^\]\n]+)\]\]|\[([^\]\n]+)\]\(([^)\n]+)\)/g; let match;
    while((match=links.exec(line.text))) {
      if(match[1])continue;
      if(inlineCodeRanges.some(([a,b])=>line.from+match.index>=a&&line.from+match.index<b))continue;
      const parts=(match[2]||'').split('|'),target=match[4]||parts[0];
      const raw=match[0],offset=match[2]!==undefined?(parts.length>1?raw.indexOf('|')+1:2):1;
      const length=match[2]!==undefined?(parts.length>1?parts[1].length:parts[0].length):match[3].length;
      if(length)list.push(Decoration.mark({class:'cm-live-link',attributes:{'data-live-target':target,title:uiText(state,'openLink')}}).range(line.from+match.index+offset,line.from+match.index+offset+length));
    }
    const highlights=/==([^=\n]+)==/g;
    while((match=highlights.exec(line.text))) {const from=line.from+match.index,to=from+match[0].length;if(inlineCodeRanges.some(([a,b])=>from>=a&&from<b))continue;list.push(Decoration.mark({class:'cm-live-highlight'}).range(from,to));}
    // Inline $…$ math shows typeset, and its source while the caret is in it.
    // A $ next to a digit or space is left alone, so prices stay plain text.
    const inlineMath=/(?<![\\$])\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?![$\d])/g;
    while((match=inlineMath.exec(line.text))) {
      const from=line.from+match.index,to=from+match[0].length;
      if(inlineCodeRanges.some(([a,b])=>from<b&&to>a))continue;
      if(metadata.editable&&state.selection.ranges.some(range=>range.to>=from&&range.from<=to))continue;
      list.push(Decoration.replace({widget:new InlineMathWidget(match[1])}).range(from,to));
    }
    const touching=(from,to)=>metadata.editable&&state.selection.ranges.some(range=>range.to>=from&&range.from<=to);
    const inCodeSpan=(from,to)=>inlineCodeRanges.some(([a,b])=>from<b&&to>a);
    inlineHTML(line.text,line.from,(from,to)=>metadata.editable&&state.selection.ranges.some(range=>range.empty&&range.head>=from&&range.head<=to),inCodeSpan,list);
    for(const embed of line.text.matchAll(/!\[\[([^\]\n]+)\]\]|!\[([^\]\n]*)\]\(([^)\s]+)\)/g)) {
      const from=line.from+embed.index,to=from+embed[0].length,parsed=embed[1]?parseEmbed(embed[1]):{target:embed[3],width:/\|(\d+)$/.exec(embed[2])?.[1]},url=isImageTarget(parsed.target)&&resourceURL(parsed.target);
      if(!url||inCodeSpan(from,to)||touching(from,to))continue;
      list.push(Decoration.replace({widget:new InlineImageWidget(url,parsed.target,parsed.width?Number(parsed.width):null)}).range(from,to));
    }
    if(!tableRanges.some(([a,b])=>line.from>=a&&line.from<b))keepWords(line.text,line.from,inCodeSpan,list);
    // A footnote mark shows as a small number that goes to its note.
    if(line.text.includes('[^')) {
      const note=/^\[\^[^\]\s]+\]:\s/.exec(line.text);
      if(note)list.push(Decoration.line({class:'cm-footnote-note'}).range(line.from));
      for(const mark of line.text.matchAll(/\[\^([^\]\s]+)\]/g)) {
        const from=line.from+mark.index,to=from+mark[0].length;
        if(inCodeSpan(from,to)||touching(from,to)||(note&&mark.index===0))continue;
        list.push(Decoration.replace({widget:new FootnoteWidget(mark[1])}).range(from,to));
      }
    }
    // $$…$$ inside a line of text is a formula too, set in the line.
    const textMath=/(?<![\\$])\$\$(?![$\s])((?:\\.|[^$\\\n])+?)\$\$(?!\$)/g;
    while((match=textMath.exec(line.text))) {
      const from=line.from+match.index,to=from+match[0].length;
      if(inlineCodeRanges.some(([a,b])=>from<b&&to>a))continue;
      if(metadata.editable&&state.selection.ranges.some(range=>range.to>=from&&range.from<=to))continue;
      list.push(Decoration.replace({widget:new InlineMathWidget(match[1].trim())}).range(from,to));
    }
    if(!line.text.trim()) {
      // Tables, code blocks, quotes and callouts end without a paragraph gap,
      // so the blank line after one keeps a gap before whatever follows.
      const prev=n>1?state.doc.line(n-1).text:'',next=n<state.doc.lines?state.doc.line(n+1).text:'';
      const gap=next.trim()&&/^\s*(?:\||```|~~~|>)/.test(prev);
      list.push(Decoration.line({class:'cm-blank-line'+(gap?' cm-block-gap':'')+(editableBlank(state,line)?' cm-input-blank-line':keptBlank(state,line)?' cm-kept-blank-line':'')}).range(line.from));
    }
  }
  // The selection is shown as a highlight on its text only. Tables mark the
  // selected text inside each cell themselves (rich-table.js), so they are left out here.
  for(const range of state.selection.ranges) {
    if(range.empty)continue;
    let from=range.from;
    for(const [a,b] of tableRanges) {
      if(b<=from||a>=range.to)continue;
      if(a>from)list.push(Decoration.mark({class:'cm-selected-text'}).range(from,a));
      from=Math.max(from,b);
    }
    if(from<range.to)list.push(Decoration.mark({class:'cm-selected-text'}).range(from,range.to));
  }
  const set=Decoration.set(list,true);blockWidgets.set(set,blocks);return set;
}
const liveField=StateField.define({create:state=>decorations(state),update(value,tr){return tr.docChanged||tr.selection||tr.startState.field(windowField)!==tr.state.field(windowField)||tr.startState.field(inputBlankField)!==tr.state.field(inputBlankField)||tr.startState.facet(editorLanguage)!==tr.state.facet(editorLanguage)||syntaxTree(tr.startState)!==syntaxTree(tr.state)?decorations(tr.state,reusableBlocks(value,tr)):value;},provide:field=>[EditorView.decorations.from(field),EditorView.atomicRanges.of(view=>view.state.field(field).update({filter:(_from,_to,value)=>value.spec.block===true}))]});
// The caret is hidden while the selection rests on a divider, which shows as selected instead.
const dividerCaret=EditorView.editorAttributes.compute(['selection',liveField],state=>{
  if(!state.selection.ranges.every(range=>range.empty))return {};
  const line=state.doc.lineAt(state.selection.main.head);let divider=false;
  state.field(liveField).between(line.from,line.from,(_from,_to,decoration)=>{if(/(?:^| )cm-divider-line(?: |$)/.test(decoration.spec.class||''))divider=true;});
  return divider?{class:'cm-caret-hidden'}:{};
});

// Which ranges each set of delimiters covers, so a caret moving within them
// does not rebuild the set.
const boldCoverage=new WeakMap();
function boldDelimiters(state,windows=decorationRanges(state)) {
  const ranges=[],tree=ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state),code=[],inline=[];
  const add=(from,to,extra={})=>{if(to>from){const line=state.doc.lineAt(from);ranges.push(Decoration.mark({class:'cm-format-delimiter'+(extra.bold?' cm-live-bold-delimiter':'')+(from>line.from&&to<line.to?' cm-hidden-syntax':''),...extra}).range(from,to));}};
  for(const [windowFrom,windowTo] of windows)tree.iterate({from:windowFrom,to:windowTo,enter(node){
    if(node.name==='FencedCode'||node.name==='CodeBlock') {
      code.push([node.from,node.to]);
      if(node.name==='FencedCode') {
        const first=state.doc.lineAt(node.from);add(first.from,first.to,{kind:'fence'});
        const last=node.node.lastChild;
        if(last?.name==='CodeMark'&&last.from>first.to){const line=state.doc.lineAt(last.from);add(line.from,line.to,{kind:'fence'});}
      }
      return false;
    }
    if(/^ATXHeading[1-6]$/.test(node.name)) {
      const line=state.doc.lineAt(node.from),prefix=/^ {0,3}#{1,6}[ \t]+/.exec(line.text);
      if(prefix){
        add(line.from,line.from+prefix[0].length,{kind:'prefix'});
        const last=node.node.lastChild;
        if(last?.name==='HeaderMark'&&last.from>line.from+prefix[0].length)add(last.from,last.to);
      }
    }
    if(/^SetextHeading[12]$/.test(node.name)){const line=state.doc.lineAt(node.to);add(line.from,line.to,{kind:'fence'});}
    if(!['StrongEmphasis','Emphasis','Strikethrough','InlineCode'].includes(node.name))return;
    const first=node.node.firstChild,last=node.node.lastChild;
    if(node.name==='InlineCode')inline.push([node.from,node.to]);
    if(!first||!last||first===last)return;
    const spec={bold:node.name==='StrongEmphasis',boldFrom:node.from,boldTo:node.to,bodyFrom:first.to,bodyTo:last.from};
    add(first.from,first.to,spec);add(last.from,last.to,spec);
  }});
  for(const [windowFrom,windowTo] of windows)for(let n=state.doc.lineAt(windowFrom).number,end=state.doc.lineAt(windowTo).number;n<=end;n++) {
    const line=state.doc.line(n);
    if(code.some(([a,b])=>line.from>=a&&line.from<b))continue;
    const callout=calloutHeader.exec(line.text),quote=/^ {0,3}(?:>[ \t]+)+/.exec(line.text);
    const prefix=callout||quote;if(prefix)add(line.from,line.from+prefix[0].length,{kind:'prefix'});
    const links=/(!?)\[\[([^\]\n]+)\]\]|\[([^\]\n]+)\]\(([^)\n]+)\)/g;let match;
    while((match=links.exec(line.text))) {
      if(match[1]||inline.some(([a,b])=>line.from+match.index>=a&&line.from+match.index<b))continue;
      const raw=match[0],parts=(match[2]||'').split('|'),offset=match[2]!==undefined?(parts.length>1?raw.indexOf('|')+1:2):1;
      const length=match[2]!==undefined?(parts.length>1?parts[1].length:parts[0].length):match[3].length,from=line.from+match.index;
      add(from,from+offset,{kind:'link'});add(from+offset+length,from+raw.length,{kind:'link'});
    }
    const highlights=/==([^=\n]+)==/g;
    while((match=highlights.exec(line.text))) {
      const from=line.from+match.index,to=from+match[0].length;
      if(inline.some(([a,b])=>from>=a&&from<b))continue;
      const spec={boldFrom:from,boldTo:to,bodyFrom:from+2,bodyTo:to-2};add(from,from+2,spec);add(to-2,to,spec);
    }
  }
  const set=Decoration.set(ranges,true);boldCoverage.set(set,windows);return set;
}
function removeBlockPrefix(view) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly||!range.empty||state.selection.ranges.length!==1||inCode(state,range.head))return false;
  const line=state.doc.lineAt(range.head),prefix=/^(?: {0,3}#{1,6}[ \t]+| {0,3}(?:>[ \t]+)+(?:\[![\w-]+(?:\|[^\]\n]*)?\][+-]?[ \t]*)?)/.exec(line.text);
  if(prefix&&range.head<=line.from+prefix[0].length){view.dispatch({changes:{from:line.from,to:line.from+prefix[0].length},selection:{anchor:line.from},userEvent:'delete.backward'});return true;}
  return false;
}
function visiblePrefixEnd(state,pos) {
  if(inCode(state,pos))return null;
  const line=state.doc.lineAt(pos),prefix=/^(?: {0,3}#{1,6}[ \t]+| {0,3}(?:>[ \t]+)+(?:\[![\w-]+(?:\|[^\]\n]*)?\][+-]?[ \t]*)?)/.exec(line.text);
  return prefix?line.from+prefix[0].length:null;
}
const formatSelectionFilter=EditorState.transactionFilter.of(tr=>{
  if(tr.docChanged||!tr.selection||tr.newSelection.ranges.length!==1||!tr.newSelection.main.empty)return tr;
  const pos=tr.newSelection.main.head,end=visiblePrefixEnd(tr.state,pos);
  return end!==null&&pos<end?[tr,{selection:EditorSelection.cursor(end),sequential:true}]:tr;
});
function beforeBlockPrefix(view) {
  const range=view.state.selection.main;
  if(!range.empty)return false;
  const end=visiblePrefixEnd(view.state,range.head);
  if(end===null||range.head>end)return false;
  const line=view.state.doc.lineAt(range.head);
  if(line.number>1)view.dispatch({selection:EditorSelection.cursor(view.state.doc.line(line.number-1).to),scrollIntoView:true,userEvent:'select'});
  return true;
}
function deleteDivider(view,forward) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly||!range.empty)return false;
  const line=state.doc.lineAt(range.head);
  let divider=false;const tree=ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state);
  tree.iterate({from:line.from,to:line.to,enter(node){if(node.name==='HorizontalRule'||node.name==='ThematicBreak')divider=true;}});
  if(!divider)return false;
  view.dispatch({changes:{from:line.from,to:line.to},selection:{anchor:line.from},userEvent:forward?'delete.forward':'delete.backward'});return true;
}
function deleteAroundBold(view,forward) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly||state.selection.ranges.length!==1||!range.empty)return false;
  const delimiters=state.field(boldDelimiterField);let cursor=range.head,crossed=false;
  // Hidden syntax is skipped, rather than deleted, at a formatting boundary.
  for(;;) {
    let adjacent=null;
    delimiters.between(Math.max(0,cursor-1),Math.min(state.doc.length,cursor+1),(from,to)=>{
      if(forward?from<=cursor&&to>cursor:from<cursor&&to>=cursor)adjacent={from,to};
    });
    if(!adjacent)break;
    cursor=forward?adjacent.to:adjacent.from;crossed=true;
  }
  const line=state.doc.lineAt(cursor);
  let target=findClusterBreak(line.text,cursor-line.from,forward,forward)+line.from;
  if(target===cursor) {
    if(forward?line.number<state.doc.lines:line.number>1)target+=forward?1:-1;
    else return crossed;
  }
  let from=Math.min(cursor,target),to=Math.max(cursor,target),emptyPair=null;
  delimiters.between(Math.max(0,from-2),Math.min(state.doc.length,to+2),(_from,_to,mark)=>{
    if(mark.spec.bodyFrom===from&&mark.spec.bodyTo===to)emptyPair=mark.spec;
  });
  if(emptyPair){from=emptyPair.boldFrom;to=emptyPair.boldTo;}
  if(!crossed&&!emptyPair)return false;
  const changes=state.changes({from,to});
  view.dispatch({changes,selection:EditorSelection.cursor(changes.mapPos(range.head,-1)),scrollIntoView:true,userEvent:forward?'delete.forward':'delete.backward'});
  return true;
}
const boldDelimiterField=StateField.define({
  create:boldDelimiters,
  update(value,tr){
    if(tr.docChanged||syntaxTree(tr.startState)!==syntaxTree(tr.state)||tr.startState.field(windowField)!==tr.state.field(windowField))return boldDelimiters(tr.state);
    const covered=boldCoverage.get(value)||[];
    return tr.selection&&tr.state.selection.ranges.some(range=>!covered.some(([a,b])=>range.from>=a&&range.to<=b))?boldDelimiters(tr.state):value;
  },
  provide:field=>[
    EditorView.decorations.from(field),
    EditorView.atomicRanges.of(view=>view.state.field(field)),
    keymap.of([{key:'Backspace',run:view=>deleteDivider(view,false)||removeBlockPrefix(view)||deleteAroundBold(view,false)},{key:'Delete',run:view=>deleteDivider(view,true)||deleteAroundBold(view,true)}])
  ]
});

function simpleListEnter(view) {
  const range=view.state.selection.main;if(!range.empty)return false;
  if(inCode(view.state,range.head))return false;
  const line=view.state.doc.lineAt(range.head);
  // Enter on an empty quote or callout line leaves the quote, like a list.
  if(/^\s*(?:>\s?)+$/.test(line.text)&&range.head===line.to)return leaveEmptyBlock(view,line);
  const match=/^(\s*)([-+*]|\d+[.)])\s+(?:\[([ xX])\]\s*)?/.exec(line.text);
  if(!match||range.head<line.from+match[0].length)return false;
  if(!line.text.slice(match[0].length).trim())return leaveEmptyBlock(view,line);
  let marker=match[2];if(/^\d/.test(marker))marker=String(parseInt(marker,10)+1)+marker.slice(-1);
  const insert='\n'+match[1]+marker+' '+(match[3]!==undefined?'[ ] ':'');
  view.dispatch(view.state.replaceSelection(insert),{scrollIntoView:true,userEvent:'input'});return true;
}
// The second Enter turns the empty item into an empty line. When more of the
// block follows, a separator after it keeps that line visible once the caret
// moves on.
function leaveEmptyBlock(view,line) {
  const doc=view.state.doc,next=line.number<doc.lines?doc.line(line.number+1):null;
  view.dispatch({changes:{from:line.from,to:line.to,insert:next&&next.text.trim()?'\n':''},selection:{anchor:line.from},scrollIntoView:true,userEvent:'input'});
  return true;
}
// Enter on an empty line right above Markdown's hidden separator moves onto
// that separator instead of adding a line: the separator becomes the new empty
// line, so two Enters after a paragraph leave one empty line, not two, once
// the caret moves on. The document keeps the same text; the change only marks
// the line as the one being typed into.
function separatorEnter(view) {
  const {state}=view,range=state.selection.main;
  if(!range.empty||state.selection.ranges.length!==1||inCode(state,range.head))return false;
  const line=state.doc.lineAt(range.head);
  if(line.text.trim()||line.number+1>=state.doc.lines)return false;
  const next=state.doc.line(line.number+1);
  if(next.text.trim()||!state.doc.line(line.number+2).text.trim()||literalCodeLine(state,state.doc.line(line.number+2)))return false;
  view.dispatch({changes:[{from:line.from,insert:state.doc.sliceString(next.from,next.to+1)},{from:next.from,to:next.to+1}],selection:{anchor:line.from+next.length+1},scrollIntoView:true,userEvent:'input'});
  return true;
}
function simpleListBackspace(view) {
  const range=view.state.selection.main;if(!range.empty)return false;
  if(inCode(view.state,range.head))return false;
  const line=view.state.doc.lineAt(range.head),match=/^(\s*)(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/.exec(line.text);
  if(!match||range.head!==line.from+match[0].length)return false;
  view.dispatch({changes:{from:line.from,to:range.head,insert:match[1]},selection:{anchor:line.from+match[1].length},userEvent:'delete.backward'});return true;
}
function inCode(state,pos){for(let node=syntaxTree(state).resolveInner(pos,-1);node;node=node.parent)if(node.name==='FencedCode'||node.name==='CodeBlock')return true;return false;}
function extensions() {return [
  history(),drawSelection({drawRangeCursor:false}),EditorView.lineWrapping,markdown({extensions:GFM,codeLanguages}),codeHighlight,syntaxHighlighting(defaultHighlightStyle),folding,windowField,windowTracker,boldDelimiterField,inputBlankField,liveField,dividerCaret,tableSelectionFilter,formatSelectionFilter,blankSelectionFilter,blankTypingFilter,blankTypingComposition,
  slashCommands({image:()=>post({type:'pickImage',currentPath:metadata.currentPath})}),formatToolbar(),markdownInput(),
  localization.of(localeExtensions()),
  editability.of([EditorView.editable.of(metadata.editable),EditorState.readOnly.of(!metadata.editable)]),
  keymap.of([...tableKeymap,{key:'ArrowLeft',run:beforeBlockPrefix},{key:'ArrowUp',run:intoTitle},{key:'Enter',run:view=>simpleListEnter(view)||separatorEnter(view)},{key:'Backspace',run:simpleListBackspace},...markdownKeymap,...defaultKeymap,...historyKeymap,indentWithTab]),
  EditorView.updateListener.of(update=>{
    if(applyingExternal)return;
    if(update.docChanged){for(const tr of update.transactions)if(tr.docChanged){applyRawChanges(tr);revision++;}lastSource=rawSource;const selection=update.state.selection.main;post({type:'change',text:rawSource,currentPath:metadata.currentPath,revision,selectionAnchor:selection.anchor,selectionHead:selection.head});}
  }),
  // A plain click on a link opens it; a drag across it still selects text.
  // A paste that carries files or a picture goes to the app, which copies them
  // into Attachments and inserts their links; it pastes plain text otherwise.
  EditorView.domEventHandlers({paste(event){const data=event.clipboardData;if(!metadata.editable||!data||!(data.files?.length||[...data.types].includes('Files')))return false;event.preventDefault();post({type:'paste',currentPath:metadata.currentPath});return true;}}),
  EditorView.domEventHandlers({click(event,view){const link=event.target.closest?.('[data-live-target]');if(link&&(view.state.selection.main.empty||event.metaKey||event.ctrlKey||!metadata.editable)){event.preventDefault();navigate(link.dataset.liveTarget);return true;}return false;}})
];}
const view=new EditorView({state:EditorState.create({doc:'',extensions:extensions()}),parent:document.getElementById('editor')});
view.scrollDOM.insertBefore(titleBlock,view.contentDOM);
configureRichText({post,uiText,currentPath:()=>metadata.currentPath,headings:headingStarts});
// The text fills what the title leaves of the window, so a short page does not scroll.
new ResizeObserver(()=>document.documentElement.style.setProperty('--page-title-height',titleBlock.offsetHeight+'px')).observe(titleBlock);
window.acdianEditor=view;
// One editor serves every tab. A tab put in the back keeps its whole editor
// state (text, selection, undo history) and scroll place here; it comes back
// as it was when the native side sends the same text again, or else starts
// fresh from the text it sends, which is what is on disk.
const sessions=new Map(),sessionLimit=12,sessionTextLimit=40_000_000;
// A restored place is applied at the editor's next layout, which WebKit holds
// back while the window is covered; until then it is still the place to report.
let pendingPlace=null;
function scrollPlace(){if(pendingPlace)return pendingPlace;const target=view.scrollSnapshot().value;return{pos:target.range.head,offset:target.yMargin};}
function scrollTo(place){
  pendingPlace=null;
  if(!place||!Number.isFinite(place.pos)||!Number.isFinite(place.offset))return [];
  pendingPlace={pos:place.pos,offset:place.offset};view.requestMeasure({read(){pendingPlace=null;}});
  const snapshot=view.scrollSnapshot();
  return snapshot.type.of(new snapshot.value.constructor(EditorSelection.cursor(Math.max(0,Math.min(place.pos,view.state.doc.length))),'start','start',place.offset,0,true));
}
// What the editor's compartments were last configured from.
const editorSettings=()=>JSON.stringify([metadata.editable,metadata.language]);
function stashSession(tabID,path){
  if(!tabID)return;
  sessions.delete(tabID);
  sessions.set(tabID,{state:view.state,path,rawSource,lineBreak,rawSnapshots,scroll:scrollPlace(),settings:editorSettings()});
  let total=0;for(const session of sessions.values())total+=session.rawSource.length;
  for(const [id,session] of sessions){if(sessions.size<=sessionLimit&&total<=sessionTextLimit)break;if(id===tabID)continue;sessions.delete(id);total-=session.rawSource.length;}
}
function installDocument(text,remembered) {
  const session=sessions.get(metadata.tabID);
  sessions.delete(metadata.tabID);
  applyingExternal=true;
  if(session&&session.path===metadata.currentPath&&session.rawSource===text) {
    ({rawSource,lineBreak,rawSnapshots}=session);
    view.setState(session.state);
    // Reconfiguring costs a few milliseconds on a long page, so it is skipped when nothing changed.
    // A page stashed while a load held the editor read-only must not come back read-only.
    const reconfigure=session.settings===editorSettings()&&session.state.facet(EditorView.editable)===metadata.editable?[]:[editability.reconfigure([EditorView.editable.of(metadata.editable),EditorState.readOnly.of(!metadata.editable)]),localization.reconfigure(localeExtensions())];
    view.dispatch({effects:[...reconfigure,scrollTo(session.scroll)].flat()});
  } else {
    rawSource=text;lineBreak=rawSource.includes('\r\n')?'\r\n':rawSource.includes('\r')?'\r':'\n';rawSnapshots=new Map([[canonical(rawSource),rawSource]]);
    view.setState(EditorState.create({doc:canonical(rawSource),extensions:extensions()}));
    const folded=startFolded(view.state);if(folded.length)view.dispatch({effects:folded});
    // A tab whose editor state was not kept still returns to its last place.
    const place=session&&session.path===metadata.currentPath?{anchor:session.state.selection.main.anchor,head:session.state.selection.main.head,scroll:session.scroll}:remembered;
    const length=view.state.doc.length,clamp=value=>Number.isFinite(value)?Math.max(0,Math.min(value,length)):0;
    view.dispatch({selection:place?EditorSelection.single(clamp(place.anchor),clamp(place.head)):EditorSelection.cursor(0),effects:scrollTo(place?.scroll)});
  }
  applyingExternal=false;
  lastSource=rawSource;revision=0;
  reportedHeading=null;requestAnimationFrame(followHeading);
}
// The file changed on disk while this page was open and unedited. Only the
// changed span is replaced, so the caret, the scroll place and the undo
// history of the page stay where they were.
function refreshFromDisk(text) {
  const next=canonical(text),current=view.state.doc.toString();
  applyingExternal=true;
  if(next!==current)view.dispatch({changes:lineChanges(current,next),annotations:Transaction.addToHistory.of(false)});
  applyingExternal=false;
  rawSource=text;lineBreak=rawSource.includes('\r\n')?'\r\n':rawSource.includes('\r')?'\r':'\n';rawSnapshots=new Map([[canonical(rawSource),rawSource]]);lastSource=rawSource;
}
// The lines that differ, as separate changes, so a caret between two edits
// stays on its line. Pages too large to compare line by line change as one span.
function lineChanges(a,b) {
  const A=a.split('\n'),B=b.split('\n');
  let top=0;while(top<A.length&&top<B.length&&A[top]===B[top])top++;
  let bottom=0;while(bottom<A.length-top&&bottom<B.length-top&&A[A.length-1-bottom]===B[B.length-1-bottom])bottom++;
  const n=A.length-top-bottom,m=B.length-top-bottom,offsets=[0];
  for(const line of A)offsets.push(offsets[offsets.length-1]+line.length+1);
  const span=(i0,i1,j0,j1)=>{
    const from=offsets[i0],to=i1>i0?offsets[i1]-1:from,insert=B.slice(j0,j1).join('\n');
    // A pure insertion or deletion carries one of its line breaks with it.
    if(i1===i0)return i0<A.length?{from,insert:insert+'\n'}:{from:from-1,insert:'\n'+insert};
    if(j1===j0)return i1<A.length?{from,to:offsets[i1]}:{from:Math.max(0,from-1),to};
    return {from,to,insert};
  };
  if(!n||!m||n*m>4e6)return [span(top,top+n,top,top+m)];
  // Longest common subsequence of the middle lines.
  const L=new Uint32Array((n+1)*(m+1)),w=m+1;
  for(let i=n-1;i>=0;i--)for(let j=m-1;j>=0;j--)L[i*w+j]=A[top+i]===B[top+j]?L[(i+1)*w+j+1]+1:Math.max(L[(i+1)*w+j],L[i*w+j+1]);
  const changes=[];let i=0,j=0,si=0,sj=0;
  const flush=()=>{if(i>si||j>sj)changes.push(span(top+si,top+i,top+sj,top+j));};
  while(i<n||j<m){
    if(i<n&&j<m&&A[top+i]===B[top+j]){flush();i++;j++;si=i;sj=j;}
    else if(j>=m||i<n&&L[(i+1)*w+j]>=L[i*w+j+1])i++;
    else j++;
  }
  flush();
  return changes;
}
window.acdianSetDocument=payload=>{
  const previousPath=metadata.currentPath,previousToken=metadata.resetToken,previousDocument=metadata.documentID,previousTab=metadata.tabID;
  if(typeof payload.currentPath==='string')metadata.currentPath=payload.currentPath;
  if(typeof payload.documentID==='string')metadata.documentID=payload.documentID;
  if(typeof payload.tabID==='string')metadata.tabID=payload.tabID;
  if(typeof payload.title==='string'){metadata.title=payload.title;document.title=payload.title||'ACdian';}
  if(typeof payload.pageTitle==='string')metadata.pageTitle=payload.pageTitle;
  if(typeof payload.draft==='boolean')document.documentElement.classList.toggle('draft-page',payload.draft);
  if(payload.appearance==='light'||payload.appearance==='dark'){document.documentElement.classList.toggle('light',payload.appearance==='light');document.querySelector('meta[name="color-scheme"]')?.setAttribute('content',payload.appearance);}
  if(typeof payload.editable==='boolean')metadata.editable=payload.editable;
  if(typeof payload.language==='string')metadata.language=normalizeLanguage(payload.language);
  document.documentElement.lang=metadata.language;
  document.getElementById('editor').setAttribute('aria-label',messagesForLanguage(metadata.language).editorLabel);
  if('resetToken'in payload)metadata.resetToken=payload.resetToken;
  if(Number.isFinite(payload.fontSize))document.documentElement.style.setProperty('--editor-font-size',Math.max(12,Math.min(28,payload.fontSize))+'px');
  const switched=previousDocument!==metadata.documentID;
  showTitle(switched);
  if(switched&&document.activeElement===titleBlock)titleBlock.blur();
  if(switched&&previousDocument)stashSession(previousTab,previousPath);
  // Tabs that were closed give up their kept state.
  if(Array.isArray(payload.openTabs))for(const id of [...sessions.keys()])if(!payload.openTabs.includes(id))sessions.delete(id);
  const hasText=typeof payload.text==='string';
  // A refresh is dropped when the page was typed in after the native side last
  // heard from it; that edit is saved next and reports the conflict.
  if(hasText&&payload.refresh&&!switched&&previousPath===metadata.currentPath){if(payload.refresh.base===rawSource)refreshFromDisk(payload.text);}
  else if(hasText&&(switched||payload.text!==rawSource||previousPath!==metadata.currentPath||previousToken!==metadata.resetToken))installDocument(payload.text,switched?payload.view:null);
  else view.dispatch({effects:[editability.reconfigure([EditorView.editable.of(metadata.editable),EditorState.readOnly.of(!metadata.editable)]),localization.reconfigure(localeExtensions())]});
};
window.acdianGetDocument=()=>{const place=scrollPlace();return{text:rawSource,currentPath:metadata.currentPath,documentID:metadata.documentID,revision,selectionAnchor:view.state.selection.main.anchor,selectionHead:view.state.selection.main.head,scrollPosition:place.pos,scrollOffset:place.offset};};
// A block insertion, such as an image embed, gets lines of its own, as an
// embed shows as a picture only when nothing else shares its line.
window.acdianInsertText=(text,insertionID,block)=>{if(insertionID&&insertions.has(insertionID))return true;if(!metadata.editable)return false;const insert=canonical(String(text));
  if(block){
    // A picture takes lines of its own and the caret goes on below it, so typing never lands in its link.
    const {from,to}=view.state.selection.main,doc=view.state.doc,before=from>0&&doc.sliceString(from-1,from)!=='\n'?'\n':'',after=doc.sliceString(to,to+1)==='\n'?'':'\n';
    view.dispatch({changes:{from,to,insert:before+insert+after},selection:{anchor:from+before.length+insert.length+1},scrollIntoView:true});
  } else view.dispatch(view.state.replaceSelection(insert));if(insertionID){insertions.add(insertionID);if(insertions.size>500)insertions.delete(insertions.values().next().value);}view.focus();return true;};
// Files dragged in from another app land where the caret follows the pointer.
window.acdianDropCaret=(x,y)=>{if(!metadata.editable)return false;const pos=view.posAtCoords({x,y},false);if(pos==null)return false;if(view.state.selection.main.head!==pos||!view.state.selection.main.empty)view.dispatch({selection:{anchor:pos}});if(!view.hasFocus)view.focus();return true;};
window.acdianRefreshTitle=()=>showTitle(true);
window.acdianUndo=()=>undo(view);
window.acdianRedo=()=>redo(view);
window.acdianScrollTo=raw=>{
  const anchor=decode(String(raw||'').replace(/^#/,''));let pos=0,found=!anchor;
  for(let n=1;n<=view.state.doc.lines&&!found;n++){const line=view.state.doc.line(n),heading=/^#{1,6}\s+(.+?)(?:\s+#+)?$/.exec(line.text);if(heading&&(heading[1].toLowerCase()===anchor.toLowerCase()||heading[1].toLowerCase().replace(/\s+/g,'-')===anchor.toLowerCase())||line.text.endsWith(' ^'+anchor.replace(/^\^/,''))){pos=line.from;found=true;}}
  if(!found)return false;
  view.dispatch({selection:EditorSelection.cursor(pos)});
  if(!anchor){view.scrollDOM.scrollTop=0;headingFollowPausedUntil=performance.now()+400;reportHeading(-1);return true;}
  // The scroll effect is lost when moving the caret re-lays out the live
  // decorations, so the heading is brought to the top of the scroller directly.
  const scroller=view.scrollDOM,offset=view.documentTop-scroller.getBoundingClientRect().top+scroller.scrollTop;
  scroller.scrollTop=Math.max(0,offset+view.lineBlockAt(pos).top-24);
  // The jumped-to heading stays current even when the page cannot scroll it to the top.
  headingFollowPausedUntil=performance.now()+400;reportHeading(headingStarts(view.state).indexOf(pos));
  return true;
};
// The outline follows the reader: the heading nearest the top of the view is
// reported to the native outline whenever it changes (-1 before the first one).
// Headings are found with the same rules as the native outline list.
let headingCache=null,reportedHeading=null,headingFrame=0,headingFollowPausedUntil=0;
function headingStarts(state){
  if(headingCache?.doc===state.doc)return headingCache.list;
  const list=[];let fence=false;
  for(let n=1;n<=state.doc.lines;n++){const line=state.doc.line(n);if(/^(?:```|~~~)/.test(line.text)){fence=!fence;continue;}if(!fence&&/^#{1,6} /.test(line.text))list.push(line.from);}
  headingCache={doc:state.doc,list};return list;
}
function reportHeading(index){if(index!==reportedHeading){reportedHeading=index;post({type:'heading',index,currentPath:metadata.currentPath});}}
function followHeading(){
  headingFrame=0;
  if(performance.now()<headingFollowPausedUntil)return;
  const scroller=view.scrollDOM,top=scroller.scrollTop-(view.documentTop-scroller.getBoundingClientRect().top+scroller.scrollTop)+60;
  const list=headingStarts(view.state);let index=-1;
  for(let i=0;i<list.length&&view.lineBlockAt(list[i]).top<=top;i++)index=i;
  reportHeading(index);
}
view.scrollDOM.addEventListener('scroll',()=>{if(!headingFrame)headingFrame=requestAnimationFrame(followHeading);},{passive:true});
window.acdianLiveEditorTest={wordRanges,simpleListEnter,simpleListBackspace,canonical,rawOffset,treeString:()=>syntaxTree(view.state).toString(),keptTabs:()=>[...sessions.keys()]};
post({type:'ready'});
