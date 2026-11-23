// What the editor draws beyond plain Markdown: coloured text and other inline
// HTML, code highlighting, Mermaid diagrams and folding.
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';
import { StateField, StateEffect } from '@codemirror/state';
import { LanguageDescription, HighlightStyle, syntaxHighlighting, syntaxTree, foldable, foldedRanges, foldEffect, unfoldEffect, codeFolding } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { javascript } from '@codemirror/lang-javascript';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { python } from '@codemirror/lang-python';
import { json } from '@codemirror/lang-json';
import { cpp } from '@codemirror/lang-cpp';
import { java } from '@codemirror/lang-java';
import { rust } from '@codemirror/lang-rust';
import { go } from '@codemirror/lang-go';
import { sql } from '@codemirror/lang-sql';
import { xml } from '@codemirror/lang-xml';
import { yaml } from '@codemirror/lang-yaml';
import { php } from '@codemirror/lang-php';

let host={post(){},uiText(){return '';},currentPath(){return '';}};
const viewOf=dom=>{const content=dom.closest?.('.cm-content');return content?EditorView.findFromDOM(content):null;};
export const configureRichText=value=>{host=value;};

// Code blocks
const language=(name,alias,load)=>LanguageDescription.of({name,alias,load:async()=>load()});
export const codeLanguages=[
  language('JavaScript',['js','jsx','node','mjs','cjs'],()=>javascript({jsx:true})),
  language('TypeScript',['ts','tsx'],()=>javascript({jsx:true,typescript:true})),
  language('HTML',['htm'],()=>html()),language('CSS',['scss','less'],()=>css()),
  language('Python',['py','python3'],()=>python()),language('JSON',['json5'],()=>json()),
  language('C++',['cpp','c','cc','h','hpp','objc','c++'],()=>cpp()),language('Java',['kotlin','scala','swift'],()=>java()),
  language('Rust',['rs'],()=>rust()),language('Go',['golang'],()=>go()),language('SQL',['mysql','postgresql','sqlite'],()=>sql()),
  language('XML',['svg','plist'],()=>xml()),language('YAML',['yml','toml'],()=>yaml()),language('PHP',[],()=>php())
];
const token=(tag,name)=>({tag,class:'cm-tok-'+name});
export const codeHighlight=syntaxHighlighting(HighlightStyle.define([
  token(tags.keyword,'keyword'),token([tags.controlKeyword,tags.moduleKeyword,tags.definitionKeyword,tags.operatorKeyword],'keyword'),
  token([tags.string,tags.special(tags.string),tags.regexp],'string'),token([tags.comment,tags.lineComment,tags.blockComment,tags.docComment],'comment'),
  token([tags.number,tags.integer,tags.float,tags.bool,tags.null,tags.atom],'number'),
  token([tags.function(tags.variableName),tags.function(tags.propertyName),tags.function(tags.definition(tags.variableName))],'function'),
  token([tags.typeName,tags.className,tags.namespace,tags.labelName],'type'),token([tags.propertyName,tags.attributeName],'property'),
  token([tags.tagName,tags.angleBracket],'tag'),token([tags.attributeValue],'string'),token([tags.operator,tags.punctuation,tags.bracket,tags.separator],'plain'),
  token([tags.variableName,tags.definition(tags.variableName),tags.meta,tags.processingInstruction],'plain')
]));
export const codePrefEffect=StateEffect.define();
export const codePrefs=StateField.define({
  create:()=>new Map(),
  update(value,tr){
    let next=value;
    if(tr.docChanged&&value.size){next=new Map();for(const [pos,pref] of value){const mapped=tr.changes.mapPos(pos,1);next.set(mapped,pref);}}
    for(const effect of tr.effects)if(effect.is(codePrefEffect)){if(next===value)next=new Map(value);next.set(effect.value.pos,{...(next.get(effect.value.pos)||{}),...effect.value.pref});}
    return next;
  }
});
const codeIcons={
  chevron:'<svg viewBox="0 0 16 16"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  caret:'<svg viewBox="0 0 16 16"><path d="M4.5 6.5L8 10l3.5-3.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  wrap:'<svg viewBox="0 0 16 16"><path d="M2.5 4h11M2.5 8h9a2 2 0 010 4H8m1.5-1.5L8 12l1.5 1.5M2.5 12h3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  copy:'<svg viewBox="0 0 16 16"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M10.5 3.5v-.5a1 1 0 00-1-1h-6a1 1 0 00-1 1v6a1 1 0 001 1h.5" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>',
  check:'<svg viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
};
const extraLanguages=['Bash','Shell','Markdown','Swift','Kotlin','Ruby','Dockerfile','Diff','Text'];
const languageNames=()=>[...new Set([...codeLanguages.map(l=>l.name),...extraLanguages])].sort((a,b)=>a.localeCompare(b));
const languageLabel=(name,state)=>{
  if(!name)return host.uiText(state,'plainText');
  const known=codeLanguages.find(l=>l.name.toLowerCase()===name.toLowerCase()||l.alias.includes(name.toLowerCase()));
  return known?known.name:extraLanguages.find(l=>l.toLowerCase()===name.toLowerCase())||name;
};
function fenceAt(view,dom) {
  const pos=view.posAtDOM(dom),line=view.state.doc.lineAt(Math.max(0,pos-1));
  for(let node=syntaxTree(view.state).resolveInner(line.from,1);node;node=node.parent)if(node.name==='FencedCode')return node;
  for(let node=syntaxTree(view.state).resolveInner(pos,-1);node;node=node.parent)if(node.name==='FencedCode')return node;
  return null;
}
function openLanguageMenu(view,button,dom) {
  document.querySelector('.cm-code-menu')?.remove();
  const menu=document.createElement('div');menu.className='cm-code-menu';
  const search=document.createElement('input');search.type='text';search.placeholder=host.uiText(view.state,'searchLanguage');search.spellcheck=false;
  const list=document.createElement('div');list.className='cm-code-menu-list';
  const node=fenceAt(view,dom);if(!node)return;
  const fence=view.state.doc.lineAt(node.from),match=/^(\s*(?:`{3,}|~{3,}))\s*([^\s`]*)/.exec(fence.text),current=match?match[2]:'';
  const currentLabel=languageLabel(current,view.state);
  const choices=[{label:host.uiText(view.state,'plainText'),value:''},...languageNames().filter(n=>n!=='Text').map(n=>({label:n,value:n.toLowerCase()}))];
  const close=()=>{menu.remove();window.removeEventListener('mousedown',outside,true);window.removeEventListener('keydown',key,true);};
  const outside=event=>{if(!menu.contains(event.target)&&event.target!==button)close();};
  const key=event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();}};
  const choose=value=>{
    const fresh=view.state.doc.lineAt(node.from),m=/^(\s*(?:`{3,}|~{3,}))(\s*)([^\s`]*)/.exec(fresh.text);
    if(m)view.dispatch({changes:{from:fresh.from+m[1].length,to:fresh.from+m[0].length,insert:value},userEvent:'input'});
    close();view.focus();
  };
  const render=()=>{
    const q=search.value.trim().toLowerCase();list.textContent='';
    for(const choice of choices.filter(c=>!q||c.label.toLowerCase().includes(q))) {
      const item=document.createElement('button');item.type='button';item.className='cm-code-menu-item';
      const on=choice.label===currentLabel;item.innerHTML=`<span></span>${on?codeIcons.check:''}`;item.firstChild.textContent=choice.label;if(on)item.classList.add('cm-code-menu-on');
      item.addEventListener('mousedown',event=>event.preventDefault());item.addEventListener('click',()=>choose(choice.value));
      list.append(item);
    }
  };
  search.addEventListener('input',render);
  search.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();list.querySelector('button')?.click();}});
  menu.append(search,list);render();document.body.append(menu);
  const rect=button.getBoundingClientRect();menu.style.left=Math.max(8,Math.min(innerWidth-menu.offsetWidth-8,rect.right-menu.offsetWidth))+'px';menu.style.top=rect.bottom+4+'px';
  setTimeout(()=>{window.addEventListener('mousedown',outside,true);window.addEventListener('keydown',key,true);search.focus();});
}
class CodeHeadWidget extends WidgetType {
  constructor(name,pos,wrap,folded) { super(); this.name=name; this.pos=pos; this.wrap=wrap; this.folded=folded; }
  eq(other) { return this.name===other.name&&this.pos===other.pos&&this.wrap===other.wrap&&this.folded===other.folded; }
  toDOM(view) {
    const state=view.state,head=document.createElement('div');head.className='cm-code-head'+(this.folded?' cm-code-head-folded':'');head.contentEditable='false';
    const button=(cls,html,text)=>{const b=document.createElement('button');b.type='button';b.className=cls;b.innerHTML=html;if(text!==undefined){const t=document.createElement('span');t.textContent=text;b.append(t);}b.addEventListener('mousedown',event=>event.preventDefault());return b;};
    const fold=button('cm-code-fold',codeIcons.chevron,host.uiText(state,'codeBlock'));
    fold.addEventListener('click',()=>view.dispatch({effects:codePrefEffect.of({pos:this.pos,pref:{folded:!this.folded}})}));
    const lang=button('cm-code-lang','',languageLabel(this.name,state));lang.insertAdjacentHTML('beforeend',codeIcons.caret);
    lang.addEventListener('click',()=>{if(view.state.facet(EditorView.editable))openLanguageMenu(view,lang,head);});
    const wrap=button('cm-code-wrapper',codeIcons.wrap,host.uiText(state,this.wrap?'codeUnwrap':'codeWrap'));
    wrap.addEventListener('click',()=>view.dispatch({effects:codePrefEffect.of({pos:this.pos,pref:{wrap:!this.wrap}})}));
    const copy=button('cm-code-copy',codeIcons.copy,host.uiText(state,'copy'));
    copy.addEventListener('click',()=>{
      const node=fenceAt(view,head);if(!node)return;
      const text=node.getChild('CodeText');host.post({type:'copy',text:text?view.state.sliceDoc(text.from,text.to):''});
      copy.lastChild.textContent=host.uiText(view.state,'copied');setTimeout(()=>{copy.lastChild.textContent=host.uiText(view.state,'copy');},1200);
    });
    const sep=()=>{const s=document.createElement('span');s.className='cm-code-sep';return s;};
    const tools=document.createElement('div');tools.className='cm-code-actions';tools.append(lang,sep(),wrap,sep(),copy);
    head.append(fold,tools);return head;
  }
  ignoreEvent() { return true; }
}
class CodeFoldWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const d=document.createElement('div');d.className='cm-code-folded-body';return d; }
  ignoreEvent() { return true; }
}
export const codeHead=(name,pos,wrap,folded)=>Decoration.widget({widget:new CodeHeadWidget(name,pos,wrap,folded),block:true,side:1});
export const codeFolded=()=>Decoration.replace({widget:new CodeFoldWidget(),block:true});

