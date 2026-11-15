import { EditorState, EditorSelection, StateField, StateEffect } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin } from '@codemirror/view';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { uiMessages } from './ui-language.js';

// Every cell remains a span in CodeMirror's one editable document. The source
// pipes and padding stay in the DOM, with permanently hidden syntax marks.
const syntaxClass='cm-table-syntax cm-format-delimiter';
const cache=new WeakMap();
const clamp=(value,min,max)=>Math.max(min,Math.min(value,max));

function parseRow(state,node,header=false) {
  const line=state.doc.lineAt(node.from),text=state.doc.sliceString(node.from,node.to);
  return parseRowText(text,node.from,line,header);
}
function parseRowText(text,from,line,header=false) {
  const pipes=[],escaped=[];
  for(let index=0;index<text.length;index++)if(text[index]==='|') {
    let slashes=0;for(let at=index-1;at>=0&&text[at]==='\\';at--)slashes++;
    if(slashes%2)escaped.push(from+index-1);else pipes.push(index);
  }
  const first=text.search(/\S/),last=text.search(/\s*$/);
  const leading=pipes[0]===first?pipes[0]:null;
  const trailing=pipes.at(-1)===last-1?pipes.at(-1):null;
  const start=leading===null?0:leading+1,end=trailing===null?text.length:trailing;
  const boundaries=pipes.filter(pos=>pos>=start&&pos<end),cells=[];
  let rawStart=start,markStart=leading===null?0:leading;
  for(const rawEnd of [...boundaries,end]) {
    const raw=text.slice(rawStart,rawEnd),left=/^\s*/.exec(raw)[0].length,right=/\s*$/.exec(raw)[0].length;
    const empty=!raw.trim();
    const contentFrom=from+rawStart+(empty?Math.min(1,raw.length):left);
    const contentTo=empty?contentFrom:from+rawEnd-right;
    cells.push({index:cells.length,markFrom:from+markStart,rawFrom:from+rawStart,rawTo:from+rawEnd,contentFrom,contentTo});
    markStart=rawEnd;rawStart=rawEnd+1;
  }
  return {from,to:from+text.length,text,line,header,cells,pipes:pipes.map(pos=>from+pos),escaped,trailing:trailing!==null,
    prefix:line.text.slice(0,from-line.from)};
}
function modelFor(state,node) {
  const rows=[];let separator=null;
  for(let child=node.firstChild;child;child=child.nextSibling) {
    if(child.name==='TableHeader'||child.name==='TableRow')rows.push(parseRow(state,child,child.name==='TableHeader'));
    else if(child.name==='TableDelimiter'&&child.to-child.from>1)separator={from:child.from,to:child.to,line:state.doc.lineAt(child.from)};
  }
  if(!rows.length||!separator)return null;
  const columns=Math.max(...rows.map(row=>row.cells.length));
  const alignment=parseRowText(state.doc.sliceString(separator.from,separator.to),separator.from,separator.line).cells.map(cell=>{
    const value=state.doc.sliceString(cell.rawFrom,cell.rawTo).trim();
    return value.startsWith(':')?(value.endsWith(':')?'center':'left'):(value.endsWith(':')?'right':'left');
  });
  return {from:node.from,to:node.to,rows,separator,columns,alignment,widths:widthsFor(state.doc.sliceString(separator.from,separator.to),columns)};
}
// A separator written without spaces, like |----|--------|, sets each column's
// width from its number of dashes (as Pandoc reads it). Any other keeps equal columns.
function widthsFor(text,columns) {
  const equal=Array(columns).fill(1/columns);
  if(/\s/.test(text.trim()))return equal;
  const dashes=text.trim().replace(/^\||\|$/g,'').split('|').map(cell=>(cell.match(/-/g)||[]).length);
  if(dashes.length!==columns||dashes.some(count=>!count))return equal;
  const total=dashes.reduce((sum,count)=>sum+count,0);
  return dashes.map(count=>count/total);
}
function separatorText(state,table,widths) {
  const raw=state.doc.sliceString(table.separator.from,table.separator.to).trim().replace(/^\||\|$/g,'').split('|');
  return '|'+widths.map((width,index)=>{
    const cell=(raw[index]||'').trim();
    return (cell.startsWith(':')?':':'')+'-'.repeat(Math.max(3,Math.round(width*100)))+(cell.length>1&&cell.endsWith(':')?':':'');
  }).join('|')+'|';
}
function rowStyle(widths) {
  let at=0;const edges=widths.map(width=>at+=width);
  return `--table-columns:${widths.length};background-image:${edges.map(()=>'linear-gradient(var(--table-line),var(--table-line))').join(',')};`+
    `background-size:1px 100%;background-repeat:no-repeat;background-position:${edges.map(edge=>`calc(${(edge*100).toFixed(3)}% + ${(edge-1).toFixed(3)}px) 0`).join(',')}`;
}
function tableNodes(tree) {
  if(tree.name==='Table')return [tree];
  const nodes=[];tree.iterate({enter(node){if(node.name==='Table'){nodes.push(node.node);return false;}}});return nodes;
}
function models(state) {
  const tree=ensureSyntaxTree(state,state.doc.length,30)||syntaxTree(state),previous=cache.get(state);
  if(previous?.tree===tree)return previous.models;
  const result=tableNodes(tree).map(node=>modelFor(state,node)).filter(Boolean);
  cache.set(state,{tree,models:result});return result;
}
function locate(state,pos,preferredColumn=0) {
  for(const table of models(state)) {
    const line=state.doc.lineAt(pos);
    let row=table.rows.find(candidate=>candidate.line.number===line.number);
    if(!row&&line.number===table.separator.line.number)row=table.rows[1]||table.rows[0];
    if(!row)continue;
    if(line.number===table.separator.line.number)return {table,row,cell:row.cells[Math.min(preferredColumn,row.cells.length-1)]};
    let cell=row.cells[0],distance=Infinity;
    for(const candidate of row.cells) {
      const next=Math.abs(pos-clamp(pos,candidate.contentFrom,candidate.contentTo));
      if(next<distance){distance=next;cell=candidate;}
    }
    return {table,row,cell};
  }
  return null;
}

