// Comments on a page, shown as cards beside the text.
//
// While a page is open, each comment's place is a range in the editor state:
// it moves with every edit as CodeMirror maps it, and undo puts it back with
// the text it covered. A comment whose text is deleted is deleted with it.
// The page file itself is never changed: comments are kept in a hidden file
// beside it, which stores each place twice, as offsets and as the quoted text
// with a little context. Offsets alone break when another app edits the page;
// a quote alone is ambiguous when the same words appear twice. On load the
// offsets are tried first, then the quote near them, then a looser match.
import { StateField, StateEffect, Transaction, Prec } from '@codemirror/state';
import { EditorView, Decoration, ViewPlugin, keymap } from '@codemirror/view';
import { invertedEffects } from '@codemirror/commands';
import { editorLanguage, messagesForLanguage } from './ui-language.js';

const CONTEXT=32;
const newID=()=>globalThis.crypto?.randomUUID?.()??(Date.now().toString(36)+Math.random().toString(36).slice(2,10));
const mapThread=(thread,mapping)=>thread.whole?thread:{...thread,from:mapping.mapPos(thread.from,1),to:mapping.mapPos(thread.to,-1)};

const addThread=StateEffect.define({map:mapThread});
const updateThread=StateEffect.define();
const removeThread=StateEffect.define();
const restoreThread=StateEffect.define({map:mapThread});
const loadThreads=StateEffect.define();
const setActive=StateEffect.define();
const outside=Transaction.addToHistory.of(false);

const initial={threads:[],active:null,discarded:new Set()};
export const commentsField=StateField.define({
  create:()=>initial,
  update(value,tr) {
    let {threads,active,discarded}=value;
    if(tr.docChanged&&threads.some(thread=>!thread.whole)) {
      let changed=false;const next=[];
      for(const thread of threads) {
        if(thread.whole){next.push(thread);continue;}
        const from=tr.changes.mapPos(thread.from,1),to=tr.changes.mapPos(thread.to,-1);
        if(from===thread.from&&to===thread.to){next.push(thread);continue;}
        changed=true;
        // Its text is gone, so the comment goes too. Undo brings both back.
        if(to>from)next.push({...thread,from,to});
      }
      if(changed)threads=next;
    }
    for(const effect of tr.effects) {
      if(effect.is(loadThreads)){threads=effect.value;active=null;discarded=new Set();}
      else if(effect.is(addThread))threads=[...threads.filter(thread=>thread.id!==effect.value.id),effect.value];
      else if(effect.is(updateThread))threads=threads.map(thread=>thread.id===effect.value.id?{...thread,...effect.value}:thread);
      else if(effect.is(removeThread)){threads=threads.filter(thread=>thread.id!==effect.value);discarded=new Set(discarded).add(effect.value);}
      else if(effect.is(restoreThread)) {
        // The oldest place comes last in an undo, so it is the one kept.
        const kept=effect.value;
        if(discarded.has(kept.id)||kept.to<=kept.from)continue;
        threads=threads.some(thread=>thread.id===kept.id)?threads.map(thread=>thread.id===kept.id?{...thread,from:kept.from,to:kept.to}:thread):[...threads,kept];
      }
      else if(effect.is(setActive))active=effect.value;
    }
    if(active&&!threads.some(thread=>thread.id===active))active=null;
    if(threads===value.threads&&active===value.active&&discarded===value.discarded)return value;
    return {threads,active,discarded};
  },
  provide:field=>EditorView.decorations.from(field,value=>{
    const ranges=[];
    for(const thread of value.threads) {
      if(thread.whole||thread.solved||thread.to<=thread.from)continue;
      ranges.push(Decoration.mark({class:'cm-comment-mark'+(thread.id===value.active?' cm-comment-active':''),attributes:{'data-comment':thread.id}}).range(thread.from,thread.to));
    }
    return Decoration.set(ranges,true);
  })
});

// Every edit that touches a comment's text records where the comment was, so
// undoing the edit returns it to that place, or back from deletion.
const undoPlaces=invertedEffects.of(tr=>{
  if(!tr.docChanged)return [];
  const restored=[];
  for(const thread of tr.startState.field(commentsField).threads) {
    if(thread.whole)continue;
    let touched=false;
    tr.changes.iterChangedRanges((from,to)=>{if(from<thread.to&&to>thread.from)touched=true;});
    if(touched)restored.push(restoreThread.of(thread));
  }
  return restored;
});