// Inline HTML: coloured text, underline, sub- and superscript and so on. Only
// plain colours and text styling get through; the tags hide unless the caret
// is right beside one, so a selection never shows them.
const safeValue=value=>/^[#\w\s.,%()/-]+$/.test(value)&&!/url|expression|javascript/i.test(value);
export function safeStyle(style,allowed) {
  return style.split(';').map(part=>{
    const at=part.indexOf(':');if(at<0)return '';
    const name=part.slice(0,at).trim().toLowerCase(),value=part.slice(at+1).trim();
    return allowed.has(name)&&safeValue(value)?name+':'+value:'';
  }).filter(Boolean).join(';');
}
const inlineProperties=new Set(['color','background','background-color','font-weight','font-style','font-size','text-decoration','text-decoration-color']);
const blockProperties=new Set([...inlineProperties,'text-align','display','flex','flex-direction','flex-wrap','gap','grid-template-columns','width','max-width','min-width','height','padding','padding-left','padding-right','padding-top','padding-bottom','margin','margin-left','margin-right','margin-top','margin-bottom','border','border-left','border-right','border-top','border-bottom','border-radius','border-color','vertical-align']);
export const safeBlockStyle=style=>safeStyle(style,blockProperties);
function inlineAttributes(name,attrs) {
  const quoted=key=>new RegExp('\\b'+key+'\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))','i').exec(attrs),value=match=>match&&(match[1]??match[2]??match[3]);
  let style=safeStyle(value(quoted('style'))||'',inlineProperties);
  if(name==='font') { const color=value(quoted('color'));if(color&&safeValue(color))style+=(style?';':'')+'color:'+color; }
  return style?{style}:{};
}
class BreakWidget extends WidgetType {
  eq() { return true; }
  toDOM() { return document.createElement('br'); }
}
export function inlineHTML(text,base,touched,skipped,list) {
  if(!text.includes('<'))return;
  const open=[];
  for(const match of text.matchAll(/<(\/?)(span|font|u|ins|mark|sub|sup|kbd|b|strong|i|em|s|del|small)\b([^<>]*)>|<br\s*\/?>/gi)) {
    const from=base+match.index,to=from+match[0].length;
    if(skipped(from,to))continue;
    if(!match[2]) { if(!touched(from,to))list.push(Decoration.replace({widget:new BreakWidget()}).range(from,to)); continue; }
    const name=match[2].toLowerCase();
    if(!match[1]) { if(!match[3].endsWith('/'))open.push({name,from,to,attrs:match[3]}); continue; }
    let at=open.length-1; while(at>=0&&open[at].name!==name)at--;
    if(at<0)continue;
    const start=open[at];open.length=at;
    if(start.to===from)continue;
    list.push(Decoration.mark({class:'cm-html-'+name,attributes:inlineAttributes(name,start.attrs)}).range(start.from,to));
    if(!touched(start.from,start.to)&&!touched(from,to)) {
      // Marked, not replaced: an element in place of a tag would offer a place to break the line.
      const hide=(a,b)=>list.push(Decoration.mark({class:'cm-format-delimiter'+(a>base&&b<base+text.length?' cm-hidden-syntax':'')}).range(a,b));
      hide(start.from,start.to);hide(from,to);
    }
  }
}

// Mermaid loads the first time a page has a diagram.
let mermaidLibrary,mermaidSerial=0;
const mermaidImages=new Map();
function loadMermaid() {
  return mermaidLibrary??=new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src='vendor/mermaid.min.js';
    script.onload=()=>resolve(window.mermaid);script.onerror=reject;document.head.append(script);
  });
}
const mermaidTheme=()=>document.documentElement.classList.contains('light')?'default':'dark';
async function drawMermaid(holder) {
  const code=holder.dataset.code,theme=mermaidTheme(),key=theme+'\n'+code;
  try {
    if(!mermaidImages.has(key)) {
      const mermaid=await loadMermaid();
      mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme,fontFamily:'-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif'});
      const id='acdian-mermaid-'+(++mermaidSerial);
      try { mermaidImages.set(key,(await mermaid.render(id,code)).svg); }
      finally { document.getElementById('d'+id)?.remove(); }
      if(mermaidImages.size>50)mermaidImages.delete(mermaidImages.keys().next().value);
    }
    if(holder.dataset.code!==code)return;
    holder.classList.remove('cm-mermaid-error');
    holder.innerHTML=mermaidImages.get(key);
  } catch(error) {
    holder.classList.add('cm-mermaid-error');
    holder.textContent=(error?.message||String(error))+'\n\n'+code;
  }
  viewOf(holder)?.requestMeasure();
}
new MutationObserver(()=>{for(const holder of document.querySelectorAll('.cm-mermaid'))drawMermaid(holder);}).observe(document.documentElement,{attributes:true,attributeFilter:['class']});
export class MermaidWidget extends WidgetType {
  constructor(code,language) { super(); this.code=code; this.language=language; }
  eq(other) { return this.code===other.code&&this.language===other.language; }
  get estimatedHeight() { return 240; }
  toDOM(view) {
    const wrap=document.createElement('div'); wrap.className='cm-live-block-wrap';
    const holder=document.createElement('div'); holder.className='cm-live-block cm-mermaid'; holder.dataset.code=this.code;
    holder.title=host.uiText(view.state,'doubleClickEdit');
    holder.addEventListener('dblclick',event=>{ event.preventDefault(); const pos=view.posAtDOM(wrap); view.dispatch({selection:{anchor:view.state.doc.lineAt(pos).to+1}}); view.focus(); });
    wrap.append(holder); drawMermaid(holder); return wrap;
  }
  ignoreEvent() { return true; }
}