/** Accepts either one Table SyntaxNode or the complete Lezer tree. */
export function tableDecorations(state,tree) {
  const result=[];
  const hide=(from,to)=>{if(from<to)result.push(Decoration.mark({class:syntaxClass}).range(from,to));};
  const preview=state.field(tableWidthField,false);
  for(const node of tableNodes(tree)) {
    const table=modelFor(state,node);if(!table)continue;
    const widths=preview?.from===table.from&&preview.widths.length===table.columns?preview.widths:table.widths,style=rowStyle(widths);
    for(const [index,row] of table.rows.entries()) {
      result.push(Decoration.line({class:'cm-table-row'+(row.header?' cm-table-header':'')+(index===0?' cm-table-first':'')+(index===table.rows.length-1?' cm-table-last':''),
        attributes:{style}}).range(row.line.from));
      for(const cell of row.cells) {
        if(cell.markFrom<cell.rawTo)result.push(Decoration.mark({class:'cm-table-cell',inclusive:true,attributes:{
          // Keep DOM attributes stable while text changes. Position attributes
          // would force CM to split an active IME composition into multiple
          // styled cell spans as the cell's end offset grows.
          'data-table-cell':String(cell.index),
          style:`text-align:${table.alignment[cell.index]||'left'};width:${Math.floor((widths[cell.index]||0)*1e5)/1e3}%`
        }}).range(cell.markFrom,cell.rawTo));
        hide(cell.rawFrom,cell.contentFrom);hide(cell.contentTo,cell.rawTo);
        // The selected part of the cell's own text, so a selection highlights text, not rows.
        for(const range of state.selection.ranges) {
          const from=Math.max(range.from,cell.contentFrom),to=Math.min(range.to,cell.contentTo);
          if(!range.empty&&from<to)result.push(Decoration.mark({class:'cm-selected-text'}).range(from,to));
        }
      }
      for(const pipe of row.pipes)hide(pipe,pipe+1);
      for(const slash of row.escaped)hide(slash,slash+1);
      if(row.from<row.cells[0].markFrom)hide(row.from,row.cells[0].markFrom);
      const trailingStart=row.pipes.at(-1);
      if(row.trailing)hide(trailingStart+1,row.to);
    }
    result.push(Decoration.line({class:'cm-table-row cm-table-separator',attributes:{style:`--table-columns:${table.columns}`}}).range(table.separator.line.from));
    hide(table.separator.line.from,table.separator.line.to);
  }
  return result;
}

