import { EditorState, EditorSelection, StateField, Compartment, findClusterBreak } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { markdown, markdownKeymap } from '@codemirror/lang-markdown';
import { syntaxTree, ensureSyntaxTree, syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
import { GFM } from '@lezer/markdown';
import { slashCommands } from './slash-commands.js';
import { formatToolbar } from './format-toolbar.js';
import { editorLanguage, normalizeLanguage, messagesForLanguage, uiText } from './ui-language.js';
import { tableDecorations, tableKeymap, tableSelectionFilter } from './rich-table.js';

const post = message => window.webkit?.messageHandlers?.acdian?.postMessage(message);
const metadata = { currentPath: '', title: '', editable: true, resetToken: null, language:'en' };
let rawSource = '', lastSource = '', lineBreak = '\n', applyingExternal = false, revision = 0;
const insertions = new Set();
let rawSnapshots = new Map();
const editability = new Compartment();
const localization = new Compartment();
const localeExtensions=()=>{
  const strings=messagesForLanguage(metadata.language);
  return [editorLanguage.of(metadata.language),placeholder(strings.placeholder),EditorView.contentAttributes.of({lang:metadata.language,'aria-label':strings.editorLabel})];
};
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

function fragment(source,state) {
  const holder = document.createElement('div'); holder.className = 'markdown-body cm-rendered-content';
  let prepared = source.replace(/!\[\[([^\]\n]+)\]\]/g, (_,value) => {
    const [target,alias] = value.split('|');
    if (/\.pdf(?:#|$)/i.test(target)) return `<a data-live-target="${escapeHTML(target)}">PDF · ${escapeHTML(alias || target.split('/').pop())} ↗</a>`;
    if (/\.(?:png|jpe?g|gif|webp|svg|avif|bmp|heic)(?:#|$)/i.test(target)) {const dimensions=/^(\d+)(?:x(\d+))?$/.exec(alias||'');return `<img data-live-resource="${escapeHTML(target)}" alt="${escapeHTML(dimensions?'':alias||'')}"${dimensions?` width="${Math.min(3000,Number(dimensions[1]))}"`:''}>`;}
    return `<a data-live-target="${escapeHTML(target)}">${escapeHTML(alias||target)}</a>`;
  }).replace(/\[\[([^\]\n]+)\]\]/g, (_,value) => {
    const [target,alias] = value.split('|'); return `<a data-live-target="${escapeHTML(target)}">${escapeHTML(alias||target)}</a>`;
  });
  holder.innerHTML = DOMPurify.sanitize(marked.parse(prepared,{gfm:true}), {USE_PROFILES:{html:true},FORBID_TAGS:['script','style','iframe','object','embed','form','input'],FORBID_ATTR:['style','srcset'],ALLOW_DATA_ATTR:true});
  holder.querySelectorAll('img').forEach(image => {
    const target = image.dataset.liveResource || image.getAttribute('src') || '';
    if(/\.pdf(?:#|$)/i.test(target)){const link=document.createElement('a');link.dataset.liveTarget=target;link.textContent='PDF · '+(image.alt||target.split('/').pop())+' ↗';image.replaceWith(link);return;}
    const url = resourceURL(target); image.removeAttribute('src');
    if (url) { image.src = url; image.loading = 'lazy'; }
    else image.replaceWith(document.createTextNode(image.alt));
  });
  holder.querySelectorAll('a').forEach(link => { const target = link.dataset.liveTarget || link.getAttribute('href'); link.href='#'; link.title=uiText(state,'openLinkShort'); link.addEventListener('click',event=>{event.preventDefault(); if(event.metaKey||event.ctrlKey||!metadata.editable) navigate(target||'');}); });
  const quote = holder.querySelector('blockquote');
  if (quote && /^>\s*\[!/.test(source)) {
    quote.className='callout';
    const first = quote.querySelector('p');
    if(first) first.innerHTML = first.innerHTML.replace(/^\[!([^\]]+)\][+-]?(?:[ \t]*([^\n]*))?/,(_,kind,title)=>`<strong class="callout-title">✦ ${escapeHTML(title||kind)}</strong>`);
  }
  return holder;
}
class BlockWidget extends WidgetType {
  constructor(source,from,kind,language) { super(); Object.assign(this,{source,from,kind,language}); }
  eq(other) { return this.source===other.source && this.from===other.from && this.kind===other.kind && this.language===other.language; }
  toDOM(view) {
    const holder=document.createElement('div'); holder.className='cm-live-block cm-block-'+this.kind;
    if(this.kind==='math') { const math=document.createElement('div'); try { katex.render(this.source.replace(/^\$\$\s*|\s*\$\$$/g,''),math,{displayMode:true,throwOnError:false,trust:false}); } catch {math.textContent=this.source;} holder.append(math); }
    else holder.append(fragment(this.source,view.state));
    holder.addEventListener('mousedown',event=>{
      if(event.metaKey||event.ctrlKey||!metadata.editable) return;
      event.preventDefault(); view.dispatch({selection:{anchor:this.from,head:Math.min(this.from+this.source.length,view.state.doc.length)}}); view.focus();
    }); return holder;
  }
  ignoreEvent() { return true; }
}

class CalloutKindWidget extends WidgetType {
  constructor(kind,title) {super();Object.assign(this,{kind,title});}
  eq(other) {return this.kind===other.kind&&this.title===other.title;}
  toDOM() {const label=document.createElement('span');label.className='cm-callout-kind';label.textContent=this.title?'✦ ':'✦ '+this.kind.toUpperCase();label.setAttribute('aria-hidden','true');return label;}
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

// Markdown's separator lines have no visual paragraph of their own. A newly
// created empty paragraph remains available for typing until the caret leaves.
const inputBlankField=StateField.define({
  create:state=>state.doc.toString().trim()?null:state.doc.lineAt(state.selection.main.head).from,
  update(value,tr) {
    const range=tr.state.selection.main,line=tr.state.doc.lineAt(range.head);
    if(!range.empty||line.text.trim())return null;
    if(tr.docChanged||!tr.state.doc.toString().trim())return line.from;
    const mapped=value===null?null:tr.changes.mapPos(value,1);
    return mapped===line.from?mapped:null;
  }
});
function editableBlank(state,line) {
  const selection=state.selection.main;
  return state.field(inputBlankField)===line.from||line.number===state.doc.lines&&selection.empty&&selection.head>=line.from;
}
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
    if(/(?:^| )(?:cm-code-fence|cm-table-separator)(?: |$)/.test(decoration.spec.class||''))hidden=true;
  });
  return hidden;
}
const blankSelectionFilter=EditorState.transactionFilter.of(tr=>{
  if(tr.docChanged||!tr.selection||tr.newSelection.ranges.length!==1||!tr.newSelection.main.empty)return tr;
  const state=tr.state,range=tr.newSelection.main,line=state.doc.lineAt(range.head);
  if(!hiddenSourceLine(state,line)&&(line.text.trim()||editableBlank(state,line)||literalCodeLine(state,line)))return tr;
  const direction=range.head<tr.startState.selection.main.head?-1:1;
  for(const step of [direction,-direction])for(let n=line.number+step;n>=1&&n<=state.doc.lines;n+=step) {
    const next=state.doc.line(n);
    if(!hiddenSourceLine(state,next)&&(next.text.trim()||literalCodeLine(state,next)||editableBlank(state,next)))return [tr,{selection:EditorSelection.cursor(step>0?(visiblePrefixEnd(state,next.from)??next.from):next.to),sequential:true}];
  }
  return tr;
});

function decorations(state) {
  const list=[], covered=[],quoteLines=new Set(),codeRanges=[],inlineCodeRanges=[];
  const tree=ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state);
  tree.iterate({enter(node){if(node.name==='FencedCode'||node.name==='CodeBlock'){codeRanges.push([node.from,node.to]);return false;}if(node.name==='InlineCode')inlineCodeRanges.push([node.from,node.to]);}});
  const addBlock=(from,to,kind)=>{
    if(from===to) return false;
    list.push(Decoration.replace({widget:new BlockWidget(state.doc.sliceString(from,to),from,kind,state.facet(editorLanguage)),block:true}).range(from,to)); covered.push([from,to]); return true;
  };
  // Rendering is independent of selection. Textual blocks stay in the main
  // editor, and non-text widgets remain rendered when selected.
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n);
    if(codeRanges.some(([a,b])=>line.from>=a&&line.from<b))continue;
    if(/^>\s*\[![\w-]+\]/.test(line.text)) {
      let end=n; while(end<state.doc.lines && /^>/.test(state.doc.line(end+1).text)) end++;
      for(let row=n;row<=end;row++)list.push(Decoration.line({class:'cm-callout-line'+(row===n?' cm-callout-first':'')+(row===end?' cm-callout-last':'')}).range(state.doc.line(row).from));
      const match=/^>\s*\[!([\w-]+)\][+-]?[ \t]*/.exec(line.text);
      list.push(Decoration.widget({widget:new CalloutKindWidget(match[1],!!line.text.slice(match[0].length)),side:1}).range(line.from+match[0].length));
      n=end;
    } else if(/^\s*\$\$\s*$/.test(line.text)) {
      let end=n+1; while(end<=state.doc.lines&&!/^\s*\$\$\s*$/.test(state.doc.line(end).text)) end++;
      if(end<=state.doc.lines) {addBlock(line.from,state.doc.line(end).to,'math');n=end;}
    } else if(/^\s*(?:!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]+\))\s*$/.test(line.text)) addBlock(line.from,line.to,'image');
  }
  const within=(from,to)=>covered.some(([a,b])=>from>=a&&to<=b);
  tree.iterate({enter(node){
    if(within(node.from,node.to)) return false;
    const name=node.name;
    if(name==='Blockquote') {
      const first=state.doc.lineAt(node.from).number,last=state.doc.lineAt(node.to).number;
      for(let n=first;n<=last;n++)quoteLines.add(n);
    }
    if(name==='HorizontalRule'||name==='ThematicBreak') {
      const line=state.doc.lineAt(node.from);
      list.push(Decoration.line({class:'cm-divider-line'}).range(line.from));
      list.push(Decoration.mark({class:'cm-divider-syntax'}).range(line.from,line.to));
      list.push(Decoration.widget({widget:new DividerWidget(line.from,line.to,state.facet(editorLanguage)),side:-1}).range(line.from));
      covered.push([line.from,line.to]);return false;
    }
    if(name==='Table') list.push(...tableDecorations(state,node.node));
    if(/^ATXHeading[1-6]$/.test(name)) {
      const level=name.slice(-1),line=state.doc.lineAt(node.from);
      list.push(Decoration.line({class:'cm-heading cm-heading-'+level}).range(line.from));
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
      return false;
    }
  }});
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n); if(within(line.from,line.to))continue;
    const insideCode=tree.resolveInner(line.from+Math.min(line.length,1),1); let code=false;
    for(let node=insideCode;node;node=node.parent)if(node.name==='FencedCode'||node.name==='CodeBlock')code=true;
    if(code)continue;
    if(quoteLines.has(n)) {
      list.push(Decoration.line({class:'cm-quote-line'}).range(line.from));
    }
    const task=/^(\s*)[-+*]\s+\[([ xX])\]\s*/.exec(line.text);
    const bullet=/^(\s*)(?:([-+*])\s+|(\d+)[.)]\s+)/.exec(line.text);
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
    if(!line.text.trim())list.push(Decoration.line({class:'cm-blank-line'+(editableBlank(state,line)?' cm-input-blank-line':'')}).range(line.from));
  }
  return Decoration.set(list,true);
}
const liveField=StateField.define({create:decorations,update(value,tr){return tr.docChanged||tr.selection||tr.startState.field(inputBlankField)!==tr.state.field(inputBlankField)||tr.startState.facet(editorLanguage)!==tr.state.facet(editorLanguage)||syntaxTree(tr.startState)!==syntaxTree(tr.state)?decorations(tr.state):value;},provide:field=>[EditorView.decorations.from(field),EditorView.atomicRanges.of(view=>view.state.field(field).update({filter:(_from,_to,value)=>value.spec.block===true}))]});