// Folding: an arrow beside a heading or a callout's first line.
const foldableLine=/^(?: {0,3}#{1,6}[ \t]+\S|>\s*\[![\w-]+(?:\|[^\]\n]*)?\])/;
class FoldToggleWidget extends WidgetType {
  constructor(folded) { super(); this.folded=folded; }
  eq(other) { return this.folded===other.folded; }
  toDOM(view) {
    const toggle=document.createElement('span'); toggle.className='cm-fold-toggle'+(this.folded?' cm-fold-closed':''); toggle.textContent='▾'; toggle.contentEditable='false'; toggle.setAttribute('aria-hidden','true');
    toggle.addEventListener('mousedown',event=>{
      event.preventDefault();
      const line=view.state.doc.lineAt(view.posAtDOM(toggle));
      const folded=[];foldedRanges(view.state).between(line.to,line.to+1,(from,to)=>{if(from===line.to)folded.push({from,to});});
      if(folded.length)view.dispatch({effects:folded.map(range=>unfoldEffect.of(range))});
      else { const range=foldable(view.state,line.from,line.to); if(range)view.dispatch({effects:foldEffect.of(range)}); }
    });
    return toggle;
  }
  ignoreEvent() { return true; }
}
function foldToggles(view) {
  const state=view.state,list=[];
  for(const {from,to} of view.visibleRanges) for(let pos=from;pos<=to;) {
    const line=state.doc.lineAt(pos);
    if(foldableLine.test(line.text)) {
      let folded=false;foldedRanges(state).between(line.to,line.to+1,start=>{if(start===line.to)folded=true;});
      if(folded||foldable(state,line.from,line.to))list.push(Decoration.widget({widget:new FoldToggleWidget(folded),side:-1}).range(line.from));
    }
    pos=line.to+1;
  }
  return Decoration.set(list);
}
export const folding=[
  codeFolding({placeholderText:'…'}),
  ViewPlugin.fromClass(class {
    constructor(view) { this.decorations=foldToggles(view); }
    update(update) { if(update.docChanged||update.viewportChanged||update.transactions.some(tr=>tr.effects.some(effect=>effect.is(foldEffect)||effect.is(unfoldEffect)))||syntaxTree(update.startState)!==syntaxTree(update.state))this.decorations=foldToggles(update.view); }
  },{decorations:plugin=>plugin.decorations})
];
// Callouts written "[!kind]-" start folded.
export function startFolded(state) {
  const effects=[],doc=state.doc;
  if(!doc.toString().includes(']-'))return effects;
  for(let n=1;n<=doc.lines;n++) {
    const line=doc.line(n);
    if(!/^>\s*\[![\w-]+(?:\|[^\]\n]*)?\]-/.test(line.text))continue;
    let end=n; while(end<doc.lines&&/^>/.test(doc.line(end+1).text))end++;
    if(end>n)effects.push(foldEffect.of({from:line.to,to:doc.line(end).to}));
    n=end;
  }
  return effects;
}