// A click on an empty cell can map to its invisible pipe or padding. Clamp only
// an empty caret selection, leaving text ranges, composition and undo native.
export const tableSelectionFilter=EditorState.transactionFilter.of(transaction=>{
  if(transaction.docChanged||!transaction.selection||transaction.newSelection.ranges.length!==1||!transaction.newSelection.main.empty)return transaction;
  const state=transaction.state,pos=transaction.newSelection.main.head;
  const old=locate(transaction.startState,transaction.startState.selection.main.head);
  const context=locate(state,pos,old?.cell.index||0);
  if(!context)return transaction;
  const target=clamp(pos,context.cell.contentFrom,context.cell.contentTo);
  return target===pos?transaction:[transaction,{selection:EditorSelection.cursor(target),sequential:true}];
});

function selectedContext(view) {
  if(view.composing||view.state.selection.ranges.length!==1)return null;
  const range=view.state.selection.main,context=locate(view.state,range.head);
  return context?{...context,range}:null;
}
function select(view,pos) {view.dispatch({selection:EditorSelection.cursor(pos),scrollIntoView:true,userEvent:'select.table'});return true;}
function neighboring(context,direction) {
  const {table,row,cell}=context,index=table.rows.indexOf(row),next=cell.index+direction;
  if(next>=0&&next<row.cells.length)return row.cells[next];
  const adjacent=table.rows[index+direction];
  return adjacent?(direction>0?adjacent.cells[0]:adjacent.cells.at(-1)):null;
}
function appendRow(view,context) {
  if(view.state.readOnly)return false;
  const {table,row,cell}=context;
  const after=row.header?table.separator.line.to:row.line.to;
  const text='| '+Array(table.columns).fill('').join(' | ')+' |',insert='\n'+row.prefix+text;
  const parsed=parseRowText(text,after+1+row.prefix.length,{from:after+1,text:row.prefix+text});
  const target=parsed.cells[Math.min(cell.index,parsed.cells.length-1)].contentFrom;
  view.dispatch({changes:{from:after,insert},selection:EditorSelection.cursor(target),scrollIntoView:true,userEvent:'input.table-row'});
  return true;
}
function tab(view,direction) {
  const context=selectedContext(view);if(!context)return false;
  if(direction>0&&context.cell.index===context.row.cells.length-1&&context.row.cells.length<context.table.columns&&!view.state.readOnly) {
    const {row,table,cell}=context,count=table.columns-row.cells.length;
    const insert=(row.trailing?'':' |')+'  |'.repeat(count);
    const parsed=parseRowText(row.text+insert,row.from,row.line,row.header);
    view.dispatch({changes:{from:row.to,insert},selection:EditorSelection.cursor(parsed.cells[cell.index+1].contentFrom),scrollIntoView:true,userEvent:'input.table-cells'});return true;
  }
  const next=neighboring(context,direction);
  if(next)return select(view,next.contentFrom);
  if(direction>0)return view.state.readOnly?true:appendRow(view,{...context,cell:{index:0}});
  return true;
}
function arrow(view,direction) {
  const context=selectedContext(view);if(!context||!context.range.empty)return false;
  const {range,cell,row,table}=context;
  if(direction<0?range.head>cell.contentFrom:range.head<cell.contentTo)return false;
  const next=neighboring(context,direction);
  if(next)return select(view,direction>0?next.contentFrom:next.contentTo);
  const line=direction>0?view.state.doc.lineAt(table.to):row.line;
  if(direction>0&&line.number<view.state.doc.lines)return select(view,view.state.doc.line(line.number+1).from);
  if(direction<0&&line.number>1)return select(view,view.state.doc.line(line.number-1).to);
  return true;
}
function eraseSelection(view,context) {
  const {range,table}=context;
  if(range.empty||range.from<table.from||range.to>table.to)return false;
  const start=locate(view.state,range.from),end=locate(view.state,range.to);
  if(!start||!end||start.table!==table||end.table!==table)return false;
  if(start.row===end.row&&start.cell===end.cell&&range.from>=start.cell.contentFrom&&range.to<=start.cell.contentTo)return false;
  const changes=[];
  for(const row of table.rows)for(const cell of row.cells) {
    const from=Math.max(range.from,cell.contentFrom),to=Math.min(range.to,cell.contentTo);
    if(from<to)changes.push({from,to});
  }
  if(!changes.length)return select(view,start.cell.contentFrom);
  view.dispatch({changes,selection:EditorSelection.cursor(changes[0].from),scrollIntoView:true,userEvent:'delete.table-content'});return true;
}
function protectDelete(view,forward) {
  const context=selectedContext(view);if(!context||view.state.readOnly)return false;
  if(!context.range.empty)return eraseSelection(view,context);
  const boundary=forward?context.cell.contentTo:context.cell.contentFrom;
  if(forward?context.range.head<boundary:context.range.head>boundary)return false;
  const next=neighboring(context,forward?1:-1);
  return next?select(view,forward?next.contentFrom:next.contentTo):true;
}
function insertPipe(view) {
  const context=selectedContext(view);if(!context||view.state.readOnly)return false;
  const {range,cell}=context;
  if(range.from<cell.contentFrom||range.to>cell.contentTo)return false;
  view.dispatch({changes:{from:range.from,to:range.to,insert:'\\|'},selection:EditorSelection.cursor(range.from+2),userEvent:'input.type'});return true;
}