// Saved form
export function serializeComments(state) {
  const doc=state.doc,threads=[];
  for(const thread of state.field(commentsField).threads) {
    if(!thread.replies.length)continue;
    const item={id:thread.id,created:thread.created,replies:thread.replies};
    if(thread.solved)item.solved=true;
    if(thread.whole)item.whole=true;
    else Object.assign(item,{from:thread.from,to:thread.to,quote:doc.sliceString(thread.from,thread.to),prefix:doc.sliceString(Math.max(0,thread.from-CONTEXT),thread.from),suffix:doc.sliceString(thread.to,Math.min(doc.length,thread.to+CONTEXT))});
    threads.push(item);
  }
  return threads.length?JSON.stringify({version:1,threads}):null;
}
const commonStart=(a,b)=>{let n=0;while(n<a.length&&n<b.length&&a[n]===b[n])n++;return n;};
const commonEnd=(a,b)=>{let n=0;while(n<a.length&&n<b.length&&a[a.length-1-n]===b[b.length-1-n])n++;return n;};
function occurrences(text,part,limit=2000) {
  const found=[];if(!part)return found;
  for(let at=text.indexOf(part);at>=0&&found.length<limit;at=text.indexOf(part,at+1))found.push(at);
  return found;
}
// Dice similarity of character pairs: forgiving of small rewrites, and works
// the same for Chinese, which has no spaces to split words on.
function similarity(a,b) {
  if(a===b)return 1;
  if(a.length<2||b.length<2)return 0;
  const pairs=new Map();
  for(let i=0;i<a.length-1;i++){const pair=a.slice(i,i+2);pairs.set(pair,(pairs.get(pair)||0)+1);}
  let shared=0;
  for(let i=0;i<b.length-1;i++){const pair=b.slice(i,i+2),count=pairs.get(pair);if(count){shared++;pairs.set(pair,count-1);}}
  return 2*shared/(a.length+b.length-2);
}
// Finds where a saved comment belongs in the page's text now, or null.
export function anchorComment(text,saved) {
  const quote=typeof saved.quote==='string'?saved.quote:'';
  if(!quote)return null;
  const from=Number.isFinite(saved.from)?saved.from:0;
  if(text.slice(from,from+quote.length)===quote)return {from,to:from+quote.length};
  const prefix=saved.prefix||'',suffix=saved.suffix||'';
  const place=at=>commonEnd(text.slice(Math.max(0,at-prefix.length),at),prefix)+commonStart(text.slice(at+quote.length,at+quote.length+suffix.length),suffix)-Math.abs(at-from)/(text.length+1);
  const exact=occurrences(text,quote);
  if(exact.length){let best=exact[0],score=place(best);for(const at of exact.slice(1)){const s=place(at);if(s>score){best=at;score=s;}}return {from:best,to:best+quote.length};}
  // The quote was edited elsewhere. Candidate spans are found from the context
  // around it and from its own first and last words, and the most similar wins.
  if(quote.length<4)return null;
  const candidates=[],reach=quote.length*3+64;
  const ends=(start,part,within)=>occurrences(text.slice(start,start+within),part,50).map(at=>start+at);
  if(prefix.length>=6&&suffix.length>=6)for(const at of occurrences(text,prefix,200)){const start=at+prefix.length;for(const end of ends(start,suffix,reach))candidates.push([start,end]);}
  const edge=Math.max(2,Math.min(12,Math.floor(quote.length/3)));
  const head=quote.slice(0,edge),tail=quote.slice(-edge);
  for(const start of occurrences(text,head,200))for(const end of ends(start+head.length,tail,reach))candidates.push([start,end+tail.length]);
  let best=null,score=.45;
  for(const [start,end] of candidates) {
    if(end<=start)continue;
    const s=similarity(quote,text.slice(start,end))-Math.abs(start-from)/(text.length+1)/10;
    if(s>score){best={from:start,to:end};score=s;}
  }
  return best;
}
// The comments read from disk, placed in the given text. Comments whose text
// cannot be found any more are dropped, as if their text had been deleted.
export function placeComments(text,json) {
  let data;
  try{data=typeof json==='string'&&json?JSON.parse(json):null;}catch{data=null;}
  if(!data||!Array.isArray(data.threads))return [];
  const threads=[];
  for(const saved of data.threads) {
    if(!saved||typeof saved.id!=='string'||!Array.isArray(saved.replies))continue;
    const replies=saved.replies.filter(reply=>reply&&typeof reply.text==='string'&&reply.text.trim()).map(reply=>({id:typeof reply.id==='string'?reply.id:newID(),text:reply.text,created:Number(reply.created)||Date.now(),...(Number(reply.edited)?{edited:Number(reply.edited)}:{})}));
    if(!replies.length)continue;
    const base={id:saved.id,created:Number(saved.created)||replies[0].created,replies,solved:!!saved.solved};
    if(saved.whole){threads.push({...base,whole:true,from:0,to:0});continue;}
    const place=anchorComment(text,saved);
    if(place&&place.to>place.from)threads.push({...base,whole:false,...place});
  }
  return threads;
}
export const loadComments=(state,json)=>loadThreads.of(placeComments(state.doc.toString(),json));