// Pictures: a frame with handles that change the width kept in the Markdown, a
// message when the file is missing, and a large view on double click.
export const imageWidthless=source=>source.replace(/\|\d+(?:x\d+)?(?=\]\]|\]\()/,'');
export function withImageWidth(source,width) {
  const plain=imageWidthless(source);
  if(/\]\]\s*$/.test(plain))return plain.replace(/\]\](\s*)$/,`|${width}]]$1`);
  return plain.replace(/\]\(/,`|${width}](`);
}
// A picture's caption is its alt text: ![caption|300](file) or ![[file|300|caption]].
export function withImageCaption(source,caption) {
  const clean=caption.replace(/[\[\]|]/g,'').replace(/\s+/g,' ').trim();
  return source.replace(/!\[\[([^\]\n]+)\]\]|!\[([^\]\n]*)\]\(([^)\n]+)\)/,(whole,embed,alt,src)=>{
    if(embed!==undefined){const [target,...rest]=embed.split('|'),size=rest.find(part=>/^\d+(?:x\d+)?$/.test(part));return '![['+[target,size,clean].filter(Boolean).join('|')+']]';}
    const sized=/^(.*?)\|?(\d+(?:x\d+)?)$/.exec(alt);
    return '!['+[clean,sized?sized[2]:''].filter(Boolean).join('|')+']('+src+')';
  });
}
// Under a picture on its own line: its caption, or a faint "Add a caption" while
// the pointer is over it. A click edits it in place; Enter keeps it, Esc does not.
function measure(image) { viewOf(image)?.requestMeasure(); }
function removeImage(view,image) {
  const at=view.posAtDOM(image),line=view.state.doc.lineAt(at),own=/^\s*(?:!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]+\))\s*$/.test(line.text);
  if(own){view.dispatch({changes:{from:line.from,to:Math.min(line.to+1,view.state.doc.length)},userEvent:'delete'});return;}
  const inline=/^!\[\[[^\]]+\]\]|^!\[[^\]]*\]\([^)]+\)/.exec(view.state.sliceDoc(at,line.to));
  if(inline)view.dispatch({changes:{from:at,to:at+inline[0].length},userEvent:'delete'});
}
function openImageMenu(event,image,state) {
  event.preventDefault();event.stopPropagation();
  document.querySelector('.cm-image-menu')?.dispatchEvent(new Event('close'));
  const view=viewOf(image),menu=document.createElement('div');menu.className='cm-image-menu';menu.setAttribute('role','menu');
  const close=()=>{menu.remove();window.removeEventListener('mousedown',outside,true);window.removeEventListener('keydown',key,true);};
  const outside=down=>{if(!menu.contains(down.target))close();};
  const key=pressed=>{if(pressed.key==='Escape'){pressed.preventDefault();pressed.stopPropagation();close();}};
  const item=(name,run,className='')=>{
    const button=document.createElement('button');button.type='button';button.setAttribute('role','menuitem');button.textContent=host.uiText(state,name);button.className=className;button.dataset.action=name;
    button.addEventListener('mousedown',down=>down.preventDefault());
    button.addEventListener('click',()=>{close();run();});
    menu.append(button);
  };
  item('viewImage',()=>showLarge(image));
  const target=image.dataset.liveResource||'';
  item('copyImage',()=>host.post({type:'copyImage',target,currentPath:host.currentPath()}));
  item('revealImage',()=>host.post({type:'revealImage',target,currentPath:host.currentPath()}));
  if(view?.state.facet(EditorView.editable))item('deleteImage',()=>removeImage(view,image),'cm-image-menu-danger');
  document.body.append(menu);
  const size=menu.getBoundingClientRect();
  menu.style.left=Math.max(8,Math.min(event.clientX,innerWidth-size.width-8))+'px';
  menu.style.top=Math.max(8,Math.min(event.clientY,innerHeight-size.height-8))+'px';
  window.addEventListener('mousedown',outside,true);window.addEventListener('keydown',key,true);
}
function watchImage(image,state) {
  image.addEventListener('contextmenu',event=>openImageMenu(event,image,state));
  image.addEventListener('load',()=>measure(image));
  image.addEventListener('error',()=>{
    const missing=document.createElement('span');missing.className='cm-image-missing';
    missing.textContent=host.uiText(state,'imageMissing')+(image.dataset.liveResource?.split('/').pop()||'');
    const place=image.closest('.cm-image-frame')||image;
    place.style.display='none';place.after(missing);measure(image);
  });
}
function resize(event,image,side) {
  event.preventDefault();event.stopPropagation();
  const view=viewOf(image),block=image.closest('.cm-live-block');
  if(!view||!block)return;
  const startX=event.clientX,startWidth=image.getBoundingClientRect().width,limit=block.clientWidth;
  // The picture stays centred, so each side moves by the distance dragged.
  const widthAt=x=>Math.round(Math.min(limit,Math.max(40,startWidth+(x-startX)*side*2)));
  const move=moved=>{image.style.width=widthAt(moved.clientX)+'px';};
  const up=moved=>{
    window.removeEventListener('mousemove',move);window.removeEventListener('mouseup',up);
    const width=widthAt(moved.clientX),from=view.posAtDOM(block),line=view.state.doc.lineAt(from);
    if(width===Math.round(startWidth))return;
    const insert=withImageWidth(view.state.sliceDoc(line.from,line.to),width);
    view.dispatch({changes:{from:line.from,to:line.to,insert},selection:{anchor:line.from,head:line.from+insert.length},userEvent:'input'});
  };
  window.addEventListener('mousemove',move);window.addEventListener('mouseup',up);
}
function showLarge(image) {
  const cover=document.createElement('div');cover.className='cm-image-large';
  const large=document.createElement('img');large.src=image.src;large.alt=image.alt;large.draggable=false;cover.append(large);
  let scale=1,x=0,y=0;
  const apply=()=>{large.style.transform=`translate(${x}px,${y}px) scale(${scale})`;cover.classList.toggle('cm-image-zoomed',scale>1);};
  const zoomAt=(factor,cx,cy)=>{
    const next=Math.min(8,Math.max(1,scale*factor));if(next===scale)return;
    const rect=cover.getBoundingClientRect(),ox=cx-rect.left-rect.width/2,oy=cy-rect.top-rect.height/2;
    x=ox-(ox-x)*next/scale;y=oy-(oy-y)*next/scale;scale=next;if(scale===1){x=0;y=0;}apply();
  };
  const close=()=>{cover.remove();window.removeEventListener('keydown',key,true);};
  const key=event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();}};
  cover.addEventListener('wheel',event=>{event.preventDefault();if(event.ctrlKey||scale===1)zoomAt(Math.exp(-event.deltaY*(event.ctrlKey?0.01:0.002)),event.clientX,event.clientY);else{x-=event.deltaX;y-=event.deltaY;apply();}},{passive:false});
  cover.addEventListener('mousedown',event=>{
    event.preventDefault();
    const sx=event.clientX,sy=event.clientY,bx=x,by=y;let moved=false;
    const move=e=>{if(Math.hypot(e.clientX-sx,e.clientY-sy)>4)moved=true;if(moved&&scale>1){x=bx+e.clientX-sx;y=by+e.clientY-sy;apply();}};
    const up=e=>{window.removeEventListener('mousemove',move);window.removeEventListener('mouseup',up);if(moved)return;if(e.target===large)zoomAt(scale>1?1/scale:2.5,e.clientX,e.clientY);else close();};
    window.addEventListener('mousemove',move);window.addEventListener('mouseup',up);
  });
  window.addEventListener('keydown',key,true);document.body.append(cover);
}
// Dragging a picture moves its line in the page. Tables, code, quotes and lists
// stay whole: a drop on one lands before or after it.
const wholeBlocks=new Set(['Table','FencedCode','CodeBlock','Blockquote','BulletList','OrderedList','HTMLBlock']);
function dropPlace(view,clientY) {
  const state=view.state,doc=state.doc,block=view.lineBlockAtHeight(clientY-view.documentTop);
  let from=block.from,to=block.to;
  for(let node=syntaxTree(state).resolveInner(from,1);node;node=node.parent)if(wholeBlocks.has(node.name)){from=Math.min(from,node.from);to=Math.max(to,node.to);}
  const first=doc.lineAt(from),last=doc.lineAt(to);
  const top=view.lineBlockAt(first.from).top+view.documentTop,bottom=view.lineBlockAt(last.from).bottom+view.documentTop;
  const after=clientY>(top+bottom)/2;
  return {pos:after?(last.number<doc.lines?doc.line(last.number+1).from:doc.length):first.from,y:after?bottom:top};
}
function moveLine(view,number,target) {
  const state=view.state,doc=state.doc,line=doc.line(number);
  if(target>=line.from&&target<=Math.min(line.to+1,doc.length))return;
  // The blank line that set the picture apart goes with it.
  const blank=n=>n>=1&&n<=doc.lines&&!doc.line(n).text.trim();
  let from=line.from,to=line.to;
  if(to<doc.length)to++; else if(from>0)from--;
  if(blank(number-1)&&blank(number+1)&&!(target>to&&target<=doc.line(number+1).to+1))to=Math.min(doc.length,doc.line(number+1).to+1);
  const atEnd=target===doc.length&&doc.sliceString(doc.length-1)!=='\n',insert=(atEnd?'\n':'')+line.text+(atEnd?'':'\n');
  const changes=state.changes([{from,to},{from:target,insert}]),anchor=changes.mapPos(target,-1)+(atEnd?1:0);
  view.dispatch({changes,selection:{anchor,head:anchor+line.text.length},userEvent:'move.line'});
}
function moveImage(event,image) {
  const view=viewOf(image),holder=image.closest('.cm-live-block');
  if(event.button!==0||!view||!holder||!view.state.facet(EditorView.editable))return;
  const startX=event.clientX,startY=event.clientY;
  let ghost=null,bar=null,scroller=null,place=null,lastY=startY;
  const show=()=>{
    place=dropPlace(view,lastY);
    const content=view.contentDOM.getBoundingClientRect(),style=getComputedStyle(view.contentDOM);
    bar.style.top=place.y-1+'px';bar.style.left=content.left+parseFloat(style.paddingLeft)+'px';bar.style.width=content.width-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight)+'px';
  };
  const begin=()=>{
    image.cmDragged=true;holder.classList.add('cm-image-moving');document.documentElement.classList.add('cm-image-dragging');
    ghost=document.createElement('img');ghost.className='cm-image-ghost';ghost.src=image.src;ghost.style.width=Math.min(220,image.getBoundingClientRect().width)+'px';
    bar=document.createElement('div');bar.className='cm-image-drop';
    document.body.append(ghost,bar);
    // Near the top or bottom of the page it scrolls by itself.
    scroller=setInterval(()=>{
      const area=view.scrollDOM.getBoundingClientRect(),edge=48;
      const step=lastY<area.top+edge?-14:lastY>area.bottom-edge?14:0;
      if(step){view.scrollDOM.scrollTop+=step;show();}
    },30);
  };
  const move=moved=>{
    if(!ghost&&Math.hypot(moved.clientX-startX,moved.clientY-startY)<5)return;
    if(!ghost)begin();
    lastY=moved.clientY;
    ghost.style.left=moved.clientX+'px';ghost.style.top=moved.clientY+'px';
    show();
  };
  const finish=commit=>{
    window.removeEventListener('mousemove',move);window.removeEventListener('mouseup',up);window.removeEventListener('keydown',key,true);
    if(!ghost)return;
    clearInterval(scroller);ghost.remove();bar.remove();holder.classList.remove('cm-image-moving');document.documentElement.classList.remove('cm-image-dragging');
    if(commit&&place)moveLine(view,view.state.doc.lineAt(view.posAtDOM(holder)).number,place.pos);
  };
  const up=()=>finish(true);
  const key=pressed=>{if(pressed.key==='Escape'&&ghost){pressed.preventDefault();pressed.stopPropagation();finish(false);}};
  window.addEventListener('mousemove',move);window.addEventListener('mouseup',up);window.addEventListener('keydown',key,true);
}
export function frameImage(image,state) {
  watchImage(image,state);
  image.draggable=false;
  image.addEventListener('mousedown',event=>moveImage(event,image));
  const frame=document.createElement('span');frame.className='cm-image-frame';
  image.replaceWith(frame);frame.append(image);
  for(const side of [-1,1]) {
    const handle=document.createElement('span');handle.className='cm-image-handle '+(side<0?'cm-image-handle-left':'cm-image-handle-right');
    handle.addEventListener('mousedown',event=>resize(event,image,side));
    frame.append(handle);
  }
  image.addEventListener('click',event=>{if(image.cmDragged){image.cmDragged=false;return;}if(event.button===0){event.preventDefault();showLarge(image);}});
}
const parseEmbed=value=>{
  const [target,...rest]=value.split('|');
  const size=rest.find(part=>/^\d+(?:x\d+)?$/.test(part));
  return {target,width:size?Math.min(3000,parseInt(size,10)):null,caption:rest.find(part=>!/^\d+(?:x\d+)?$/.test(part))||''};
};
export {parseEmbed};
// A picture inside a line of text sits in the line.
export class InlineImageWidget extends WidgetType {
  constructor(url,target,width) { super(); Object.assign(this,{url,target,width}); }
  eq(other) { return this.url===other.url&&this.width===other.width; }
  toDOM(view) {
    const image=document.createElement('img');image.className='cm-inline-image';image.src=this.url;image.dataset.liveResource=this.target;
    if(this.width)image.width=this.width;
    watchImage(image,view.state);
    return image;
  }
}