export const tableKeymap=[
  {key:'Tab',run:view=>tab(view,1)},{key:'Shift-Tab',run:view=>tab(view,-1)},
  {key:'Enter',run(view){const context=selectedContext(view);return context?appendRow(view,context):false;}},
  {key:'Backspace',run:view=>protectDelete(view,false)},{key:'Delete',run:view=>protectDelete(view,true)},
  {key:'ArrowLeft',run:view=>arrow(view,-1)},{key:'ArrowRight',run:view=>arrow(view,1)},
  {key:'Home',run(view){const context=selectedContext(view);return context?select(view,context.cell.contentFrom):false;}},
  {key:'End',run(view){const context=selectedContext(view);return context?select(view,context.cell.contentTo):false;}},
  {key:'|',run:insertPipe}
];

const previewWidths=StateEffect.define();
export const tableWidthField=StateField.define({
  create:()=>null,
  update(value,tr){for(const effect of tr.effects)if(effect.is(previewWidths))return effect.value;return tr.docChanged?null:value;}
});

function resizeTarget(view,event) {
  const cell=event.target?.closest?.('.cm-table-cell');if(!cell)return null;
  const rect=cell.getBoundingClientRect();let index=Number(cell.dataset.tableCell);
  if(event.clientX<=rect.left+5&&index>0)index--;else if(event.clientX<rect.right-5)return null;
  const context=locate(view.state,view.posAtDOM(cell));
  if(!context||index>=context.table.columns-1)return null;
  return {table:context.table,index,line:cell.closest('.cm-line')};
}
const resizeCursor=on=>document.body.classList.toggle('cm-table-col-resize',on);
let resizing=false;

