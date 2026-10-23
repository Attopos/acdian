import { EditorSelection, StateEffect, StateField, Prec } from '@codemirror/state';
import { EditorView, keymap, showTooltip, ViewPlugin } from '@codemirror/view';
import { isolateHistory } from '@codemirror/commands';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { editorLanguage, uiMessages } from './ui-language.js';
import { blockCommands } from './slash-commands.js';

// Selection formatting rewrites Markdown in place: every action stores plain
// Markdown syntax, so files stay readable in any other editor.
const formats={
  bold:{node:'StrongEmphasis',mark:'**'},
  strike:{node:'Strikethrough',mark:'~~'},
  italic:{node:'Emphasis',mark:'*'},
  code:{node:'InlineCode',mark:'`'},
  highlight:{mark:'=='}
};
const inlineNodes={StrongEmphasis:'bold',Strikethrough:'strike',Emphasis:'italic',InlineCode:'code'};
const blockPrefix=/^[ \t]*(?:#{1,6}(?:[ \t]+|$)|>[ \t]?(?:\[![\w-]+\][+-]?[ \t]*)?|(?:[-+*]|\d+[.)])(?:[ \t]+|$)(?:\[[ xX]\](?:[ \t]+|$))?)/;
const calloutHeader=/^[ \t]*>[ \t]?\[![\w-]+\][+-]?[ \t]*/;
const markdownLinks=/(!?)\[\[([^\]\n]+)\]\]|(!?)\[([^\]\n]+)\]\(([^)\n]+)\)/g;
const treeOf=state=>ensureSyntaxTree(state,state.doc.length,40)||syntaxTree(state);

function nodeAround(state,pos,names) {
  for(let node=treeOf(state).resolveInner(pos,1);node;node=node.parent)if(names.includes(node.name))return node;
  return null;
}
const lineInCode=(state,line)=>!!nodeAround(state,line.from+Math.min(line.length,1),['FencedCode','CodeBlock']);
const lineInTable=(state,line)=>!!nodeAround(state,line.from+Math.min(line.length,1),['Table']);
function mathLines(state) {
  const lines=new Set();
  for(let n=1;n<=state.doc.lines;n++) {
    if(!/^\s*\$\$\s*$/.test(state.doc.line(n).text))continue;
    let end=n+1;while(end<=state.doc.lines&&!/^\s*\$\$\s*$/.test(state.doc.line(end).text))end++;
    if(end>state.doc.lines)break;
    for(let row=n;row<=end;row++)lines.add(row);n=end;
  }
  return lines;
}
// Lines rendered as widgets, rules or code keep their source untouched.
function literalLine(state,line,math) {
  if(math.has(line.number)||lineInCode(state,line))return true;
  if(/^\s*(?:!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]+\))\s*$/.test(line.text))return true;
  let rule=false;
  treeOf(state).iterate({from:line.from,to:line.to,enter(node){if(node.name==='HorizontalRule'||node.name==='ThematicBreak')rule=true;}});
  return rule;
}

// Inline spans on one line: formatting nodes, ==highlights== and links.
function lineSpans(state,line) {
  const spans=[],code=[];
  treeOf(state).iterate({from:line.from,to:line.to,enter(node){
    const kind=inlineNodes[node.name];
    if(!kind||node.from<line.from||node.to>line.to)return;
    const first=node.node.firstChild,last=node.node.lastChild;
    if(!first||!last||first===last)return;
    spans.push({kind,from:node.from,to:node.to,bodyFrom:first.to,bodyTo:last.from});
    if(kind==='code')code.push([node.from,node.to]);
  }});
  const literal=pos=>code.some(([a,b])=>pos>=a&&pos<b);
  let match;const highlights=/==([^=\n]+)==/g;
  while((match=highlights.exec(line.text))) {
    const from=line.from+match.index,to=from+match[0].length;
    if(!literal(from))spans.push({kind:'highlight',from,to,bodyFrom:from+2,bodyTo:to-2});
  }
  markdownLinks.lastIndex=0;
  while((match=markdownLinks.exec(line.text))) {
    const from=line.from+match.index,to=from+match[0].length;
    if(match[1]||match[3]||literal(from))continue;
    if(match[2]!==undefined) {
      const bar=match[2].indexOf('|');
      spans.push({kind:'wiki',from,to,bodyFrom:bar<0?from+2:from+3+bar,bodyTo:to-2});
    } else spans.push({kind:'link',from,to,bodyFrom:from+1,bodyTo:from+1+match[4].length,url:match[5]});
  }
  return spans;
}

