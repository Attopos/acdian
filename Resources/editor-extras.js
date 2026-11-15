import { EditorState, EditorSelection, StateField, StateEffect, Prec } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { isolateHistory } from '@codemirror/commands';
import { syntaxTree } from '@codemirror/language';
import { search, searchKeymap, openSearchPanel, closeSearchPanel, SearchQuery, setSearchQuery, getSearchQuery, findNext, findPrevious, replaceNext, replaceAll } from '@codemirror/search';
import { autocompletion, completionKeymap, startCompletion } from '@codemirror/autocomplete';
import { editorLanguage } from './ui-language.js';
import { moveCurrentBlock } from './block-drag.js';

// Requests answered by the app: the list of pages, and a web page's title.
let nextRequest=1;const waiting=new Map();
globalThis.acdianReply=({id,result})=>{const done=waiting.get(id);if(done){waiting.delete(id);done(result);}};
function ask(post,message,timeout=8000) {
  return new Promise(resolve=>{
    const id=nextRequest++;waiting.set(id,resolve);
    setTimeout(()=>{if(waiting.delete(id))resolve(null);},timeout);
    post({...message,request:id});
  });
}

// Find and replace in the page (⌘F, ⌥⌘F), with ACdian's words for the panel.
const phrases={
  en:{},
  es:{'Find':'Buscar','Replace':'Reemplazar','next':'siguiente','previous':'anterior','all':'todos','match case':'mayúsculas','regexp':'expresión regular','by word':'palabra completa','replace':'reemplazar','replace all':'reemplazar todo','close':'cerrar','current match':'coincidencia actual','on line':'en la línea','replaced $ matches':'$ reemplazos','replaced match on line $':'reemplazado en la línea $'},
  'zh-Hans':{'Find':'查找','Replace':'替换为','next':'下一个','previous':'上一个','all':'全部','match case':'区分大小写','regexp':'正则','by word':'全词匹配','replace':'替换','replace all':'全部替换','close':'关闭','current match':'当前匹配','on line':'第几行','replaced $ matches':'已替换 $ 处','replaced match on line $':'已替换第 $ 行的匹配'}
};
const languageKey=state=>{const language=state.facet(editorLanguage)||'en';return language.startsWith('zh')?'zh-Hans':language.startsWith('es')?'es':'en';};
const words={
  en:{find:'Find in page',replace:'Replace with',previous:'Previous (⇧↩)',next:'Next (↩)',caseSensitive:'Match case',regexp:'Regular expression',showReplace:'Replace',close:'Close (Esc)',replaceOne:'Replace',replaceEvery:'Replace all',none:'No results'},
  es:{find:'Buscar en la página',replace:'Reemplazar por',previous:'Anterior (⇧↩)',next:'Siguiente (↩)',caseSensitive:'Mayúsculas',regexp:'Expresión regular',showReplace:'Reemplazar',close:'Cerrar (Esc)',replaceOne:'Reemplazar',replaceEvery:'Reemplazar todo',none:'Sin resultados'},
  'zh-Hans':{find:'在页面中查找',replace:'替换为',previous:'上一个（⇧↩）',next:'下一个（↩）',caseSensitive:'区分大小写',regexp:'正则表达式',showReplace:'替换',close:'关闭（Esc）',replaceOne:'替换',replaceEvery:'全部替换',none:'无结果'}
};
const panels=new WeakMap();
// A compact find card in ACdian's colours, in place of CodeMirror's grey bar:
// the query, "3/12", previous and next, match case, regular expression, and a
// replace row that ⌥⌘F opens.
class FindPanel {
  constructor(view) {
    this.view=view;const doc=view.dom.ownerDocument,t=words[languageKey(view.state)];
    const make=(tag,className,props={})=>Object.assign(doc.createElement(tag),{className,...props});
    this.dom=make('div','cm-acdian-find');this.dom.setAttribute('role','search');
    const row=make('div','cm-find-row'),replaceRow=make('div','cm-find-row cm-find-replace-row');
    this.search=make('input','cm-find-input',{type:'text',placeholder:t.find,spellcheck:false});this.search.setAttribute('main-field','true');
    this.count=make('span','cm-find-count');
    const button=(text,title,run,className='')=>{const element=make('button','cm-find-button '+className,{type:'button',textContent:text,title});element.setAttribute('aria-label',title);element.addEventListener('mousedown',event=>event.preventDefault());element.addEventListener('click',run);return element;};
    this.caseButton=button('Aa',t.caseSensitive,()=>{this.caseButton.classList.toggle('cm-find-on');this.commit();});
    this.regexButton=button('.*',t.regexp,()=>{this.regexButton.classList.toggle('cm-find-on');this.commit();});
    this.replaceToggle=button('⇄',t.showReplace,()=>this.showReplace(!this.replaceShown));
    row.append(this.search,this.count,button('↑',t.previous,()=>{findPrevious(view);}),button('↓',t.next,()=>{findNext(view);}),this.caseButton,this.regexButton,this.replaceToggle,button('✕',t.close,()=>closeSearchPanel(view),'cm-find-close'));
    this.replace=make('input','cm-find-input',{type:'text',placeholder:t.replace,spellcheck:false});
    replaceRow.append(this.replace,button(t.replaceOne,t.replaceOne,()=>{this.commit();replaceNext(view);},'cm-find-text'),button(t.replaceEvery,t.replaceEvery,()=>{this.commit();replaceAll(view);},'cm-find-text'));
    this.dom.append(row,replaceRow);this.replaceRow=replaceRow;this.showReplace(false);
    for(const field of [this.search,this.replace]) {
      field.addEventListener('input',()=>this.commit());
      field.addEventListener('keydown',event=>{
        if(event.isComposing)return;
        if(event.key==='Escape'){event.preventDefault();closeSearchPanel(view);view.focus();}
        else if(event.key==='Enter'&&field===this.search){event.preventDefault();(event.shiftKey?findPrevious:findNext)(view);}
        else if(event.key==='Enter'&&field===this.replace){event.preventDefault();this.commit();(event.metaKey?replaceAll:replaceNext)(view);}
      });
    }
    const query=getSearchQuery(view.state);
    this.search.value=query.search;this.replace.value=query.replace;
    this.caseButton.classList.toggle('cm-find-on',query.caseSensitive);this.regexButton.classList.toggle('cm-find-on',query.regexp);
    panels.set(view,this);
  }
  get top() {return true;}
  mount() {this.search.focus();this.search.select();this.refresh();}
  showReplace(on) {this.replaceShown=on;this.replaceRow.hidden=!on;this.replaceToggle.classList.toggle('cm-find-on',on);}
  commit() {
    const query=new SearchQuery({search:this.search.value,replace:this.replace.value,caseSensitive:this.caseButton.classList.contains('cm-find-on'),regexp:this.regexButton.classList.contains('cm-find-on')});
    if(!query.eq(getSearchQuery(this.view.state)))this.view.dispatch({effects:setSearchQuery.of(query)});
  }
  update(update) {
    for(const tr of update.transactions)for(const effect of tr.effects)if(effect.is(setSearchQuery)&&effect.value.search!==this.search.value)this.search.value=effect.value.search;
    if(update.docChanged||update.selectionSet||update.transactions.some(tr=>tr.effects.some(effect=>effect.is(setSearchQuery))))this.refresh();
  }
  // "current/total", counting up to 999 matches.
  refresh() {
    const query=getSearchQuery(this.view.state),t=words[languageKey(this.view.state)];
    if(!query.search||!query.valid){this.count.textContent='';this.dom.classList.remove('cm-find-empty');return;}
    const cursor=query.getCursor(this.view.state),main=this.view.state.selection.main;let total=0,current=0;
    for(let next=cursor.next();!next.done&&total<999;next=cursor.next()){total++;if(next.value.from===main.from&&next.value.to===main.to)current=total;}
    this.count.textContent=total?`${current||'–'}/${total}${total>=999?'+':''}`:t.none;
    this.dom.classList.toggle('cm-find-empty',!total);
  }
}
export function findInPage(view,replace) {
  openSearchPanel(view);
  const panel=panels.get(view);
  if(panel){panel.showReplace(!!replace||panel.replaceShown);requestAnimationFrame(()=>{const field=replace?panel.replace:panel.search;field.focus();field.select();});}
  return true;
}