// Callouts: an icon on the first line, which opens a choice of icons and colours.
// Both are kept in the Markdown as > [!kind|icon], which other editors read as a callout.
export const calloutHeader=/^>\s*\[!([\w-]+)(?:\|([^\]\n]*))?\][+-]?[ \t]*/;
const calloutEmoji='💡 📝 📌 ⭐️ 🔥 ✅ ❌ ⚠️ ❗ ❓ ℹ️ 🔔 🎯 🚀 💬 📖 📚 🧠 🔍 🧪 🧮 🔢 📊 📈 🧬 ⚛️ 🌍 🌱 🕒 📅 🎉 🏆 👍 👎 ❤️ 🙂 🤔 😀 😎 🤖 🛠️ 🔒 🔑 📎 🎵 🎨 ✏️ 🗂️'.split(' ');
const calloutColors=[['note','#d93b86'],['idea','#e0943a'],['tip','#3fae6b'],['info','#4c9be8'],['danger','#e0524d'],['question','#9b6fe0'],['quote','#8d8695']];
function headerLine(view,icon) {
  let number=view.state.doc.lineAt(view.posAtDOM(icon)).number;
  while(number>1&&!calloutHeader.test(view.state.doc.line(number).text)&&/^>/.test(view.state.doc.line(number-1).text))number--;
  return number;
}
function setCallout(view,number,kind,emoji) {
  const line=view.state.doc.line(number),match=/^(>\s*\[!)([\w-]+)(?:\|([^\]\n]*))?\]/.exec(line.text);
  if(!match)return;
  const insert=`${match[1]}${kind??match[2]}${emoji??match[3]?`|${emoji??match[3]}`:''}]`;
  view.dispatch({changes:{from:line.from,to:line.from+match[0].length,insert},userEvent:'input'});
}
function openCalloutPicker(view,icon) {
  document.querySelector('.cm-callout-picker')?.dispatchEvent(new Event('close'));
  const number=headerLine(view,icon),panel=document.createElement('div');panel.className='cm-callout-picker';
  const colors=document.createElement('div');colors.className='cm-callout-picker-colors';
  const current=()=>calloutHeader.exec(view.state.doc.line(number).text)?.[1];
  const close=()=>{panel.remove();window.removeEventListener('mousedown',outside,true);window.removeEventListener('keydown',key,true);};
  const outside=event=>{if(!panel.contains(event.target))close();};
  const key=event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();}};
  for(const [kind,color] of calloutColors) {
    const dot=document.createElement('button');dot.type='button';dot.style.background=color;dot.dataset.kind=kind;dot.setAttribute('aria-label',kind);
    dot.classList.toggle('cm-callout-picker-on',current()===kind);
    dot.addEventListener('mousedown',event=>event.preventDefault());
    dot.addEventListener('click',()=>{setCallout(view,number,kind,null);for(const other of colors.children)other.classList.toggle('cm-callout-picker-on',other===dot);});
    colors.append(dot);
  }
  const grid=document.createElement('div');grid.className='cm-callout-picker-grid';
  for(const emoji of calloutEmoji) {
    const choice=document.createElement('button');choice.type='button';choice.textContent=emoji;
    choice.addEventListener('mousedown',event=>event.preventDefault());
    choice.addEventListener('click',()=>{setCallout(view,number,null,emoji);close();});
    grid.append(choice);
  }
  panel.append(colors,grid);panel.addEventListener('close',close);
  document.body.append(panel);
  const at=icon.getBoundingClientRect(),size=panel.getBoundingClientRect();
  panel.style.left=Math.max(8,Math.min(at.left,innerWidth-size.width-8))+'px';
  panel.style.top=(at.bottom+size.height+8<innerHeight?at.bottom+4:Math.max(8,at.top-size.height-4))+'px';
  window.addEventListener('mousedown',outside,true);window.addEventListener('keydown',key,true);
}
export class CalloutIconWidget extends WidgetType {
  constructor(emoji,kind) { super(); this.emoji=emoji; this.kind=kind; }
  eq(other) { return this.emoji===other.emoji&&this.kind===other.kind; }
  toDOM(view) {
    const icon=document.createElement('span');icon.className='cm-callout-icon';icon.textContent=this.emoji;icon.contentEditable='false';icon.title=host.uiText(view.state,'calloutIcon');
    icon.addEventListener('mousedown',event=>{event.preventDefault();if(view.state.facet(EditorView.editable))openCalloutPicker(view,icon);});
    return icon;
  }
  ignoreEvent() { return true; }
}