function cellRanges(line) {
  const ranges=[];let start=line.from;
  for(let index=0;index<line.text.length;index++) {
    if(line.text[index]!=='|')continue;
    let slashes=0;for(let at=index-1;at>=0&&line.text[at]==='\\';at--)slashes++;
    if(slashes%2)continue;
    ranges.push([start,line.from+index]);start=line.from+index+1;
  }
  ranges.push([start,line.to]);return ranges;
}
// The selection split into editable text runs, one per line or table cell.
function segments(state,from,to) {
  const result=[],math=mathLines(state);
  const first=state.doc.lineAt(from).number,last=state.doc.lineAt(to).number;
  for(let n=first;n<=last;n++) {
    const line=state.doc.line(n);
    if(n>first&&to===line.from)continue;
    if(literalLine(state,line,math))continue;
    const table=lineInTable(state,line);
    if(table&&/^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/.test(line.text))continue;
    const start=line.from+(table?0:(blockPrefix.exec(line.text)?.[0].length||0));
    for(const [cellFrom,cellTo] of table?cellRanges(line):[[start,line.to]]) {
      let a=Math.max(from,cellFrom),b=Math.min(to,cellTo);
      while(a<b&&/\s/.test(state.doc.sliceString(a,a+1)))a++;
      while(b>a&&/\s/.test(state.doc.sliceString(b-1,b)))b--;
      if(a>=b)continue;
      const spans=lineSpans(state,line);
      // A selection may not cut through other syntax; it grows to whole spans.
      for(let changed=true;changed;) {
        changed=false;
        for(const span of spans) {
          if(a>=span.to||b<=span.from||a<=span.from&&b>=span.to)continue;
          if(span.kind!=='code'&&a>=span.bodyFrom&&b<=span.bodyTo)continue;
          a=Math.min(a,span.from);b=Math.max(b,span.to);changed=true;
        }
      }
      result.push({line,from:a,to:b,spans});
    }
  }
  return result;
}