function boldDelimiters(state) {
  const ranges=[],tree=ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state),code=[],inline=[];
  const add=(from,to,extra={})=>{if(to>from)ranges.push(Decoration.mark({class:'cm-format-delimiter'+(extra.bold?' cm-live-bold-delimiter':''),...extra}).range(from,to));};
  tree.iterate({enter(node){
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
      const line=state.doc.lineAt(node.from),prefix=/^ {0,3}#{1,6}(?:[ \t]+|$)/.exec(line.text);
      if(prefix)add(line.from,line.from+prefix[0].length,{kind:'prefix'});
      const last=node.node.lastChild;
      if(last?.name==='HeaderMark'&&last.from>line.from+(prefix?.[0].length||0))add(last.from,last.to);
    }
    if(/^SetextHeading[12]$/.test(node.name)){const line=state.doc.lineAt(node.to);add(line.from,line.to,{kind:'fence'});}
    if(!['StrongEmphasis','Emphasis','Strikethrough','InlineCode'].includes(node.name))return;
    const first=node.node.firstChild,last=node.node.lastChild;
    if(node.name==='InlineCode')inline.push([node.from,node.to]);
    if(!first||!last||first===last)return;
    const spec={bold:node.name==='StrongEmphasis',boldFrom:node.from,boldTo:node.to,bodyFrom:first.to,bodyTo:last.from};
    add(first.from,first.to,spec);add(last.from,last.to,spec);
  }});
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n);
    if(code.some(([a,b])=>line.from>=a&&line.from<b))continue;
    const callout=/^>\s*\[![\w-]+\][+-]?[ \t]*/.exec(line.text),quote=/^ {0,3}(?:> ?)+/.exec(line.text);
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
  return Decoration.set(ranges,true);
}
function removeBlockPrefix(view) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly||!range.empty||state.selection.ranges.length!==1||inCode(state,range.head))return false;
  const line=state.doc.lineAt(range.head),prefix=/^(?: {0,3}#{1,6}(?:[ \t]+|$)| {0,3}(?:> ?)+(?:\[![\w-]+\][+-]?[ \t]*)?)/.exec(line.text);
  if(prefix&&range.head<=line.from+prefix[0].length){view.dispatch({changes:{from:line.from,to:line.from+prefix[0].length},selection:{anchor:line.from},userEvent:'delete.backward'});return true;}
  return false;
}
function visiblePrefixEnd(state,pos) {
  if(inCode(state,pos))return null;
  const line=state.doc.lineAt(pos),prefix=/^(?: {0,3}#{1,6}(?:[ \t]+|$)| {0,3}(?:> ?)+(?:\[![\w-]+\][+-]?[ \t]*)?)/.exec(line.text);
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
  update(value,tr){return tr.docChanged||syntaxTree(tr.startState)!==syntaxTree(tr.state)?boldDelimiters(tr.state):value;},
  provide:field=>[
    EditorView.decorations.from(field),
    EditorView.atomicRanges.of(view=>view.state.field(field)),
    keymap.of([{key:'Backspace',run:view=>deleteDivider(view,false)||removeBlockPrefix(view)||deleteAroundBold(view,false)},{key:'Delete',run:view=>deleteDivider(view,true)||deleteAroundBold(view,true)}])
  ]
});