// Adds a comment on the selection, or on the whole page when nothing is selected.
let focusRequest=null;
export function startComment(view) {
  const range=view.state.selection.main;
  let from=range.from,to=range.to;
  const text=view.state.sliceDoc(from,to);
  from+=text.length-text.trimStart().length;to-=text.length-text.trimEnd().length;
  const whole=to<=from;
  const existing=whole&&view.state.field(commentsField).threads.find(thread=>thread.whole&&!thread.solved);
  const id=existing?existing.id:newID();
  focusRequest=id;
  const effects=existing?[setActive.of(id)]:[addThread.of({id,from:whole?0:from,to:whole?0:to,whole,created:Date.now(),replies:[],solved:false}),setActive.of(id)];
  view.dispatch({effects,annotations:outside});
  return true;
}

const svg=paths=>`<svg viewBox="0 0 20 20" aria-hidden="true">${paths.map(d=>`<path d="${d}"/>`).join('')}</svg>`;
export const commentIcon=svg(['M4 5.5A1.5 1.5 0 0 1 5.5 4h9A1.5 1.5 0 0 1 16 5.5v6a1.5 1.5 0 0 1-1.5 1.5H9l-3.5 3v-3h0A1.5 1.5 0 0 1 4 11.5z','M7.5 7.5h5','M7.5 10h3']);
const icons={
  resolve:svg(['M4.5 10.5l3.5 3.5 7.5-8']),
  reopen:svg(['M5 9a5 5 0 1 1 1.5 4.5','M5 5v4h4']),
  remove:svg(['M5 6h10','M8 6V4.5h4V6','M6.5 6l.7 9.5h5.6l.7-9.5']),
  edit:svg(['M12.5 4.5l3 3L8 15H5v-3z']),
  collapse:svg(['M5 6l4 4-4 4','M11 6l4 4-4 4'])
};
const GAP=10,CARD=268,COLUMN=300,HEADER=52;
// With the comment column open the text sits in the middle of the space between
// whatever is on its left (the outline, or the page edge) and the column, as
// Feishu does, narrowing down to TEXT_MIN before the column gives way.
const COLUMN_GAP=48,TEXT_MIN=480,PAGE=760;
const collapsedKey='acdian.commentsCollapsed';
const storedCollapsed=()=>{try{return localStorage.getItem(collapsedKey)==='1';}catch{return false;}};

function timeLabel(ms,language,strings) {
  const seconds=(Date.now()-ms)/1000;
  if(seconds<60)return strings.justNow;
  try {
    const relative=new Intl.RelativeTimeFormat(language,{numeric:'auto'});
    if(seconds<3600)return relative.format(-Math.floor(seconds/60),'minute');
    if(seconds<86400)return relative.format(-Math.floor(seconds/3600),'hour');
    const date=new Date(ms),now=new Date();
    return date.toLocaleDateString(language,{month:'short',day:'numeric',...(date.getFullYear()===now.getFullYear()?{}:{year:'numeric'})});
  } catch { return new Date(ms).toLocaleDateString(); }
}
function autosize(input) {input.style.height='auto';input.style.height=Math.min(200,input.scrollHeight+2)+'px';}