function markerPositions(spans) {
  const markers=new Set();
  for(const span of spans) {
    for(let pos=span.from;pos<span.bodyFrom;pos++)markers.add(pos);
    for(let pos=span.bodyTo;pos<span.to;pos++)markers.add(pos);
  }
  return markers;
}
function segmentActive(state,segment,kind) {
  const own=segment.spans.filter(span=>span.kind===kind),markers=markerPositions(own);
  const text=state.doc.sliceString(segment.from,segment.to);
  for(let pos=segment.from;pos<segment.to;pos++) {
    if(markers.has(pos)||/\s/.test(text[pos-segment.from]))continue;
    if(!own.some(span=>pos>=span.bodyFrom&&pos<span.bodyTo))return false;
  }
  return true;
}
export function formatActive(state,kind) {
  const range=state.selection.main;if(range.empty)return false;
  const list=segments(state,range.from,range.to);
  return list.length>0&&list.every(segment=>segmentActive(state,segment,kind));
}
function codeFence(text) {
  const longest=Math.max(0,...(text.match(/`+/g)||[]).map(run=>run.length));
  const fence='`'.repeat(longest+1),pad=/^`|`$/.test(text)?' ':'';
  return [fence+pad,pad+fence];
}
// Rewrites a segment and every touching span of the same kind, so adjacent
// or overlapping runs merge into one span and partial removal splits a span.
function rewrite(state,segment,kind,on) {
  const own=segment.spans.filter(span=>span.kind===kind&&span.to>=segment.from&&span.from<=segment.to);
  const strip=[...own];
  if(kind==='code'&&on)strip.push(...segment.spans.filter(span=>['bold','italic','strike','highlight'].includes(span.kind)&&span.from>=segment.from&&span.to<=segment.to));
  const from=Math.min(segment.from,...own.map(span=>span.from)),to=Math.max(segment.to,...own.map(span=>span.to));
  const markers=markerPositions(strip),chars=[];
  for(let pos=from;pos<to;pos++) {
    if(markers.has(pos))continue;
    const selected=pos>=segment.from&&pos<segment.to;
    chars.push({text:state.doc.sliceString(pos,pos+1),selected,on:selected?on:own.some(span=>pos>=span.bodyFrom&&pos<span.bodyTo)});
  }
  let insert='',selFrom=null,selTo=null;
  const emit=char=>{if(char.selected&&selFrom===null)selFrom=insert.length;insert+=char.text;if(char.selected)selTo=insert.length;};
  for(let index=0;index<chars.length;) {
    let end=index;while(end<chars.length&&chars[end].on===chars[index].on)end++;
    const run=chars.slice(index,end);index=end;
    if(!run[0].on){run.forEach(emit);continue;}
    let lead=0,trail=run.length;
    while(lead<trail&&/\s/.test(run[lead].text))lead++;
    while(trail>lead&&/\s/.test(run[trail-1].text))trail--;
    if(lead===trail){run.forEach(emit);continue;}
    const body=run.slice(lead,trail).map(char=>char.text).join('');
    const [open,close]=kind==='code'?codeFence(body):[formats[kind].mark,formats[kind].mark];
    run.slice(0,lead).forEach(emit);insert+=open;run.slice(lead,trail).forEach(emit);insert+=close;run.slice(trail).forEach(emit);
  }
  return {from,to,insert,selFrom:selFrom??0,selTo:selTo??insert.length};
}

const historyStep={annotations:isolateHistory.of('full'),scrollIntoView:true};
export function toggleFormat(kind) {
  return view=>{
    const {state}=view,range=state.selection.main;
    if(state.readOnly)return false;
    if(range.empty)return true;
    const list=segments(state,range.from,range.to);
    if(!list.length)return true;
    const on=!list.every(segment=>segmentActive(state,segment,kind));
    const edits=list.map(segment=>rewrite(state,segment,kind,on));
    const changes=state.changes(edits.map(({from,to,insert})=>({from,to,insert})));
    const first=edits[0],last=edits.at(-1);
    const anchor=changes.mapPos(first.from,-1)+first.selFrom,head=changes.mapPos(last.from,-1)+last.selTo;
    view.dispatch({changes,selection:EditorSelection.range(anchor,head),userEvent:'input.format',...historyStep});
    return true;
  };
}

// Links
function linkAt(state,from,to) {
  const line=state.doc.lineAt(from);
  if(to>line.to)return null;
  return lineSpans(state,line).find(span=>(span.kind==='link'||span.kind==='wiki')&&from<=span.to&&to>=span.from&&(from<span.to||to>span.from))||null;
}
const linkTarget=url=>url.trim().replace(/ /g,'%20').replace(/\(/g,'%28').replace(/\)/g,'%29');
function applyLink(view,url) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly)return false;
  const target=linkTarget(url),existing=linkAt(state,range.from,range.to);
  if(existing?.kind==='wiki')return false;
  if(existing) {
    const text=state.doc.sliceString(existing.bodyFrom,existing.bodyTo);
    const insert=target?`[${text}](${target})`:text,from=existing.from;
    view.dispatch({changes:{from,to:existing.to,insert},selection:EditorSelection.range(from+(target?1:0),from+(target?1:0)+text.length),userEvent:'input.format',...historyStep});
    return true;
  }
  const segment=segments(state,range.from,range.to)[0];
  if(!target||!segment)return false;
  const text=state.doc.sliceString(segment.from,segment.to);
  if(/[\[\]]/.test(text))return false;
  view.dispatch({changes:{from:segment.from,to:segment.to,insert:`[${text}](${target})`},selection:EditorSelection.range(segment.from+1,segment.from+1+text.length),userEvent:'input.format',...historyStep});
  return true;
}

// Block types reuse the slash menu's set of elements.
export function currentBlock(state,pos) {
  const line=state.doc.lineAt(pos);
  if(lineInCode(state,line))return 'code';
  if(/^[ \t]*>/.test(line.text)) {
    for(let n=line.number;n>=1&&/^[ \t]*>/.test(state.doc.line(n).text);n--)if(calloutHeader.test(state.doc.line(n).text))return 'callout';
    return 'quote';
  }
  const heading=/^ {0,3}(#{1,6})(?:[ \t]|$)/.exec(line.text);
  if(heading)return heading[1].length<=4?'h'+heading[1].length:null;
  if(/^[ \t]*[-+*][ \t]+\[[ xX]\]/.test(line.text))return 'todo';
  if(/^[ \t]*[-+*](?:[ \t]|$)/.test(line.text))return 'bullet';
  if(/^[ \t]*\d+[.)](?:[ \t]|$)/.test(line.text))return 'number';
  return 'text';
}
function blockLines(state) {
  const range=state.selection.main;
  const first=state.doc.lineAt(range.from);let last=state.doc.lineAt(range.to);
  if(!range.empty&&range.to===last.from&&last.number>first.number)last=state.doc.line(last.number-1);
  return {first,last};
}
function blockAllowed(state) {
  const {first,last}=blockLines(state),math=mathLines(state);
  for(let n=first.number;n<=last.number;n++) {
    const line=state.doc.line(n);
    if(lineInTable(state,line)||!lineInCode(state,line)&&literalLine(state,line,math))return false;
  }
  return true;
}
export function setBlock(id,toggle=false) {
  return view=>{
    const {state}=view;
    if(state.readOnly)return false;
    if(!blockAllowed(state))return true;
    let {first,last}=blockLines(state);
    const current=new Set();
    for(let n=first.number;n<=last.number;n++){const line=state.doc.line(n);if(line.text.trim()||first===last)current.add(currentBlock(state,line.from));}
    if(current.size===1&&current.has(id)){if(!toggle)return true;id='text';}
    // Lines of an enclosing code block are converted as a whole, fences included.
    const fences=new Set();
    for(const pos of [first.from,last.from]) {
      const fence=nodeAround(state,pos+Math.min(state.doc.lineAt(pos).length,1),['FencedCode']);
      if(fence){first=state.doc.lineAt(Math.min(first.from,fence.from));last=state.doc.lineAt(Math.max(last.from,fence.to));}
    }
    treeOf(state).iterate({from:first.from,to:last.to,enter(node){
      if(node.name!=='FencedCode')return;
      const open=state.doc.lineAt(node.from).number,close=state.doc.lineAt(node.to).number;
      fences.add(open);
      if(node.node.lastChild?.name==='CodeMark'&&close>open)fences.add(close);
      return false;
    }});
    const rows=[];
    for(let n=first.number;n<=last.number;n++) {
      const line=state.doc.line(n);
      if(fences.has(n))continue;
      if(lineInCode(state,line)){rows.push({line,indent:'',content:line.text,cut:0});continue;}
      let text=line.text,cut=0;const indent=/^[ \t]*/.exec(text)[0];
      const header=calloutHeader.exec(text);
      if(header&&!text.slice(header[0].length).trim()&&id!=='callout')continue;
      for(let match;(match=blockPrefix.exec(text))&&match[0].length;){cut+=match[0].length;text=text.slice(match[0].length);}
      rows.push({line,indent,content:text,cut});
    }
    const single=first.number===last.number||rows.length===1;
    let number=1;
    if(id==='number'&&first.number>1){const before=/^([ \t]*)(\d+)[.)][ \t]/.exec(state.doc.line(first.number-1).text);if(before&&before[1]===(rows[0]?.indent||''))number=Number(before[2])+1;}
    const prefixFor=row=>{
      if(!row.content.trim()&&!single&&id!=='code')return '';
      if(/^h[1-4]$/.test(id))return '#'.repeat(Number(id[1]))+' ';
      return {text:'',code:'',quote:'> ',callout:'> ',todo:row.indent+'- [ ] ',bullet:row.indent+'- ',number:row.indent+(number++)+'. '}[id];
    };
    let insert='';const starts=new Map();
    if(id==='code')insert+='```\n';
    if(id==='callout')insert+='> [!note]\n';
    rows.forEach((row,index)=>{
      if(index)insert+='\n';
      const prefix=prefixFor(row);insert+=prefix;
      starts.set(row.line.number,{at:insert.length,cut:row.cut});insert+=row.content;
    });
    if(id==='code')insert+='\n```';
    const map=pos=>{
      const line=state.doc.lineAt(pos),start=starts.get(line.number);
      if(start)return first.from+start.at+Math.max(0,pos-line.from-start.cut);
      const after=[...starts.entries()].find(([n])=>n>line.number);
      return first.from+(after?after[1].at:insert.length);
    };
    const range=state.selection.main;
    view.dispatch({changes:{from:first.from,to:last.to,insert},selection:EditorSelection.range(map(range.anchor),map(range.head)),userEvent:'input.format',...historyStep});
    return true;
  };
}

