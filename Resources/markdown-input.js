import { EditorSelection, Prec } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';

// Block shortcuts typed at the start of a line, as in Feishu docs. They write
// ordinary Markdown, accepting the full-width punctuation Chinese input gives.
const listItem=/^([ \t]*)([-+*]|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?/;
const treeOf=state=>ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state);
function inCode(state,pos) {
  for(let node=treeOf(state).resolveInner(pos,-1);node;node=node.parent)if(['FencedCode','CodeBlock','InlineCode','HTMLBlock'].includes(node.name))return true;
  return false;
}
const spaceRules=[
  [/^([ \t]*)(?:[-+*][ \t]?)?(?:\[ ?\]|【 ?】)$/,match=>match[1]+'- [ ] '],
  [/^([ \t]*)(?:[-+*][ \t]?)?(?:\[[xX]\]|【[xX]】)$/,match=>match[1]+'- [x] '],
  [/^([ \t]*)[＊－＋×·・•]$/,match=>match[1]+'- '],
  [/^([ \t]*)(\d+)[。．]$/,match=>match[1]+match[2]+'. '],
  [/^([ \t]*)[》>]$/,match=>match[1]+'> '],
  [/^(＃{1,6})$/,match=>'#'.repeat(match[1].length)+' '],
  // A full-width space after an ASCII marker still starts the block.
  [/^([ \t]*(?:[-+*]|\d+[.)]|#{1,6}|>))$/,(match,typed)=>typed==='　'?match[1]+' ':null]
];
const spaceInput=EditorView.inputHandler.of((view,from,to,text)=>{
  if((text!==' '&&text!=='　')||from!==to||view.state.readOnly||view.composing)return false;
  const {state}=view,line=state.doc.lineAt(from),before=line.text.slice(0,from-line.from);
  if(inCode(state,from))return false;
  for(const [pattern,replace] of spaceRules) {
    const match=pattern.exec(before);if(!match)continue;
    const insert=replace(match,text);if(insert===null)return false;
    view.dispatch({changes:{from:line.from,to:from,insert},selection:EditorSelection.cursor(line.from+insert.length),userEvent:'input.type',scrollIntoView:true});
    return true;
  }
  return false;
});

// Enter after an opening fence closes the block, so the rest of the page is
// never swallowed by an unterminated code block.
function closeFence(view) {
  const {state}=view,range=state.selection.main;
  if(!range.empty||state.readOnly)return false;
  const line=state.doc.lineAt(range.head),match=/^( {0,3})(`{3,}|~{3,})([^`\s]*)[ \t]*$/.exec(line.text);
  if(!match||range.head!==line.to)return false;
  // Typing the closing fence by hand absorbs the one inserted automatically.
  const next=line.number<state.doc.lines?state.doc.line(line.number+1):null;
  if(next&&next.text===match[1]+match[2]&&!match[3]) {
    const block=fenceAt(state,line.from),orphan=fenceAt(state,next.from);
    if(block&&orphan&&block.from<line.from&&orphan.from===next.from&&!fenceClosed(state,orphan)) {
      view.dispatch({changes:{from:line.to,to:next.to,insert:'\n'},selection:EditorSelection.cursor(line.to+1),userEvent:'input',scrollIntoView:true});
      return true;
    }
  }
  const fence=fenceAt(state,line.from);
  if(!fence||state.doc.lineAt(fence.from).number!==line.number||fenceClosed(state,fence))return false;
  const insert='\n'+match[1]+'\n'+match[1]+match[2];
  view.dispatch({changes:{from:line.to,insert},selection:EditorSelection.cursor(line.to+1+match[1].length),userEvent:'input',scrollIntoView:true});
  return true;
}
function fenceAt(state,pos) {
  for(let node=treeOf(state).resolveInner(pos,1);node;node=node.parent)if(node.name==='FencedCode')return node;
  return null;
}
function fenceClosed(state,fence) {
  const last=fence.node.lastChild;
  return last?.name==='CodeMark'&&state.doc.lineAt(last.from).number>state.doc.lineAt(fence.from).number;
}
// Enter on an empty item leaves the list, or one nesting level of it.
function emptyItemEnter(view) {
  const {state}=view,range=state.selection.main;
  if(!range.empty||state.readOnly||state.selection.ranges.length!==1||inCode(state,range.head))return false;
  const line=state.doc.lineAt(range.head),match=listItem.exec(line.text);
  if(!match||line.text.slice(match[0].length).trim()||range.head<line.from+match[0].length)return false;
  if(match[1].length)return moveItem(view,true);
  view.dispatch({changes:{from:line.from,to:line.to},selection:EditorSelection.cursor(line.from),userEvent:'delete',scrollIntoView:true});
  return true;
}
// Backspace at the start of an item's text turns it into a paragraph.
function listBackspace(view) {
  const {state}=view,range=state.selection.main;
  if(!range.empty||state.readOnly||state.selection.ranges.length!==1||inCode(state,range.head))return false;
  const line=state.doc.lineAt(range.head),match=listItem.exec(line.text);
  if(!match||range.head!==line.from+match[0].length)return false;
  view.dispatch({changes:{from:line.from,to:range.head,insert:match[1]},selection:EditorSelection.cursor(line.from+match[1].length),userEvent:'delete.backward',scrollIntoView:true});
  return true;
}

// Tab nests an item under the previous one; Shift-Tab moves it back out.
// Numbered items restart at 1 when nested and continue their parent's count.
function itemAt(state,number) {
  if(number<1||number>state.doc.lines)return null;
  const line=state.doc.line(number),match=listItem.exec(line.text);
  return match?{line,indent:match[1].length,content:match[0].length-(match[6]?.length||0),ordered:match[3]!==undefined,number:Number(match[3]),delimiter:match[4],match}:null;
}
function previousItem(state,from,test) {
  for(let n=from-1;n>=1;n--) {
    const text=state.doc.line(n).text;
    if(!text.trim())continue;
    const item=itemAt(state,n);
    if(!item)return null;
    if(test(item))return item;
  }
  return null;
}
function moveItem(view,outdent) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly||inCode(state,range.head))return false;
  const first=state.doc.lineAt(range.from).number,last=state.doc.lineAt(range.to).number;
  const items=[];
  for(let n=first;n<=last;n++){const item=itemAt(state,n);if(!item)return false;items.push(item);}
  const changes=[];
  for(const item of items) {
    let indent,number=item.number;
    if(outdent) {
      const parent=previousItem(state,item.line.number,other=>other.indent<item.indent);
      if(!item.indent)continue;
      indent=parent?parent.indent:0;
      if(item.ordered){const sibling=previousItem(state,item.line.number,other=>other.indent<=indent);number=sibling&&sibling.indent===indent&&sibling.ordered?sibling.number+1:1;}
    } else {
      const sibling=previousItem(state,item.line.number,other=>other.indent<=item.indent);
      if(!sibling||sibling.indent!==item.indent)continue;
      indent=sibling.content;
      if(item.ordered){const child=previousItem(state,item.line.number,other=>other.indent<=indent);number=child&&child.indent===indent&&child.ordered?child.number+1:1;}
    }
    const marker=item.ordered?number+item.delimiter:item.match[2];
    changes.push({from:item.line.from,to:item.line.from+item.match[1].length+item.match[2].length,insert:' '.repeat(indent)+marker});
  }
  if(changes.length)view.dispatch({changes,userEvent:outdent?'delete.dedent':'input.indent',scrollIntoView:true});
  return true;
}

export function markdownInput() {return [
  spaceInput,
  Prec.highest(keymap.of([
    {key:'Enter',run:view=>closeFence(view)||emptyItemEnter(view)},
    {key:'Backspace',run:listBackspace},
    {key:'Tab',run:view=>moveItem(view,false)},
    {key:'Shift-Tab',run:view=>moveItem(view,true)}
  ]))
];}