export const tableColumnResize=EditorView.domEventHandlers({
  mousemove(event,view) {if(!resizing)resizeCursor(view.state.facet(EditorView.editable)&&!view.state.readOnly&&!!resizeTarget(view,event));return false;},
  mouseleave() {if(!resizing)resizeCursor(false);return false;},
  mousedown(event,view) {
    if(event.button!==0||!view.state.facet(EditorView.editable)||view.state.readOnly)return false;
    const target=resizeTarget(view,event);if(!target)return false;
    event.preventDefault();resizing=true;resizeCursor(true);
    const {table,index}=target,start=event.clientX,width=target.line.getBoundingClientRect().width||1;
    const base=table.widths,pair=base[index]+base[index+1],least=Math.min(.06,pair/2);
    let widths=base;
    const move=moveEvent=>{
      const left=Math.round(clamp(base[index]+(moveEvent.clientX-start)/width,least,pair-least)*100)/100;
      widths=base.map((value,at)=>at===index?left:at===index+1?pair-left:value);
      view.dispatch({effects:previewWidths.of({from:table.from,widths})});
    };
    const up=()=>{
      window.removeEventListener('mousemove',move);window.removeEventListener('mouseup',up);
      resizing=false;resizeCursor(false);
      const current=models(view.state).find(candidate=>candidate.from===table.from);
      if(!current||widths===base||current.columns!==widths.length){view.dispatch({effects:previewWidths.of(null)});return;}
      const insert=separatorText(view.state,current,widths);
      view.dispatch({changes:{from:current.separator.from,to:current.separator.to,insert},effects:previewWidths.of(null),userEvent:'input.table-width'});
    };
    window.addEventListener('mousemove',move);window.addEventListener('mouseup',up);
    return true;
  }
});

// Adds an empty column at the right of every row. A separator with spaces keeps
// equal columns; one written with dash counts gives the new column an average share.
function appendColumn(view,table) {
  if(view.state.readOnly)return false;
  const {state}=view,changes=[];
  for(const row of table.rows)changes.push({from:row.to,insert:row.trailing?'  |':' |  |'});
  const separator=state.doc.sliceString(table.separator.from,table.separator.to),compact=!/\s/.test(separator.trim());
  const counts=separator.trim().replace(/^\||\|$/g,'').split('|').map(cell=>(cell.match(/-/g)||[]).length);
  const dashes=compact?'-'.repeat(Math.max(3,Math.round(counts.reduce((sum,count)=>sum+count,0)/counts.length))):' --- ';
  changes.push({from:table.separator.to,insert:(separator.trimEnd().endsWith('|')?'':'|')+dashes+'|'});
  const header=table.rows[0],cell=header.to+(header.trailing?1:3);
  view.dispatch({changes,selection:EditorSelection.cursor(cell),scrollIntoView:true,userEvent:'input.table-column'});
  view.focus();return true;
}

// The whole table's lines, with the blank line it leaves behind folded away.
function tableLines(state,table) {
  const first=state.doc.lineAt(table.from);let last=state.doc.lineAt(table.to);
  if(last.number<state.doc.lines&&!state.doc.line(last.number+1).text.trim()&&first.number>1&&!state.doc.line(first.number-1).text.trim())last=state.doc.line(last.number+1);
  return last.number<state.doc.lines?{from:first.from,to:last.to+1}:{from:first.number>1?first.from-1:first.from,to:last.to};
}
// Deletes one row. Deleting the header makes the next row the header; deleting
// the only row deletes the table.
function deleteRow(view,table,index) {
  if(view.state.readOnly)return false;
  const {state}=view,row=table.rows[index];if(!row)return false;
  let change,anchor;
  if(table.rows.length===1){change={...tableLines(state,table),insert:''};anchor=change.from;}
  else if(row.header) {
    const next=table.rows[1],separator=state.doc.sliceString(table.separator.line.from,table.separator.line.to);
    change={from:row.line.from,to:next.line.to,insert:next.line.text+'\n'+separator};anchor=row.line.from+(next.cells[0].contentFrom-next.line.from);
  } else {
    const line=row.line;
    change=line.number<state.doc.lines?{from:line.from,to:line.to+1,insert:''}:{from:line.from-1,to:line.to,insert:''};
    const neighbour=table.rows[index+1]||table.rows[index-1];
    anchor=neighbour.cells[0].contentFrom;anchor=anchor>line.from?anchor-(line.to+1-line.from):anchor;
  }
  view.dispatch({changes:change,selection:EditorSelection.cursor(Math.min(anchor,state.doc.length-(change.to-change.from)+change.insert.length)),scrollIntoView:true,userEvent:'delete.table-row'});
  view.focus();return true;
}
// Deletes one column from every row and the separator; the last column deletes the table.
function deleteColumn(view,table,index) {
  if(view.state.readOnly)return false;
  const {state}=view;
  if(table.columns<=1){const change={...tableLines(state,table),insert:''};view.dispatch({changes:change,selection:EditorSelection.cursor(change.from),userEvent:'delete.table-column'});view.focus();return true;}
  const separator=parseRowText(state.doc.sliceString(table.separator.from,table.separator.to),table.separator.from,table.separator.line);
  const changes=[];
  for(const row of [...table.rows,separator]) {
    const cell=row.cells[index];if(!cell)continue;
    if(index<row.cells.length-1)changes.push({from:cell.rawFrom,to:cell.rawTo+1});
    else changes.push({from:Math.max(row.from,cell.rawFrom-1),to:cell.rawTo});
  }
  const set=state.changes(changes),header=table.rows[0],target=header.cells[Math.min(index,header.cells.length-2)]||header.cells[0];
  view.dispatch({changes:set,selection:EditorSelection.cursor(set.mapPos(target.contentFrom,-1)),scrollIntoView:true,userEvent:'delete.table-column'});
  view.focus();return true;
}