// [[ offers the pages to link to; picking one finishes the link.
let pageCache={at:0,list:null};
async function pageNames(post) {
  if(pageCache.list&&Date.now()-pageCache.at<20000)return pageCache.list;
  const list=await ask(post,{type:'listPages'},4000);
  if(Array.isArray(list))pageCache={at:Date.now(),list};
  return pageCache.list||[];
}
function wikiCompletions(post) {
  return async context=>{
    const before=context.matchBefore(/\[\[[^\]\[|\n]*$/);
    if(!before)return null;
    const tree=syntaxTree(context.state).resolveInner(context.pos,-1);
    for(let node=tree;node;node=node.parent)if(['FencedCode','CodeBlock','InlineCode'].includes(node.name))return null;
    const query=before.text.slice(2).toLowerCase(),names=await pageNames(post);
    if(context.aborted)return null;
    const base=name=>name.split('/').pop(),counts=new Map();
    for(const name of names)counts.set(base(name),(counts.get(base(name))||0)+1);
    const scored=[];
    for(const name of names) {
      const short=base(name),lower=short.toLowerCase(),path=name.toLowerCase();
      const score=!query?2:lower.startsWith(query)?3:lower.includes(query)?2:path.includes(query)?1:0;
      if(score)scored.push({name,short,score});
    }
    scored.sort((a,b)=>b.score-a.score||a.short.length-b.short.length||a.short.localeCompare(b.short));
    const after=context.state.sliceDoc(context.pos,context.pos+2)===']]';
    const options=scored.slice(0,50).map(({name,short})=>({
      label:short,detail:name.includes('/')?name.slice(0,name.length-short.length-1):'',
      apply:(view,completion,from,to)=>{
        const target=counts.get(short)>1?name:short;
        view.dispatch({changes:{from,to:after?to+2:to,insert:target+']]'},selection:{anchor:from+target.length+2},userEvent:'input.complete'});
      }
    }));
    return {from:before.from+2,options,filter:false};
  };
}

// A pasted web address goes in at once; when the app has fetched the page's
// title the address becomes [title](address), as its own undo step, so ⌘Z
// brings the bare address back. Pasted over selected text, it links that text.
const trackPaste=StateEffect.define();
const pastedLinks=StateField.define({
  create:()=>[],
  update(value,tr){
    let next=tr.docChanged?value.map(item=>({...item,from:tr.changes.mapPos(item.from,1)})):value;
    for(const effect of tr.effects)if(effect.is(trackPaste))next=effect.value.remove?next.filter(item=>item.id!==effect.value.id):[...next,effect.value];
    return next;
  }
});
const urlOnly=/^https?:\/\/[^\s<>"]+$/i;
const escapeTitle=title=>title.replace(/[\[\]|\\]/g,match=>'\\'+match);
function inCodeAt(state,pos) {
  for(let node=syntaxTree(state).resolveInner(pos,-1);node;node=node.parent)if(['FencedCode','CodeBlock','InlineCode','Link','URL','Autolink'].includes(node.name))return true;
  return false;
}
function pasteLink(post) {
  return EditorView.domEventHandlers({paste(event,view){
    const data=event.clipboardData;if(!data||!view.state.facet(EditorView.editable)||view.state.readOnly)return false;
    if(data.files?.length||[...data.types].includes('Files'))return false;
    const text=(data.getData('text/plain')||'').trim(),range=view.state.selection.main;
    if(!urlOnly.test(text)||view.state.selection.ranges.length!==1||inCodeAt(view.state,range.from))return false;
    event.preventDefault();
    const selected=view.state.sliceDoc(range.from,range.to);
    if(!range.empty&&!selected.includes('\n')&&!urlOnly.test(selected.trim())) {
      const insert=`[${escapeTitle(selected)}](${text})`;
      view.dispatch({changes:{from:range.from,to:range.to,insert},selection:{anchor:range.from+insert.length},userEvent:'input.paste'});
      return true;
    }
    const id=nextRequest++;
    view.dispatch({changes:{from:range.from,to:range.to,insert:text},selection:{anchor:range.from+text.length},effects:trackPaste.of({id,from:range.from,url:text}),userEvent:'input.paste'});
    ask(post,{type:'fetchTitle',url:text}).then(title=>{
      const item=view.state.field(pastedLinks).find(entry=>entry.id===id);
      if(!item)return;
      const remove=trackPaste.of({id,remove:true});
      if(typeof title!=='string'||!title.trim()||view.state.sliceDoc(item.from,item.from+text.length)!==text){view.dispatch({effects:remove});return;}
      const insert=`[${escapeTitle(title.trim())}](${text})`,head=view.state.selection.main.head;
      const caretAfter=head===item.from+text.length;
      view.dispatch({changes:{from:item.from,to:item.from+text.length,insert},effects:remove,annotations:isolateHistory.of('full'),userEvent:'input.paste-title',
        ...(caretAfter?{selection:{anchor:item.from+insert.length}}:{})});
    });
    return true;
  }});
}

export function editorExtras(post) {return [
  search({top:true,createPanel:view=>new FindPanel(view)}),
  EditorState.phrases.compute([editorLanguage],state=>phrases[languageKey(state)]),
  autocompletion({override:[wikiCompletions(post)],icons:false,activateOnTyping:true,closeOnBlur:true}),
  pastedLinks,pasteLink(post),
  Prec.high(keymap.of([
    {key:'Alt-Shift-ArrowUp',run:view=>moveCurrentBlock(view,-1)},
    {key:'Alt-Shift-ArrowDown',run:view=>moveCurrentBlock(view,1)},
    ...completionKeymap
  ])),
  keymap.of(searchKeymap)
];}
export { startCompletion };