// [TOC]: the page's headings, listed where it is written. A click goes to one.
export class TocWidget extends WidgetType {
  constructor(entries) { super(); this.entries=entries; }
  eq(other) { return JSON.stringify(this.entries)===JSON.stringify(other.entries); }
  toDOM(view) {
    const wrap=document.createElement('div');wrap.className='cm-live-block-wrap';
    const block=document.createElement('nav');block.className='cm-live-block cm-toc';block.title=host.uiText(view.state,'doubleClickEdit');
    const title=document.createElement('div');title.className='cm-toc-title';title.textContent=host.uiText(view.state,'toc');block.append(title);
    if(!this.entries.length){const empty=document.createElement('div');empty.className='cm-toc-empty';empty.textContent=host.uiText(view.state,'tocEmpty');block.append(empty);}
    const top=Math.min(...this.entries.map(entry=>entry.level));
    this.entries.forEach((entry,index)=>{
      const link=document.createElement('button');link.type='button';link.textContent=entry.text;link.style.paddingLeft=(entry.level-top)*1.2+'em';
      link.addEventListener('mousedown',event=>event.preventDefault());
      link.addEventListener('click',()=>{
        const pos=host.headings(view.state)[index];
        if(pos!==undefined)view.dispatch({effects:EditorView.scrollIntoView(pos,{y:'start',yMargin:24})});
      });
      block.append(link);
    });
    block.addEventListener('dblclick',event=>{event.preventDefault();view.dispatch({selection:{anchor:view.posAtDOM(wrap)+1}});view.focus();});
    wrap.append(block);return wrap;
  }
  ignoreEvent() { return true; }
}