// Hovering a table shows a + bar under its last row and one right of its last
// column, as in Feishu; clicking adds a row or a column.
export const tableAddControls=ViewPlugin.fromClass(class {
  constructor(view) {
    this.view=view;this.table=null;this.hideTimer=null;
    const bar=(className,label,run)=>{
      const element=document.createElement('button');element.type='button';element.tabIndex=-1;element.className='cm-table-add '+className;element.textContent='+';element.hidden=true;
      element.setAttribute('aria-label',label);
      element.addEventListener('mousedown',event=>event.preventDefault());
      element.addEventListener('click',()=>{const table=this.current();if(table)run(table);this.hide();});
      element.addEventListener('mouseenter',()=>clearTimeout(this.hideTimer));
      element.addEventListener('mouseleave',()=>this.later());
      view.dom.append(element);return element;
    };
    this.row=bar('cm-table-add-row','',table=>appendRow(view,{table,row:table.rows.at(-1),cell:{index:0}})&&view.focus());
    this.column=bar('cm-table-add-column','',table=>appendColumn(view,table));
    // Handles beside the row and above the column under the pointer open a small
    // menu to delete that row or column, as in Feishu.
    this.rowIndex=0;this.columnIndex=0;
    const handle=(className,kind)=>{
      const element=document.createElement('button');element.type='button';element.tabIndex=-1;element.className='cm-table-handle '+className;element.hidden=true;
      element.addEventListener('mousedown',event=>event.preventDefault());
      element.addEventListener('click',()=>this.openMenu(kind,element));
      element.addEventListener('mouseenter',()=>clearTimeout(this.hideTimer));
      element.addEventListener('mouseleave',()=>this.later());
      view.dom.append(element);return element;
    };
    this.rowHandle=handle('cm-table-handle-row','row');
    this.columnHandle=handle('cm-table-handle-column','column');
    this.menu=document.createElement('div');this.menu.className='cm-table-menu';this.menu.setAttribute('role','menu');this.menu.hidden=true;
    this.menu.addEventListener('mousedown',event=>event.preventDefault());
    this.menu.addEventListener('mouseenter',()=>clearTimeout(this.hideTimer));
    this.menu.addEventListener('mouseleave',()=>this.later());
    view.dom.append(this.menu);
    this.outside=event=>{if(!this.menu.hidden&&!this.menu.contains(event.target)&&!event.target.closest?.('.cm-table-handle'))this.hide();};
    view.dom.ownerDocument.addEventListener('mousedown',this.outside,true);
    this.move=event=>this.track(event);
    this.leave=()=>this.later();
    this.scroll=()=>this.hide();
    view.contentDOM.addEventListener('mousemove',this.move);
    view.contentDOM.addEventListener('mouseleave',this.leave);
    view.scrollDOM.addEventListener('scroll',this.scroll,{passive:true});
  }
  current() {return this.table===null?null:models(this.view.state).find(table=>table.from===this.table)||null;}
  openMenu(kind,anchor) {
    const strings=uiMessages(this.view.state).tableUI,item=document.createElement('button');
    item.type='button';item.tabIndex=-1;item.className='cm-table-menu-item';item.setAttribute('role','menuitem');
    item.textContent=kind==='row'?strings.deleteRow:strings.deleteColumn;
    const index=kind==='row'?this.rowIndex:this.columnIndex;
    item.addEventListener('click',()=>{const table=this.current();this.hide();if(table)(kind==='row'?deleteRow:deleteColumn)(this.view,table,index);});
    this.menu.replaceChildren(item);this.menu.hidden=false;this.menuOpen=true;
    const host=this.view.dom.getBoundingClientRect(),box=anchor.getBoundingClientRect();
    Object.assign(this.menu.style,kind==='row'?{left:(box.left-host.left)+'px',top:(box.bottom-host.top+4)+'px'}:{left:(box.left-host.left)+'px',top:(box.bottom-host.top+4)+'px'});
  }
  track(event) {
    const view=this.view,line=event.target?.closest?.('.cm-table-row');
    if(!line||!view.state.facet(EditorView.editable)||view.state.readOnly){this.later();return;}
    let context=null;try{context=locate(view.state,view.posAtDOM(line));}catch{}
    if(!context){this.later();return;}
    clearTimeout(this.hideTimer);
    let first=line,last=line;
    while(first.previousElementSibling?.classList.contains('cm-table-row')&&!first.classList.contains('cm-table-first'))first=first.previousElementSibling;
    while(last.nextElementSibling?.classList.contains('cm-table-row')&&!last.classList.contains('cm-table-last'))last=last.nextElementSibling;
    const host=view.dom.getBoundingClientRect(),top=first.getBoundingClientRect(),bottom=last.getBoundingClientRect();
    if(this.menuOpen)return;
    this.table=context.table.from;
    const strings=uiMessages(view.state).tableUI;
    this.row.title=strings.addRow;this.row.setAttribute('aria-label',strings.addRow);
    this.column.title=strings.addColumn;this.column.setAttribute('aria-label',strings.addColumn);
    this.rowIndex=context.table.rows.indexOf(context.row);
    const rowBox=line.getBoundingClientRect(),cellElement=event.target.closest('.cm-table-cell');
    if(cellElement)this.columnIndex=Number(cellElement.dataset.tableCell)||0;
    const headerCell=first.querySelector(`.cm-table-cell[data-table-cell="${this.columnIndex}"]`),columnBox=(headerCell||cellElement||first).getBoundingClientRect();
    Object.assign(this.rowHandle.style,{left:(top.left-host.left-18)+'px',top:(rowBox.top-host.top)+'px',height:rowBox.height+'px'});
    Object.assign(this.columnHandle.style,{left:(columnBox.left-host.left)+'px',top:(top.top-host.top-16)+'px',width:columnBox.width+'px'});
    this.rowHandle.title=this.rowHandle.ariaLabel=strings.row;this.columnHandle.title=this.columnHandle.ariaLabel=strings.column;
    this.rowHandle.hidden=this.columnHandle.hidden=false;
    Object.assign(this.row.style,{left:(top.left-host.left)+'px',top:(bottom.bottom-host.top+4)+'px',width:top.width+'px'});
    Object.assign(this.column.style,{left:(top.right-host.left+4)+'px',top:(top.top-host.top)+'px',height:(bottom.bottom-top.top)+'px'});
    this.row.hidden=this.column.hidden=false;
  }
  later() {clearTimeout(this.hideTimer);this.hideTimer=setTimeout(()=>this.hide(),250);}
  hide() {clearTimeout(this.hideTimer);this.row.hidden=this.column.hidden=this.rowHandle.hidden=this.columnHandle.hidden=this.menu.hidden=true;this.menuOpen=false;this.table=null;}
  update(update) {if(update.docChanged&&this.table!==null)this.hide();}
  destroy() {
    clearTimeout(this.hideTimer);this.row.remove();this.column.remove();this.rowHandle.remove();this.columnHandle.remove();this.menu.remove();
    this.view.dom.ownerDocument.removeEventListener('mousedown',this.outside,true);
    this.view.contentDOM.removeEventListener('mousemove',this.move);
    this.view.contentDOM.removeEventListener('mouseleave',this.leave);
    this.view.scrollDOM.removeEventListener('scroll',this.scroll);
  }
});
export const tableTest={appendColumn,deleteRow,deleteColumn,models};