// Floating toolbar
const setPointer=StateEffect.define(),setFocus=StateEffect.define(),setMode=StateEffect.define(),dismiss=StateEffect.define();
function toolbarVisible(state,value) {
  const range=state.selection.main;
  if(state.readOnly||value.pointer||value.dismissed||!(value.focused||value.mode))return false;
  if(state.selection.ranges.length!==1||range.empty||!state.sliceDoc(range.from,range.to).trim())return false;
  return segments(state,range.from,range.to).length>0;
}
const toolbarState=StateField.define({
  create:()=>({pointer:false,focused:false,dismissed:false,mode:null,show:false,pos:0}),
  update(value,tr) {
    let next={...value};
    if(tr.selection||tr.docChanged){next.dismissed=false;next.mode=null;}
    for(const effect of tr.effects) {
      if(effect.is(setPointer))next.pointer=effect.value;
      if(effect.is(setFocus))next.focused=effect.value;
      if(effect.is(setMode))next.mode=effect.value;
      if(effect.is(dismiss)){next.dismissed=true;next.mode=null;}
    }
    next.show=toolbarVisible(tr.state,next);
    if(!next.show)next.mode=null;
    next.pos=tr.state.selection.main.from;
    return next;
  },
  provide:field=>showTooltip.from(field,value=>value.show?{pos:value.pos,above:true,strictSide:false,arrow:false,create:createToolbar}:null)
});