// Chinese has no spaces, so a browser breaks a line between any two characters,
// even inside a word: 网 at the end of one line, 络 at the start of the next. Each
// word is kept whole instead, along with the punctuation that has to stay with it.
const han=/[\u3400-\u9fff\uf900-\ufaff]/;
const wordFinder=typeof Intl!=='undefined'&&Intl.Segmenter?new Intl.Segmenter('zh',{granularity:'word'}):null;
const afterWord=/^(?:\*{1,3}|_{1,3}|~~|==|`|\]\([^)\n]*\)|\]\])*[）」』】》〉〕。，、；：！？”’)\]]+/;
const beforeWord=/[（「『【《〈〔“‘(\[]+(?:\*{1,3}|_{1,3}|~~|==|`|\[{1,2})*$/;
const wordCache=new Map();
export function wordRanges(text) {
  if(!wordFinder||!han.test(text))return [];
  const kept=wordCache.get(text);
  if(kept)return kept;
  const ranges=[];let last=0;
  for(const {segment,index,isWordLike} of wordFinder.segment(text)) {
    if(!isWordLike||segment.length<2||!han.test(segment))continue;
    let from=index,to=index+segment.length;
    const after=afterWord.exec(text.slice(to,to+200));if(after)to+=after[0].length;
    const before=beforeWord.exec(text.slice(Math.max(0,from-12),from));if(before)from-=before[0].length;
    from=Math.max(from,last);
    if(to>from){ranges.push([from,to]);last=to;}
  }
  if(wordCache.size>3000)wordCache.clear();
  wordCache.set(text,ranges);
  return ranges;
}
const wholeWord=Decoration.mark({class:'cm-whole-word'});
export function keepWords(text,base,skipped,list) {
  for(const [from,to] of wordRanges(text))if(!skipped(base+from,base+to))list.push(wholeWord.range(base+from,base+to));
}
