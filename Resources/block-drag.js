import { EditorSelection } from '@codemirror/state';
import { ViewPlugin, EditorView } from '@codemirror/view';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { uiMessages } from './ui-language.js';
import { blockCommands } from './slash-commands.js';
import { setBlock, currentBlock } from './format-toolbar.js';

// Feishu-style blocks: every paragraph, heading, code block, quote or callout,
// divider, table and top-level list item gets a ⋮⋮ handle on its left while the
// pointer is at its height. Dragging the handle moves the block; clicking it
// opens a menu to turn it into another kind, add a block below, copy or delete.
const TOP=new Set(['Paragraph','FencedCode','CodeBlock','Blockquote','HorizontalRule','Table','HTMLBlock','SetextHeading1','SetextHeading2','CommentBlock','ProcessingInstructionBlock','LinkReference']);
const TEXTUAL=new Set(['Paragraph','Blockquote','ListItem','ATXHeading1','ATXHeading2','ATXHeading3','ATXHeading4','ATXHeading5','ATXHeading6']);
const frontMatter=/^---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/;
const syntaxPrefix=/^ {0,3}(?:#{1,6}[ \t]+|(?:>[ \t]?)+(?:\[![\w-]+(?:\|[^\]\n]*)?\][+-]?[ \t]*)?|[-+*][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+)?/;
const cache=new WeakMap();

export function blocksOf(state) {
  const known=cache.get(state);if(known)return known;
  const tree=ensureSyntaxTree(state,state.doc.length,50)||syntaxTree(state),doc=state.doc,list=[];
  const head=frontMatter.exec(doc.sliceString(0,Math.min(doc.length,20000))),skip=head?head[0].length:0;
  const push=(kind,from,to)=>{
    if(from<skip||to<=from)return;
    const first=doc.lineAt(from),last=doc.lineAt(doc.sliceString(to-1,to)==='\n'?to-1:to);
    const previous=list.at(-1);
    if(previous&&first.from<=previous.to)return;
    list.push({kind,from:first.from,to:last.to});
  };
  for(let node=tree.topNode.firstChild;node;node=node.nextSibling) {
    if(node.name==='BulletList'||node.name==='OrderedList'){for(let item=node.firstChild;item;item=item.nextSibling)if(item.name==='ListItem')push('ListItem',item.from,item.to);}
    else if(TOP.has(node.name)||/^ATXHeading[1-6]$/.test(node.name))push(node.name,node.from,node.to);
  }
  cache.set(state,list);return list;
}
// The last block starting at or before `pos`, if `pos` is inside it.
function blockIndexAt(blocks,pos) {
  let lo=0,hi=blocks.length-1,found=-1;
  while(lo<=hi){const mid=(lo+hi)>>1;if(blocks[mid].from<=pos){found=mid;lo=mid+1;}else hi=mid-1;}
  return found>=0&&pos<=blocks[found].to?found:-1;
}
const listPair=(a,b)=>a?.kind==='ListItem'&&b?.kind==='ListItem';
// What sits between a block and the next: the text after the first and before the second.
const gap=(state,a,b)=>state.doc.sliceString(a.to,b.from);
const blank=text=>/\n[ \t]*\n/.test(text);
// What taking a block out removes: the block and one of the gaps beside it,
// keeping the wider gap, so a list followed by a blank line keeps that line.
function removal(state,blocks,index) {
  const block=blocks[index],next=blocks[index+1],previous=blocks[index-1];
  if(previous&&(!next||(blank(gap(state,block,next))&&!blank(gap(state,previous,block)))))return {from:previous.to,to:block.to};
  return next?{from:block.from,to:next.from}:{from:block.from,to:block.to};
}

// Moves block `index` to sit before block `to` (to may equal the block count:
// the end). The blank line a block leaves is taken with it; where it lands it
// gets one, except between list items, which stay one per line.
export function moveBlock(view,index,to,keepCaret=false) {
  const {state}=view,blocks=blocksOf(state),block=blocks[index];
  if(!block||state.readOnly||to===index||to===index+1||to<0||to>blocks.length)return false;
  const text=state.doc.sliceString(block.from,block.to),remove=removal(state,blocks,index);
  let at,insert,offset;
  if(to<blocks.length) {
    const target=blocks[to],before=blocks[to-1];
    // A paragraph dropped just under a list item needs a blank line, or it would
    // join that item as a continuation line.
    const lead=before&&before!==block&&!listPair(before,block)&&!blank(gap(state,before,target))?'\n':'';
    at=target.from;insert=lead+text+(listPair(block,target)?'\n':'\n\n');offset=lead.length;
  } else {
    const last=blocks.at(-1),separator=listPair(last,block)?'\n':'\n\n';
    at=last.to;insert=separator+text;offset=separator.length;
  }
  const changes=state.changes([remove,{from:at,insert}]);
  const head=state.selection.main.head,inside=keepCaret&&head>=block.from&&head<=block.to?head-block.from:0;
  const anchor=changes.mapPos(at,-1)+offset+inside;
  view.dispatch({changes,selection:EditorSelection.cursor(anchor),scrollIntoView:true,userEvent:'move.block'});
  view.focus();return true;
}
// ⌥⇧↑ / ⌥⇧↓ move the block with the caret up or down past its neighbour.
export function moveCurrentBlock(view,direction) {
  const {state}=view;if(state.readOnly||state.selection.ranges.length!==1)return false;
  const blocks=blocksOf(state),index=blockIndexAt(blocks,state.selection.main.head);
  if(index<0)return false;
  const to=direction<0?index-1:index+2;
  if(to<0||to>blocks.length)return true;
  return moveBlock(view,index,to,true);
}
function deleteBlock(view,index) {
  const {state}=view,blocks=blocksOf(state),block=blocks[index];if(!block||state.readOnly)return false;
  const range=removal(state,blocks,index);
  view.dispatch({changes:range,selection:EditorSelection.cursor(range.from),scrollIntoView:true,userEvent:'delete.block'});
  view.focus();return true;
}
function addBelow(view,index) {
  const {state}=view,block=blocksOf(state)[index];if(!block||state.readOnly)return false;
  view.dispatch({changes:{from:block.to,insert:'\n\n'},selection:EditorSelection.cursor(block.to+2),scrollIntoView:true,userEvent:'input.block'});
  view.focus();return true;
}
function copyBlock(view,index) {
  const block=blocksOf(view.state)[index];if(!block)return false;
  view.dispatch({selection:EditorSelection.range(block.from,block.to)});view.focus();
  try{view.dom.ownerDocument.execCommand('copy');}catch{}
  return true;
}
function turnInto(view,index,id) {
  const block=blocksOf(view.state)[index];if(!block)return false;
  view.dispatch({selection:EditorSelection.cursor(block.from+(syntaxPrefix.exec(view.state.doc.lineAt(block.from).text)?.[0].length||0))});
  setBlock(id)(view);view.focus();return true;
}

const dots='<svg viewBox="0 0 10 16" aria-hidden="true"><circle cx="2.5" cy="3" r="1.4"/><circle cx="7.5" cy="3" r="1.4"/><circle cx="2.5" cy="8" r="1.4"/><circle cx="7.5" cy="8" r="1.4"/><circle cx="2.5" cy="13" r="1.4"/><circle cx="7.5" cy="13" r="1.4"/></svg>';

export const blockHandles=ViewPlugin.fromClass(class {
  constructor(view) {
    this.view=view;this.index=-1;this.hideTimer=null;this.dragging=false;this.dragged=false;
    const doc=view.dom.ownerDocument;
    this.handle=doc.createElement('button');this.handle.type='button';this.handle.tabIndex=-1;this.handle.className='cm-block-handle';this.handle.innerHTML=dots;this.handle.hidden=true;
    this.handle.addEventListener('mousedown',event=>{event.preventDefault();if(event.button===0&&this.index>=0)this.startDrag(event);});
    this.handle.addEventListener('click',()=>{if(this.dragged){this.dragged=false;return;}if(this.index<0)this.openInsert();else this.openMenu();});
    this.handle.addEventListener('mouseenter',()=>clearTimeout(this.hideTimer));
    this.indicator=doc.createElement('div');this.indicator.className='cm-block-drop';this.indicator.hidden=true;
    this.menu=doc.createElement('div');this.menu.className='cm-block-menu';this.menu.setAttribute('role','menu');this.menu.hidden=true;
    this.menu.addEventListener('mousedown',event=>event.preventDefault());
    view.dom.append(this.handle,this.indicator,this.menu);
    this.move=event=>this.track(event);
    this.leave=()=>{if(!this.dragging&&this.menu.hidden){clearTimeout(this.hideTimer);this.hideTimer=setTimeout(()=>this.hide(),300);}};
    this.outside=event=>{if(!this.menu.hidden&&!this.menu.contains(event.target)&&event.target!==this.handle&&!this.handle.contains(event.target))this.hide();};
    this.key=event=>{if(event.key==='Escape'&&!this.menu.hidden){event.preventDefault();this.hide();}};
    view.scrollDOM.addEventListener('mousemove',this.move);
    view.dom.addEventListener('mouseleave',this.leave);
    doc.addEventListener('mousedown',this.outside,true);
    doc.addEventListener('keydown',this.key,true);
  }
  usable() {return globalThis.acdianTouch!==true&&this.view.state.facet(EditorView.editable)&&!this.view.state.readOnly;}
  textLeft() {const content=this.view.contentDOM,rect=content.getBoundingClientRect();return rect.left+parseFloat(getComputedStyle(content).paddingLeft||'0');}
  // The block at a height in the window, or -1.
  indexAtY(y) {
    const view=this.view,line=view.lineBlockAtHeight(y-view.documentTop);
    return blockIndexAt(blocksOf(view.state),line.from);
  }
  // The block's first line of text, in window coordinates, for placing its handle.
  firstLine(block) {
    const view=this.view,line=view.state.doc.lineAt(block.from),start=line.from+(syntaxPrefix.exec(line.text)?.[0].length||0);
    const coords=start<=line.to?view.coordsAtPos(start,1):null;
    if(coords&&coords.bottom-coords.top>=8)return {top:coords.top,bottom:coords.bottom};
    const box=view.lineBlockAt(block.from),top=view.documentTop+box.top;
    return {top,bottom:top+Math.min(box.height,28)};
  }
  track(event) {
    if(this.dragging||!this.menu.hidden)return;
    if(!this.usable()||event.target.closest?.('.cm-tooltip,.cm-table-menu,.cm-table-picker')){this.hide();return;}
    const index=this.indexAtY(event.clientY);
    if(index<0){this.trackEmpty(event);return;}
    clearTimeout(this.hideTimer);
    this.plus=null;this.handle.classList.remove('cm-block-plus');this.handle.innerHTML=dots;
    const block=blocksOf(this.view.state)[index],line=this.firstLine(block),host=this.view.dom.getBoundingClientRect();
    const height=Math.max(20,Math.min(28,line.bottom-line.top));
    this.index=index;
    Object.assign(this.handle.style,{left:(Math.max(host.left+2,this.textLeft()-52)-host.left)+'px',top:((line.top+line.bottom)/2-height/2-host.top)+'px',height:height+'px'});
    const strings=uiMessages(this.view.state).blockUI;this.handle.title=strings.handle;this.handle.setAttribute('aria-label',strings.handle);
    this.handle.hidden=false;
  }
  // An empty line gets a + in the handle's place, which opens the insert menu there, as in Feishu.
  trackEmpty(event) {
    const view=this.view,line=view.lineBlockAtHeight(event.clientY-view.documentTop),text=view.state.doc.lineAt(line.from);
    if(text.text.trim()||line.height<12||line.from!==text.from){this.leave();return;}
    clearTimeout(this.hideTimer);
    const host=view.dom.getBoundingClientRect(),top=view.documentTop+line.top,height=Math.min(28,line.height);
    this.index=-1;this.plus=text.from;this.handle.classList.add('cm-block-plus');this.handle.textContent='+';
    Object.assign(this.handle.style,{left:(Math.max(host.left+2,this.textLeft()-52)-host.left)+'px',top:(top+(line.height-height)/2-host.top)+'px',height:height+'px'});
    const strings=uiMessages(view.state).blockUI;this.handle.title=strings.insert;this.handle.setAttribute('aria-label',strings.insert);
    this.handle.hidden=false;
  }
  openInsert() {
    const view=this.view,at=this.plus;if(at===null||at===undefined||view.state.readOnly)return;
    this.hide();
    view.dispatch({selection:EditorSelection.cursor(at)});view.focus();
    view.dispatch({changes:{from:at,insert:'/'},selection:EditorSelection.cursor(at+1),userEvent:'input.type'});
  }
  hide() {if(this.dragging)return;clearTimeout(this.hideTimer);this.handle.hidden=this.menu.hidden=this.indicator.hidden=true;}
  // Where a drop at this height would go: before block `to`, and the line's place.
  dropAt(y,blocks) {
    const view=this.view,line=view.lineBlockAtHeight(y-view.documentTop);
    let index=blockIndexAt(blocks,line.from);
    if(index<0){let lo=0,hi=blocks.length-1;index=blocks.length;while(lo<=hi){const mid=(lo+hi)>>1;if(blocks[mid].from>line.from){index=mid;hi=mid-1;}else lo=mid+1;}return index;}
    const top=view.documentTop+view.lineBlockAt(blocks[index].from).top,bottom=view.documentTop+view.lineBlockAt(blocks[index].to).bottom;
    return y<(top+bottom)/2?index:index+1;
  }
  startDrag(down) {
    const view=this.view,from=this.index;if(from<0)return;
    const doc=view.dom.ownerDocument;let target=null;
    const move=event=>{
      if(!this.dragging&&Math.hypot(event.clientX-down.clientX,event.clientY-down.clientY)<4)return;
      if(!this.dragging){this.dragging=true;this.menu.hidden=true;doc.body.classList.add('cm-block-dragging');}
      const scroller=view.scrollDOM.getBoundingClientRect();
      if(event.clientY<scroller.top+40)view.scrollDOM.scrollTop-=14;else if(event.clientY>scroller.bottom-40)view.scrollDOM.scrollTop+=14;
      const blocks=blocksOf(view.state);target=this.dropAt(event.clientY,blocks);
      const host=view.dom.getBoundingClientRect(),content=view.contentDOM,left=this.textLeft(),width=content.getBoundingClientRect().right-parseFloat(getComputedStyle(content).paddingRight||'0')-left;
      const edge=target<blocks.length?view.documentTop+view.lineBlockAt(blocks[target].from).top:view.documentTop+view.lineBlockAt(blocks.at(-1).to).bottom;
      const show=target!==from&&target!==from+1;
      this.indicator.hidden=!show;
      Object.assign(this.indicator.style,{left:(left-host.left)+'px',top:(edge-host.top-1)+'px',width:Math.max(40,width)+'px'});
    };
    const up=()=>{
      window.removeEventListener('mousemove',move,true);window.removeEventListener('mouseup',up,true);
      doc.body.classList.remove('cm-block-dragging');this.indicator.hidden=true;
      if(!this.dragging)return;
      this.dragging=false;this.dragged=true;setTimeout(()=>{this.dragged=false;},0);
      this.hide();
      if(target!==null)moveBlock(view,from,target);
    };
    window.addEventListener('mousemove',move,true);window.addEventListener('mouseup',up,true);
  }
  openMenu() {
    const view=this.view,index=this.index,block=blocksOf(view.state)[index];if(!block)return;
    const strings=uiMessages(view.state),doc=view.dom.ownerDocument;
    const button=(className,text,run,title)=>{const element=doc.createElement('button');element.type='button';element.tabIndex=-1;element.className=className;element.textContent=text;if(title){element.title=title;element.setAttribute('aria-label',title);}
      element.setAttribute('role','menuitem');element.addEventListener('click',()=>{this.hide();run();});return element;};
    const parts=[];
    if(TEXTUAL.has(block.kind)) {
      const current=currentBlock(view.state,block.from),types=doc.createElement('div');types.className='cm-block-menu-types';
      types.title=strings.turnInto;
      for(const command of blockCommands) {
        const element=button('cm-block-menu-type',command.icon,()=>turnInto(view,index,command.id),strings.commands[command.id][0]);
        element.setAttribute('aria-checked',String(command.id===current));types.append(element);
      }
      parts.push(types);
    }
    parts.push(button('cm-block-menu-item',strings.blockUI.addBelow,()=>addBelow(view,index)));
    parts.push(button('cm-block-menu-item',strings.blockUI.copy,()=>copyBlock(view,index)));
    parts.push(button('cm-block-menu-item cm-block-menu-danger',strings.blockUI.delete,()=>deleteBlock(view,index)));
    this.menu.replaceChildren(...parts);this.menu.hidden=false;
    const host=view.dom.getBoundingClientRect(),box=this.handle.getBoundingClientRect();
    Object.assign(this.menu.style,{left:(box.left-host.left)+'px',top:(box.bottom-host.top+4)+'px'});
  }
  update(update) {if(update.docChanged&&!this.dragging)this.hide();}
  destroy() {
    const doc=this.view.dom.ownerDocument;clearTimeout(this.hideTimer);
    this.handle.remove();this.indicator.remove();this.menu.remove();
    this.view.scrollDOM.removeEventListener('mousemove',this.move);this.view.dom.removeEventListener('mouseleave',this.leave);
    doc.removeEventListener('mousedown',this.outside,true);doc.removeEventListener('keydown',this.key,true);
  }
});
export const blockDragTest={blocksOf,moveBlock,moveCurrentBlock};