const svg=(paths,extra='')=>`<svg viewBox="0 0 20 20" aria-hidden="true"${extra}>${paths.map(d=>`<path d="${d}"/>`).join('')}</svg>`;
const icons={
  bold:svg(['M6 4h4.8a3 3 0 0 1 0 6H6z','M6 10h5.6a3 3 0 0 1 0 6H6z']),
  strike:svg(['M13.8 6.2C13.2 4.9 11.8 4 10 4 7.8 4 6.3 5.2 6.3 6.9c0 1 .5 1.7 1.4 2.2','M3.5 10.5h13','M13.4 12.6c.3.4.4.9.4 1.4 0 1.8-1.6 3-3.8 3-2 0-3.5-.9-4.1-2.4'],' class="cm-format-strike"'),
  italic:svg(['M8.5 4H15','M5 16h6.5','M11.8 4 8.2 16']),
  link:svg(['M8.6 11.4a3 3 0 0 0 4.2 0l2.5-2.5a3 3 0 0 0-4.2-4.2l-1 1','M11.4 8.6a3 3 0 0 0-4.2 0l-2.5 2.5a3 3 0 0 0 4.2 4.2l1-1']),
  code:svg(['M6.8 6 3 10l3.8 4','M13.2 6 17 10l-3.8 4','M11.4 4.5 8.6 15.5']),
  highlight:svg(['M5.8 15 10 4.5 14.2 15','M7.4 11h5.2']),
  chevron:svg(['M6 8.5l4 4 4-4'],' class="cm-format-chevron"')
};
const inlineButtons=[['bold','Mod-b'],['strike','Mod-Shift-x'],['italic','Mod-i'],['link','Mod-k'],['code','Mod-e'],['highlight',null]];
const shortcutLabel=key=>key?' '+key.replace('Mod-','⌘').replace('Shift-','⇧').replace('Alt-','⌥').toUpperCase():'';
const blockShortcuts={text:'Mod-Alt-0',h1:'Mod-Alt-1',h2:'Mod-Alt-2',h3:'Mod-Alt-3',h4:'Mod-Alt-4',quote:'Mod-Shift-.',todo:'Mod-Shift-9',bullet:'Mod-Shift-8',number:'Mod-Shift-7',code:'Mod-Alt-c'};

