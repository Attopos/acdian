// Touch-only editor behaviour. The iOS app sets window.acdianTouch before this
// script runs; on the Mac the flag is absent and none of this is installed.
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { undo, redo } from '@codemirror/commands';
import { syntaxTree } from '@codemirror/language';
import { toggleFormat, setBlock } from './format-toolbar.js';
import { startComment } from './comments.js';

export const isTouch=()=>globalThis.acdianTouch===true;

// iOS turns "--" into an em dash as it is typed, which breaks the "--- " divider.
export function dashPrefixFix(line) {
  const match=/^[ \t]*([-–—]+)/.exec(line);
  if(!match||!/[–—]/.test(match[1]))return null;
  const from=match[0].length-match[1].length;
  return {from,to:match[0].length,insert:match[1].replace(/—/g,'--').replace(/–/g,'-')};
}
const straightQuotes=text=>text.replace(/[“”]/g,'"').replace(/[‘’]/g,"'");
function inCode(state,pos) {
  for(let node=syntaxTree(state).resolveInner(pos,-1);node;node=node.parent)if(['InlineCode','FencedCode','CodeBlock'].includes(node.name))return true;
  return false;
}
// An input method's own punctuation is left alone: only plain typing is corrected.
const smartPunctuation=EditorState.transactionFilter.of(tr=>{
  if(!tr.docChanged||!tr.isUserEvent('input.type')||tr.isUserEvent('input.type.compose'))return tr;
  const fixes=[];
  tr.changes.iterChanges((fromA,toA,fromB,toB,inserted)=>{
    const line=tr.newDoc.lineAt(fromB),fix=dashPrefixFix(line.text);
    if(fix&&!fixes.some(item=>item.from===line.from+fix.from))fixes.push({from:line.from+fix.from,to:line.from+fix.to,insert:fix.insert});
    const text=inserted.toString();
    if(/[“”‘’]/.test(text)&&inCode(tr.startState,fromA))fixes.push({from:fromB,to:toB,insert:straightQuotes(text)});
  });
  return fixes.length?[tr,{changes:fixes,sequential:true}]:tr;
});
export const composing=tr=>isTouch()&&tr.isUserEvent('input.type.compose');

// WebKit on iOS ends a composition by deleting the marked text and inserting the
// chosen word, but CodeMirror can keep the marked text (the pinyin) instead.
// When that happens the pinyin before the caret is swapped for the chosen word.
export function compositionFix(text,head,typed,chosen) {
  // An empty word means the composition was deleted, so the pinyin goes too.
  if(!typed||typed===chosen)return null;
  const from=head-typed.length;
  return from>=0&&text.slice(from,head)===typed?{from,to:head,insert:chosen}:null;
}
function composedWord() {
  let typed='';
  return EditorView.domEventHandlers({
    compositionstart(){typed='';return false;},
    compositionupdate(event){if(/[A-Za-z]/.test(event.data||''))typed=event.data;return false;},
    compositionend(event,view){
      const chosen=event.data||'',was=typed;typed='';
      setTimeout(()=>{
        const head=view.state.selection.main.head,fix=compositionFix(view.state.sliceDoc(Math.max(0,head-was.length),head),Math.min(head,was.length),was,chosen);
        if(fix)view.dispatch({changes:{from:head-was.length,to:head,insert:chosen},selection:{anchor:head-was.length+chosen.length},userEvent:'input.type'});
      },0);
      return false;
    }
  });
}

export function touchInput(post) {
  if(!isTouch())return [];
  return [
    smartPunctuation,composedWord(),
    // Shake to undo and the three-finger gestures reach CodeMirror's history.
    EditorView.domEventHandlers({beforeinput(event,view){
      if(event.inputType==='historyUndo'){event.preventDefault();undo(view);return true;}
      if(event.inputType==='historyRedo'){event.preventDefault();redo(view);return true;}
      return false;
    }}),
    EditorView.scrollMargins.of(()=>({top:24,bottom:56})),
    EditorView.updateListener.of(update=>{if(update.focusChanged)post({type:'focus',focused:update.view.hasFocus});})
  ];
}
const actions={
  bold:toggleFormat('bold'),italic:toggleFormat('italic'),strike:toggleFormat('strike'),code:toggleFormat('code'),
  h1:setBlock('h1',true),bullet:setBlock('bullet',true),todo:setBlock('todo',true),quote:setBlock('quote',true),comment:startComment,undo,redo
};
export function installTouchCommands(view) {
  if(!isTouch())return;
  globalThis.acdianFormat=name=>{const run=actions[name];if(run){run(view);view.focus();}};
  // The web view shrinks when the keyboard appears; the caret stays in sight.
  addEventListener('resize',()=>{if(view.hasFocus)view.dispatch({scrollIntoView:true});});
}