function simpleListEnter(view) {
  const range=view.state.selection.main;if(!range.empty)return false;
  if(inCode(view.state,range.head))return false;
  const line=view.state.doc.lineAt(range.head),match=/^(\s*)([-+*]|\d+[.)])\s+(?:\[([ xX])\]\s*)?/.exec(line.text);
  if(!match||range.head<line.from+match[0].length)return false;
  if(!line.text.slice(match[0].length).trim()) {view.dispatch({changes:{from:line.from,to:line.to,insert:''},selection:{anchor:line.from},userEvent:'input'});return true;}
  let marker=match[2];if(/^\d/.test(marker))marker=String(parseInt(marker,10)+1)+marker.slice(-1);
  const insert='\n'+match[1]+marker+' '+(match[3]!==undefined?'[ ] ':'');
  view.dispatch(view.state.replaceSelection(insert),{scrollIntoView:true,userEvent:'input'});return true;
}
function simpleListBackspace(view) {
  const range=view.state.selection.main;if(!range.empty)return false;
  if(inCode(view.state,range.head))return false;
  const line=view.state.doc.lineAt(range.head),match=/^(\s*)(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/.exec(line.text);
  if(!match||range.head!==line.from+match[0].length)return false;
  view.dispatch({changes:{from:line.from,to:range.head,insert:match[1]},selection:{anchor:line.from+match[1].length},userEvent:'delete.backward'});return true;
}
// Chinese input methods type full-width punctuation, so "1。 " or "＊ " at the
// start of a line becomes the Markdown list marker the writer meant.
const fullWidthListFilter=EditorState.transactionFilter.of(tr=>{
  if(!tr.docChanged||!tr.isUserEvent('input')||tr.newSelection.ranges.length!==1||!tr.newSelection.main.empty)return tr;
  const state=tr.state,head=tr.newSelection.main.head,line=state.doc.lineAt(head);
  const match=/^(\s*)(?:(\d+)[。．]|([＊×・·－—]))[ 　]$/.exec(line.text.slice(0,head-line.from));
  if(!match||inCode(state,head))return tr;
  const insert=match[1]+(match[2]!==undefined?match[2]+'. ':match[3]==='－'||match[3]==='—'?'- ':'* ');
  return [tr,{changes:{from:line.from,to:head,insert},selection:{anchor:line.from+insert.length},sequential:true}];
});
function inCode(state,pos){for(let node=syntaxTree(state).resolveInner(pos,-1);node;node=node.parent)if(node.name==='FencedCode'||node.name==='CodeBlock')return true;return false;}
function extensions() {return [
  history(),drawSelection(),EditorView.lineWrapping,markdown({extensions:GFM}),syntaxHighlighting(defaultHighlightStyle),boldDelimiterField,inputBlankField,liveField,tableSelectionFilter,formatSelectionFilter,blankSelectionFilter,fullWidthListFilter,
  slashCommands(),formatToolbar(),
  localization.of(localeExtensions()),
  editability.of([EditorView.editable.of(metadata.editable),EditorState.readOnly.of(!metadata.editable)]),
  keymap.of([...tableKeymap,{key:'ArrowLeft',run:beforeBlockPrefix},{key:'Enter',run:simpleListEnter},{key:'Backspace',run:simpleListBackspace},...markdownKeymap,...defaultKeymap,...historyKeymap,indentWithTab]),
  EditorView.updateListener.of(update=>{
    if(applyingExternal)return;
    if(update.docChanged){for(const tr of update.transactions)if(tr.docChanged){applyRawChanges(tr);revision++;}lastSource=rawSource;const selection=update.state.selection.main;post({type:'change',text:rawSource,currentPath:metadata.currentPath,revision,selectionAnchor:selection.anchor,selectionHead:selection.head});}
  }),
  EditorView.domEventHandlers({click(event){const link=event.target.closest?.('[data-live-target]');if(link&&(event.metaKey||event.ctrlKey||!metadata.editable)){event.preventDefault();navigate(link.dataset.liveTarget);return true;}return false;}})
];}
const view=new EditorView({state:EditorState.create({doc:'',extensions:extensions()}),parent:document.getElementById('editor')});
window.acdianEditor=view;
window.acdianSetDocument=payload=>{
  const previousPath=metadata.currentPath,previousToken=metadata.resetToken;
  if(typeof payload.currentPath==='string')metadata.currentPath=payload.currentPath;
  if(typeof payload.title==='string'){metadata.title=payload.title;document.title=payload.title||'acdian';}
  if(typeof payload.draft==='boolean')document.documentElement.classList.toggle('draft-page',payload.draft);
  if(typeof payload.editable==='boolean')metadata.editable=payload.editable;
  if(typeof payload.language==='string')metadata.language=normalizeLanguage(payload.language);
  document.documentElement.lang=metadata.language;
  document.getElementById('editor').setAttribute('aria-label',messagesForLanguage(metadata.language).editorLabel);
  if('resetToken'in payload)metadata.resetToken=payload.resetToken;
  if(Number.isFinite(payload.fontSize))document.documentElement.style.setProperty('--editor-font-size',Math.max(12,Math.min(28,payload.fontSize))+'px');
  const hasText=typeof payload.text==='string';
  if(hasText&&(payload.text!==rawSource||previousPath!==metadata.currentPath||previousToken!==metadata.resetToken)){
    rawSource=payload.text;lastSource=rawSource;revision=0;lineBreak=rawSource.includes('\r\n')?'\r\n':rawSource.includes('\r')?'\r':'\n';rawSnapshots=new Map([[canonical(rawSource),rawSource]]);
    applyingExternal=true;view.setState(EditorState.create({doc:canonical(rawSource),extensions:extensions()}));view.dispatch({selection:EditorSelection.cursor(0)});applyingExternal=false;
  }else view.dispatch({effects:[editability.reconfigure([EditorView.editable.of(metadata.editable),EditorState.readOnly.of(!metadata.editable)]),localization.reconfigure(localeExtensions())]});
};
window.acdianGetDocument=()=>({text:rawSource,currentPath:metadata.currentPath,revision,selectionAnchor:view.state.selection.main.anchor,selectionHead:view.state.selection.main.head});
window.acdianInsertText=(text,insertionID)=>{if(insertionID&&insertions.has(insertionID))return true;if(!metadata.editable)return false;view.dispatch(view.state.replaceSelection(canonical(String(text))));if(insertionID){insertions.add(insertionID);if(insertions.size>500)insertions.delete(insertions.values().next().value);}view.focus();return true;};
window.acdianUndo=()=>undo(view);
window.acdianRedo=()=>redo(view);
window.acdianScrollTo=raw=>{
  const anchor=decode(String(raw||'').replace(/^#/,''));let pos=0,found=!anchor;
  for(let n=1;n<=view.state.doc.lines&&!found;n++){const line=view.state.doc.line(n),heading=/^#{1,6}\s+(.+?)(?:\s+#+)?$/.exec(line.text);if(heading&&(heading[1].toLowerCase()===anchor.toLowerCase()||heading[1].toLowerCase().replace(/\s+/g,'-')===anchor.toLowerCase())||line.text.endsWith(' ^'+anchor.replace(/^\^/,''))){pos=line.from;found=true;}}
  if(found)view.dispatch({selection:EditorSelection.cursor(pos),effects:EditorView.scrollIntoView(pos,{y:'start'})});return found;
};
window.acdianLiveEditorTest={simpleListEnter,simpleListBackspace,canonical,rawOffset,treeString:()=>syntaxTree(view.state).toString()};
post({type:'ready'});