function openLink(view) {
  const {state}=view,range=state.selection.main;
  if(state.readOnly)return false;
  let selection=null;
  if(range.empty) {
    const link=linkAt(state,range.head,range.head);
    if(!link||link.kind==='wiki')return true;
    selection=EditorSelection.range(link.bodyFrom,link.bodyTo);
  }
  view.dispatch({...(selection?{selection}:{}),effects:setMode.of('link')});
  return true;
}
function createToolbar(view) {
  const dom=document.createElement('div');dom.className='cm-format-toolbar';dom.setAttribute('role','toolbar');
  const bar=document.createElement('div');bar.className='cm-format-buttons';
  const button=(className,html,run)=>{
    const element=document.createElement('button');element.type='button';element.tabIndex=-1;element.className='cm-format-button '+className;element.innerHTML=html;
    element.addEventListener('mousedown',event=>event.preventDefault());
    element.addEventListener('click',()=>run());
    return element;
  };
  const blockIcon=document.createElement('span');blockIcon.className='cm-format-block-icon';
  const blockButton=button('cm-format-block','',()=>view.dispatch({effects:setMode.of(view.state.field(toolbarState).mode==='block'?null:'block')}));
  blockButton.append(blockIcon);blockButton.insertAdjacentHTML('beforeend',icons.chevron);blockButton.setAttribute('aria-haspopup','menu');
  const separator=document.createElement('span');separator.className='cm-format-separator';
  bar.append(blockButton,separator);
  const inline=new Map();
  for(const [kind] of inlineButtons) {
    const element=button('cm-format-'+kind,icons[kind],()=>{if(kind==='link'){openLink(view);return;}toggleFormat(kind)(view);});
    inline.set(kind,element);bar.append(element);
  }
  const linkPanel=document.createElement('div');linkPanel.className='cm-format-link';
  const input=document.createElement('input');input.type='text';input.spellcheck=false;input.autocomplete='off';
  linkPanel.append(input);
  input.addEventListener('keydown',event=>{
    if(event.isComposing)return;
    if(event.key==='Enter'){event.preventDefault();applyLink(view,input.value);view.dispatch({effects:setMode.of(null)});view.focus();}
    else if(event.key==='Escape'){event.preventDefault();view.dispatch({effects:setMode.of(null)});view.focus();}
  });
  input.addEventListener('blur',()=>{if(view.state.field(toolbarState).mode==='link')view.dispatch({effects:setMode.of(null)});});
  const menu=document.createElement('div');menu.className='cm-format-menu';menu.setAttribute('role','menu');
  dom.append(bar,linkPanel,menu);
  let mode=null,language=null;
  const render=()=>{
    const {state}=view,value=state.field(toolbarState),strings=uiMessages(state);
    const range=state.selection.main,block=currentBlock(state,range.from),allowed=blockAllowed(state);
    dom.setAttribute('aria-label',strings.formatToolbar);
    blockButton.hidden=separator.hidden=!allowed;
    blockIcon.textContent=blockCommands.find(command=>command.id===block)?.icon||'T';
    blockButton.title=strings.turnInto;blockButton.setAttribute('aria-label',strings.turnInto);blockButton.setAttribute('aria-expanded',String(value.mode==='block'));
    const link=linkAt(state,range.from,range.to);
    for(const [kind,key] of inlineButtons) {
      const element=inline.get(kind),label=strings.format[kind];
      element.title=label+shortcutLabel(key);element.setAttribute('aria-label',label);
      element.setAttribute('aria-pressed',String(kind==='link'?!!link:formatActive(state,kind)));
      if(kind==='link')element.disabled=link?.kind==='wiki';
    }
    bar.hidden=value.mode==='link';linkPanel.hidden=value.mode!=='link';menu.hidden=value.mode!=='block';
    input.placeholder=strings.linkPlaceholder;input.setAttribute('aria-label',strings.format.link);
    if(value.mode==='link'&&mode!=='link'){input.value=link?.kind==='link'?link.url:'';requestAnimationFrame(()=>{input.focus();input.select();});}
    if(value.mode==='block'&&(mode!=='block'||language!==state.facet(editorLanguage))) {
      language=state.facet(editorLanguage);menu.replaceChildren();
      for(const command of blockCommands) {
        const option=document.createElement('button');option.type='button';option.tabIndex=-1;option.className='cm-format-option';option.setAttribute('role','menuitemradio');
        option.setAttribute('aria-checked',String(command.id===block));option.dataset.block=command.id;
        const icon=document.createElement('span');icon.className='cm-slash-icon';icon.textContent=command.icon;icon.setAttribute('aria-hidden','true');
        const label=document.createElement('span');label.className='cm-slash-label';label.textContent=strings.commands[command.id][0];
        option.title=strings.commands[command.id][0]+shortcutLabel(blockShortcuts[command.id]);
        option.append(icon,label);
        option.addEventListener('mousedown',event=>event.preventDefault());
        option.addEventListener('click',()=>{setBlock(command.id)(view);view.dispatch({effects:setMode.of(null)});});
        menu.append(option);
      }
    }
    mode=value.mode;
  };
  render();
  return {dom,update:render};
}

