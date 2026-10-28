import { EditorState, EditorSelection } from '@codemirror/state';
import { Decoration } from '@codemirror/view';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';

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
  return {from:node.from,to:node.to,rows,separator,columns,alignment};
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
  // A selection is painted cell by cell: the editor's own selection boxes
  // cannot follow the cell layout, so table rows hide them (see the CSS).
  const selected=(from,to)=>state.selection.ranges.some(range=>!range.empty&&range.from<to&&range.to>from);
  for(const node of tableNodes(tree)) {
    const table=modelFor(state,node);if(!table)continue;
    for(const [index,row] of table.rows.entries()) {
      result.push(Decoration.line({class:'cm-table-row'+(row.header?' cm-table-header':'')+(index===0?' cm-table-first':'')+(index===table.rows.length-1?' cm-table-last':''),
        attributes:{style:`--table-columns:${table.columns}`}}).range(row.line.from));
      for(const cell of row.cells) {
        if(cell.markFrom<cell.rawTo)result.push(Decoration.mark({class:'cm-table-cell'+(selected(cell.markFrom,cell.rawTo)?' cm-table-cell-selected':''),inclusive:true,attributes:{
          // Keep DOM attributes stable while text changes. Position attributes
          // would force CM to split an active IME composition into multiple
          // styled cell spans as the cell's end offset grows.
          'data-table-cell':String(cell.index),
          style:`text-align:${table.alignment[cell.index]||'left'}`
        }}).range(cell.markFrom,cell.rawTo));
        hide(cell.rawFrom,cell.contentFrom);hide(cell.contentTo,cell.rawTo);
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
