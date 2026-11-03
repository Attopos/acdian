// What the editor draws beyond plain Markdown: coloured text and other inline
// HTML, code highlighting, Mermaid diagrams and folding.
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';
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

let host={post(){},uiText(){return '';}};
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
class CodeToolsWidget extends WidgetType {
  constructor(name) { super(); this.name=name; }
  eq(other) { return this.name===other.name; }
  toDOM(view) {
    const tools=document.createElement('span'); tools.className='cm-code-tools'; tools.contentEditable='false';
    if(this.name) { const label=document.createElement('span'); label.textContent=this.name; tools.append(label); }
    const copy=document.createElement('button'); copy.type='button'; copy.textContent=host.uiText(view.state,'copy');
    copy.addEventListener('mousedown',event=>event.preventDefault());
    copy.addEventListener('click',event=>{
      event.preventDefault();
      for(let node=syntaxTree(view.state).resolveInner(view.posAtDOM(tools),1);node;node=node.parent) if(node.name==='FencedCode') {
        const text=node.getChild('CodeText');
        host.post({type:'copy',text:text?view.state.sliceDoc(text.from,text.to):''});
        copy.textContent=host.uiText(view.state,'copied');
        setTimeout(()=>{copy.textContent=host.uiText(view.state,'copy');},1200);
        return;
      }
    });
    tools.append(copy); return tools;
  }
  ignoreEvent() { return true; }
}
export const codeTools=name=>Decoration.widget({widget:new CodeToolsWidget(name),side:-1});

// Inline HTML: coloured text, underline, sub- and superscript and so on. Only
// plain colours and text styling get through; the tags hide unless the caret
// is on them.
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
    if(!touched(start.from,to)) { list.push(Decoration.replace({}).range(start.from,start.to)); list.push(Decoration.replace({}).range(from,to)); }
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
const foldableLine=/^(?: {0,3}#{1,6}[ \t]+\S|>\s*\[![\w-]+\])/;
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
    if(!/^>\s*\[![\w-]+\]-/.test(line.text))continue;
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
function measure(image) { viewOf(image)?.requestMeasure(); }
function watchImage(image,state) {
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
  const large=document.createElement('img');large.src=image.src;large.alt=image.alt;cover.append(large);
  const close=()=>{cover.remove();window.removeEventListener('keydown',key,true);};
  const key=event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();}};
  cover.addEventListener('mousedown',event=>{event.preventDefault();close();});
  window.addEventListener('keydown',key,true);document.body.append(cover);
}
export function frameImage(image,state) {
  watchImage(image,state);
  const frame=document.createElement('span');frame.className='cm-image-frame';
  image.replaceWith(frame);frame.append(image);
  for(const side of [-1,1]) {
    const handle=document.createElement('span');handle.className='cm-image-handle '+(side<0?'cm-image-handle-left':'cm-image-handle-right');
    handle.addEventListener('mousedown',event=>resize(event,image,side));
    frame.append(handle);
  }
  image.addEventListener('dblclick',event=>{event.preventDefault();showLarge(image);});
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