// Focus is mirrored into state after each update, since dispatching from a
// focus event could run inside an update CodeMirror is applying.
const focusTracker=ViewPlugin.fromClass(class {
  constructor(view) {
    this.view=view;
    this.up=()=>{if(view.state.field(toolbarState).pointer)view.dispatch({effects:setPointer.of(false)});};
    view.dom.ownerDocument.defaultView.addEventListener('mouseup',this.up);
    this.sync();
  }
  update(update){if(update.focusChanged)this.sync();}
  sync() {
    queueMicrotask(()=>{
      const view=this.view;
      if(this.destroyed||view.state.field(toolbarState).focused===view.hasFocus)return;
      view.dispatch({effects:setFocus.of(view.hasFocus)});
    });
  }
  destroy(){this.destroyed=true;this.view.dom.ownerDocument.defaultView.removeEventListener('mouseup',this.up);}
});

export function formatToolbar() {return [
  toolbarState,focusTracker,
  Prec.high(keymap.of([
    {key:'Mod-b',run:toggleFormat('bold')},
    {key:'Mod-i',run:toggleFormat('italic')},
    {key:'Mod-Shift-x',run:toggleFormat('strike')},
    {key:'Mod-e',run:toggleFormat('code')},
    {key:'Mod-k',run:openLink},
    ...Object.entries(blockShortcuts).map(([id,key])=>({key,run:setBlock(id,true)})),
    {key:'Escape',run(view){if(!view.state.field(toolbarState).show)return false;view.dispatch({effects:dismiss.of(null)});return true;}}
  ])),
  EditorView.domEventHandlers({
    mousedown(event,view){if(event.button===0)view.dispatch({effects:setPointer.of(true)});return false;}
  })
];}
export const formatToolbarTest={toggleFormat,setBlock,applyLink,openLink,formatActive,currentBlock};