function commentsPanel(config) {return ViewPlugin.fromClass(class {
  constructor(view) {
    this.view=view;this.cards=new Map();this.badges=new Map();this.editing=null;this.drafts=new Map();this.showSolved=false;this.mode=null;
    this.dom=document.createElement('div');this.dom.className='cm-comments';
    this.footer=document.createElement('button');this.footer.type='button';this.footer.className='cm-comments-solved';
    this.footer.addEventListener('click',()=>{this.showSolved=!this.showSolved;this.render(true);});
    // The column: a panel docked to the right edge with its own header. The
    // cards scroll with the text over it, beside the line they belong to.
    this.panel=document.createElement('div');this.panel.className='cm-comments-panel';
    this.header=document.createElement('div');this.header.className='cm-comments-header';
    this.heading=document.createElement('span');
    this.collapse=document.createElement('button');this.collapse.type='button';this.collapse.className='cm-comment-tool cm-comments-collapse';this.collapse.innerHTML=icons.collapse;
    this.collapse.addEventListener('click',()=>this.setCollapsed(true));
    this.header.append(this.heading,this.collapse);
    this.opener=document.createElement('button');this.opener.type='button';this.opener.className='cm-comments-opener';
    this.opener.addEventListener('click',()=>this.setCollapsed(false));
    this.collapsed=storedCollapsed();
    // The app's own menu and keyboard shortcut show or hide the comments.
    globalThis.acdianToggleComments=()=>this.setCollapsed(!this.collapsed);
    this.dom.append(this.panel,this.footer,this.header,this.opener);
    // Clicks in the cards stay out of the editor's own mouse handling.
    this.dom.addEventListener('mousedown',event=>event.stopPropagation());
    view.scrollDOM.append(this.dom);
    this.resize=new ResizeObserver(()=>this.schedule());this.resize.observe(view.scrollDOM);
    // The text moves without the editor changing size when the window centres it anew.
    this.relayout=()=>this.schedule();window.addEventListener('acdian-relayout',this.relayout);
    this.path=config.path();this.saved=serializeComments(view.state);this.saveTimer=null;this.pendingPath=null;
    this.render(true);
  }
  update(update) {
    const before=update.startState.field(commentsField),after=update.state.field(commentsField);
    const language=update.startState.facet(editorLanguage)!==update.state.facet(editorLanguage);
    if(before!==after||language)this.render(language||before.active!==after.active);
    const loaded=update.transactions.some(tr=>tr.effects.some(effect=>effect.is(loadThreads)));
    const path=config.path();
    if(loaded){this.saved=serializeComments(update.state);this.path=path;}
    else if(before.threads!==after.threads) {
      // Moved places are saved after a pause in typing; anything else at once.
      const moved=before.threads.length===after.threads.length&&!update.transactions.some(tr=>tr.effects.some(effect=>effect.is(addThread)||effect.is(updateThread)||effect.is(removeThread)||effect.is(restoreThread)));
      this.queueSave(moved?1000:0);
    }
    else if(path!==this.path)this.queueSave(0);
    if(update.geometryChanged||update.docChanged||update.viewportChanged||before!==after)this.schedule();
  }
  queueSave(delay) {
    clearTimeout(this.saveTimer);
    this.pendingPath=config.path();
    this.saveTimer=setTimeout(()=>this.save(),delay);
  }
  save() {
    clearTimeout(this.saveTimer);this.saveTimer=null;
    const path=this.pendingPath??config.path();this.pendingPath=null;
    if(!path)return;
    const data=serializeComments(this.view.state);
    if(path===this.path&&data===this.saved)return;
    this.path=path;this.saved=data;
    config.post({type:'comments',currentPath:path,data});
  }
  destroy() {
    if(this.saveTimer)this.save();
    this.resize.disconnect();window.removeEventListener('acdian-relayout',this.relayout);this.dom.remove();
    this.view.scrollDOM.classList.remove('cm-comments-wide','cm-comments-narrow');
    for(const name of ['--comment-left','--column'])document.documentElement.style.removeProperty(name);
  }
  setCollapsed(collapsed) {
    this.collapsed=collapsed;
    try{localStorage.setItem(collapsedKey,collapsed?'1':'0');}catch{}
    // The iOS app keeps no web storage between launches, so it remembers this itself.
    if(globalThis.acdianTouch){
      config.post({type:'commentsCollapsed',collapsed});
      // On a touch screen only the open comment shows, so showing them opens the first one.
      const state=this.view.state.field(commentsField);
      if(!collapsed&&state.active==null&&state.threads.length)this.dispatch(setActive.of(state.threads[0].id));
    }
    this.schedule();
  }
  strings(){return messagesForLanguage(this.view.state.facet(editorLanguage)).comments;}
  dispatch(...effects){this.view.dispatch({effects,annotations:outside});}
  thread(id){return this.view.state.field(commentsField).threads.find(thread=>thread.id===id);}
  render(force=false) {
    const {threads,active}=this.view.state.field(commentsField),strings=this.strings(),language=this.view.state.facet(editorLanguage);
    const solved=threads.filter(thread=>thread.solved).length;
    const shown=threads.filter(thread=>!thread.solved||this.showSolved);
    for(const [id,card] of this.cards)if(!shown.some(thread=>thread.id===id)){card.dom.remove();this.cards.delete(id);this.badges.get(id)?.remove();this.badges.delete(id);}
    for(const thread of shown) {
      let card=this.cards.get(thread.id);
      if(!card){card=this.makeCard(thread.id);this.cards.set(thread.id,card);this.dom.insertBefore(card.dom,this.footer);}
      if(force||card.thread!==thread)this.fill(card,thread,strings,language);
      card.dom.classList.toggle('active',thread.id===active);
      let badge=this.badges.get(thread.id);
      if(!badge){badge=document.createElement('button');badge.type='button';badge.className='cm-comment-badge';badge.addEventListener('click',()=>this.dispatch(setActive.of(this.view.state.field(commentsField).active===thread.id?null:thread.id)));this.badges.set(thread.id,badge);this.dom.append(badge);}
      badge.innerHTML=commentIcon;badge.append(String(thread.replies.length||''));badge.title=strings.show;badge.classList.toggle('active',thread.id===active);
    }
    const open=threads.filter(thread=>!thread.solved&&thread.replies.length).length;
    this.heading.textContent=strings.title.replace('%d',open);
    this.collapse.title=strings.collapse;this.collapse.setAttribute('aria-label',strings.collapse);
    this.opener.innerHTML=commentIcon;this.opener.append(String(open||''));this.opener.title=strings.expand;this.opener.setAttribute('aria-label',strings.expand);
    this.footer.hidden=!solved;
    this.footer.textContent=(this.showSolved?strings.hideSolved:strings.showSolved).replace('%d',solved);
    if(focusRequest&&this.cards.has(focusRequest)) {
      const card=this.cards.get(focusRequest);focusRequest=null;
      requestAnimationFrame(()=>{card.input.focus({preventScroll:true});});
    }
    this.schedule();
  }
  makeCard(id) {
    const dom=document.createElement('div');dom.className='cm-comment-card';dom.dataset.id=id;
    const head=document.createElement('div');head.className='cm-comment-head';
    const quote=document.createElement('div');quote.className='cm-comment-quote';
    const resolve=this.tool(()=>{const thread=this.thread(id);if(!thread)return;if(!thread.replies.length){this.dispatch(removeThread.of(id));return;}this.dispatch(updateThread.of({id,solved:!thread.solved}),setActive.of(null));});
    const remove=this.tool(()=>this.dispatch(removeThread.of(id)));
    head.append(quote,resolve,remove);
    // On a touch screen the open comment can cover the text, so it can be put away.
    if(globalThis.acdianTouch){const hide=this.tool(()=>this.setCollapsed(true));hide.classList.add('cm-comments-collapse');hide.innerHTML=icons.collapse;hide.title=this.strings().collapse;hide.setAttribute('aria-label',this.strings().collapse);head.append(hide);}
    const replies=document.createElement('div');replies.className='cm-comment-replies';
    const composer=document.createElement('div');composer.className='cm-comment-composer';
    const input=document.createElement('textarea');input.className='cm-comment-input';input.rows=1;input.spellcheck=false;
    composer.append(input);
    dom.append(head,replies,composer);
    dom.addEventListener('mousedown',event=>{
      if(event.target.closest('button'))return;
      if(this.view.state.field(commentsField).active!==id)this.dispatch(setActive.of(id));
    });
    input.addEventListener('input',()=>{this.drafts.set(id,input.value);autosize(input);this.schedule();});
    input.addEventListener('keydown',event=>{
      if(event.isComposing||event.keyCode===229)return;
      if(event.key==='Enter'&&!event.shiftKey&&!event.altKey){event.preventDefault();this.submit(id,input);}
      else if(event.key==='Escape'){event.preventDefault();input.value='';this.drafts.delete(id);this.leave(id);}
    });
    input.addEventListener('blur',()=>setTimeout(()=>{
      const thread=this.thread(id);
      if(thread&&!thread.replies.length&&!input.value.trim()&&document.activeElement!==input)this.dispatch(removeThread.of(id));
    },200));
    return {dom,quote,resolve,remove,replies,input,thread:null};
  }
  tool(run) {
    const button=document.createElement('button');button.type='button';button.className='cm-comment-tool';
    button.addEventListener('click',event=>{event.stopPropagation();run();});
    return button;
  }
  submit(id,input) {
    const text=input.value.replace(/\s+$/,'');
    if(!text.trim())return;
    const thread=this.thread(id);if(!thread)return;
    input.value='';this.drafts.delete(id);autosize(input);
    this.dispatch(updateThread.of({id,replies:[...thread.replies,{id:newID(),text,created:Date.now()}]}));
  }
  leave(id) {
    const thread=this.thread(id);
    if(thread&&!thread.replies.length){this.dispatch(removeThread.of(id));}
    else this.dispatch(setActive.of(null));
    this.view.focus();
  }
  fill(card,thread,strings,language) {
    card.thread=thread;
    card.dom.classList.toggle('solved',!!thread.solved);
    card.dom.classList.toggle('draft',!thread.replies.length);
    card.quote.textContent=thread.whole?strings.page:this.view.state.sliceDoc(thread.from,thread.to).replace(/\s+/g,' ');
    card.quote.title=card.quote.textContent;
    card.resolve.innerHTML=thread.solved?icons.reopen:icons.resolve;
    card.resolve.title=thread.solved?strings.reopen:strings.resolve;card.resolve.setAttribute('aria-label',card.resolve.title);
    card.resolve.hidden=!thread.replies.length;
    card.remove.innerHTML=icons.remove;card.remove.title=strings.deleteThread;card.remove.setAttribute('aria-label',strings.deleteThread);
    card.input.placeholder=thread.replies.length?strings.reply:strings.placeholder;
    card.input.setAttribute('aria-label',card.input.placeholder);
    if(document.activeElement!==card.input)card.input.value=this.drafts.get(thread.id)||'';
    const items=[];
    for(const reply of thread.replies) {
      const item=document.createElement('div');item.className='cm-comment-reply';
      const meta=document.createElement('div');meta.className='cm-comment-meta';
      const time=document.createElement('span');time.textContent=timeLabel(reply.created,language,strings);time.title=new Date(reply.created).toLocaleString(language);
      meta.append(time);
      if(reply.edited){const edited=document.createElement('span');edited.textContent=strings.edited;meta.append(edited);}
      const tools=document.createElement('span');tools.className='cm-comment-reply-tools';
      const edit=this.tool(()=>{this.editing={thread:thread.id,reply:reply.id};this.fill(card,this.thread(thread.id),this.strings(),this.view.state.facet(editorLanguage));});
      edit.innerHTML=icons.edit;edit.title=strings.edit;edit.setAttribute('aria-label',strings.edit);
      const remove=this.tool(()=>this.removeReply(thread.id,reply.id));
      remove.innerHTML=icons.remove;remove.title=strings.deleteReply;remove.setAttribute('aria-label',strings.deleteReply);
      tools.append(edit,remove);meta.append(tools);
      item.append(meta);
      if(this.editing?.thread===thread.id&&this.editing.reply===reply.id) {
        const input=document.createElement('textarea');input.className='cm-comment-input cm-comment-editor';input.rows=1;input.spellcheck=false;input.value=reply.text;
        input.setAttribute('aria-label',strings.edit);
        const done=save=>{
          if(this.editing?.reply!==reply.id)return;
          this.editing=null;
          if(save)this.editReply(thread.id,reply.id,input.value);
          else this.fill(card,this.thread(thread.id)||thread,this.strings(),this.view.state.facet(editorLanguage));
        };
        input.addEventListener('keydown',event=>{
          if(event.isComposing||event.keyCode===229)return;
          if(event.key==='Enter'&&!event.shiftKey&&!event.altKey){event.preventDefault();done(true);}
          else if(event.key==='Escape'){event.preventDefault();done(false);}
        });
        input.addEventListener('input',()=>{autosize(input);this.schedule();});
        input.addEventListener('blur',()=>done(true));
        item.append(input);
        requestAnimationFrame(()=>{autosize(input);input.focus({preventScroll:true});input.setSelectionRange(input.value.length,input.value.length);this.schedule();});
      } else {
        const text=document.createElement('div');text.className='cm-comment-text';text.textContent=reply.text;
        text.addEventListener('dblclick',()=>{this.editing={thread:thread.id,reply:reply.id};this.fill(card,this.thread(thread.id),this.strings(),this.view.state.facet(editorLanguage));});
        item.append(text);
      }
      items.push(item);
    }
    card.replies.replaceChildren(...items);
    autosize(card.input);
  }
  editReply(threadID,replyID,value) {
    const thread=this.thread(threadID);if(!thread)return;
    const text=value.replace(/\s+$/,'');
    if(!text.trim()){this.removeReply(threadID,replyID);return;}
    const old=thread.replies.find(reply=>reply.id===replyID);
    if(!old||old.text===text){const card=this.cards.get(threadID);if(card)this.fill(card,thread,this.strings(),this.view.state.facet(editorLanguage));return;}
    this.dispatch(updateThread.of({id:threadID,replies:thread.replies.map(reply=>reply.id===replyID?{...reply,text,edited:Date.now()}:reply)}));
  }
  removeReply(threadID,replyID) {
    const thread=this.thread(threadID);if(!thread)return;
    if(this.editing?.reply===replyID)this.editing=null;
    const replies=thread.replies.filter(reply=>reply.id!==replyID);
    this.dispatch(replies.length?updateThread.of({id:threadID,replies}):removeThread.of(threadID));
  }
  schedule() {this.view.requestMeasure({key:this,read:view=>this.measure(view),write:measured=>this.place(measured)});}
  measure(view) {
    const scroller=view.scrollDOM,box=scroller.getBoundingClientRect(),scrollTop=scroller.scrollTop,scrollLeft=scroller.scrollLeft;
    const content=view.contentDOM.getBoundingClientRect(),style=getComputedStyle(view.contentDOM);
    const title=scroller.querySelector('.cm-page-title:not([hidden])');
    const pageTop=(title?title.getBoundingClientRect().top:content.top)-box.top+scrollTop+(title?parseFloat(getComputedStyle(title).paddingTop)||0:0);
    const items=[];
    for(const [id,card] of this.cards) {
      const thread=card.thread;if(!thread)continue;
      let top;
      if(thread.whole)top=pageTop;
      else {
        const pos=Math.min(thread.from,view.state.doc.length),coords=view.coordsAtPos(pos,1);
        top=coords?coords.top-box.top+scrollTop:view.documentTop-box.top+scrollTop+view.lineBlockAt(pos).top;
      }
      items.push({id,top,height:card.dom.offsetHeight,whole:thread.whole});
    }
    // The page says where text may start on the left (--left-edge, past the outline).
    const textRight=content.right-box.left+scrollLeft-(parseFloat(style.paddingRight)||0);
    const side=parseFloat(style.paddingLeft)||0,edge=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--left-edge'))||side;
    const room=scroller.clientWidth-COLUMN-COLUMN_GAP-edge,text=Math.min(PAGE-2*side,room);
    const fit=items.length>0&&!this.collapsed&&!globalThis.acdianTouch&&room>=TEXT_MIN;
    const key=fit?Math.floor(edge+(room-text)/2-side)+'|'+Math.floor(text+2*side):'';
    return {items,key,wide:fit||(!this.layoutKey&&scroller.clientWidth+scrollLeft-textRight>=COLUMN+16),clientRight:scroller.clientWidth+scrollLeft,column:scroller.clientWidth-COLUMN+scrollLeft,fixedTop:box.top,fixedRight:window.innerWidth-box.left-scroller.clientWidth,bottom:Math.max(scroller.scrollHeight,scroller.clientHeight),right:content.right-box.left+scrollLeft,textRight:content.right-box.left+scrollLeft-(parseFloat(style.paddingRight)||0),line:parseFloat(getComputedStyle(view.contentDOM).lineHeight)||27,footer:this.footer.offsetHeight};
  }
  place(m) {
    // On the scroller: CodeMirror rewrites the editor's own class list.
    const classes=this.view.scrollDOM.classList,any=m.items.length>0;
    const mode=any?(m.wide&&!this.collapsed?'wide':'narrow'):null;
    if(m.key!==(this.layoutKey||'')){
      this.layoutKey=m.key;const root=document.documentElement.style,[left,column]=m.key.split('|');
      if(m.key){root.setProperty('--comment-left',left+'px');root.setProperty('--column',column+'px');}
      else for(const name of ['--comment-left','--column'])root.removeProperty(name);
      this.mode=mode;requestAnimationFrame(()=>this.schedule());return;
    }
    classes.toggle('cm-comments-wide',mode==='wide');classes.toggle('cm-comments-narrow',mode==='narrow');
    for(const element of [this.panel,this.header]){element.style.top=m.fixedTop+'px';element.style.right=m.fixedRight+'px';element.style.width=COLUMN+'px';}
    this.opener.style.top=(m.fixedTop+12)+'px';this.opener.style.right=(m.fixedRight+16)+'px';
    this.opener.hidden=!(any&&this.collapsed&&(m.wide||globalThis.acdianTouch));
    classes.toggle('cm-comments-collapsed',any&&this.collapsed&&!!globalThis.acdianTouch);
    // The text moves over to make room, so the places are read again.
    if(mode!==this.mode){this.mode=mode;requestAnimationFrame(()=>this.schedule());return;}
    const active=this.view.state.field(commentsField).active;
    const items=m.items.sort((a,b)=>(b.whole-a.whole)||(a.top-b.top));
    let bottom=0;
    if(mode==='wide') {
      const left=Math.round(m.column+(COLUMN-CARD)/2),tops=items.map(item=>Math.max(item.top,HEADER+12));
      const pinned=items.findIndex(item=>item.id===active);
      const start=pinned<0?0:pinned;
      for(let i=start+1;i<items.length;i++)tops[i]=Math.max(items[i].top,tops[i-1]+items[i-1].height+GAP);

      for(let i=start-1;i>=0;i--)tops[i]=Math.min(items[i].top,tops[i+1]-items[i].height-GAP);
      // Cards pushed above the top of the page come back down, below one another.
      if(tops.length&&tops[0]<HEADER+12){tops[0]=HEADER+12;for(let i=1;i<items.length;i++)tops[i]=Math.max(tops[i],tops[i-1]+items[i-1].height+GAP);}
      items.forEach((item,i)=>{
        const card=this.cards.get(item.id).dom;
        card.style.left=left+'px';card.style.top=Math.round(tops[i])+'px';card.style.width=CARD+'px';
        bottom=Math.max(bottom,tops[i]+item.height);
      });
      this.footer.style.left=left+'px';this.footer.style.top=Math.round(bottom+GAP)+'px';
    } else if(mode==='narrow') {
      const width=Math.min(CARD,Math.max(200,m.right-16));
      let previous=null,shift=0;
      for(const item of items) {
        const badge=this.badges.get(item.id);
        shift=previous!==null&&Math.abs(previous-item.top)<4?shift+34:0;previous=item.top;
        if(badge){badge.style.left=Math.round(Math.min(m.textRight+8+shift,m.clientRight-40-shift))+'px';badge.style.top=Math.round(item.top+2)+'px';}
        const card=this.cards.get(item.id).dom;
        if(item.id===active){card.style.left=Math.round(Math.max(8,m.right-width-12))+'px';card.style.top=Math.round(item.top+m.line+4)+'px';card.style.width=width+'px';}
      }
    }
  }
}, {
  eventObservers:{
    // Clicking commented text opens its card; clicking other text lets it go.
    click(event,view) {
      if(!view.state.selection.main.empty||!view.contentDOM.contains(event.target))return false;
      // The line may be redrawn between press and release, so the place
      // clicked is found from the pointer rather than from the element.
      const pos=view.posAtCoords({x:event.clientX,y:event.clientY});
      const {threads,active:current}=view.state.field(commentsField);
      let id=null,size=Infinity;
      if(pos!=null)for(const thread of threads)if(!thread.whole&&!thread.solved&&thread.from<=pos&&pos<=thread.to&&thread.to-thread.from<size){id=thread.id;size=thread.to-thread.from;}
      if(id!==current&&(id||current))view.dispatch({effects:setActive.of(id),annotations:outside});
      return false;
    }
  }
});}

export function comments(config) {
  return [commentsField,undoPlaces,commentsPanel(config),Prec.high(keymap.of([{key:'Mod-Shift-m',run:startComment}]))];
}
export const commentsTest={anchorComment,placeComments,serializeComments,similarity,startComment,commentsField,setActive,updateThread,removeThread};
