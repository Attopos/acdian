import { StateEffect, StateField, Prec } from '@codemirror/state';
import { EditorView, keymap, showTooltip } from '@codemirror/view';
import { isolateHistory } from '@codemirror/commands';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { editorLanguage, uiMessages } from './ui-language.js';

const commands = [
  {id:'text',label:'Text',description:'文本',icon:'T',insert:'',aliases:'text paragraph plain 文本 正文 段落'},
  ...[1,2,3,4].map((level,index)=>({id:'h'+level,label:'Heading '+level,description:['一级标题','二级标题','三级标题','四级标题'][index],icon:'H'+level,insert:'#'.repeat(level)+' ',aliases:`heading ${level} h${level} 标题${level} ${['一级标题','二级标题','三级标题','四级标题'][index]}`})),
  {id:'quote',label:'Quote',description:'引用',icon:'❝',insert:'> ',aliases:'quote blockquote 引用'},
  {id:'todo',label:'Todo',description:'待办事项',icon:'☑',insert:'- [ ] ',aliases:'todo task checkbox 待办 任务 清单'},
  {id:'bullet',label:'Bulleted List',description:'无序列表',icon:'• ≡',insert:'- ',aliases:'bulleted bullet unordered list 无序列表 项目符号'},
  {id:'number',label:'Numbered List',description:'有序列表',icon:'1 ≡',insert:'1. ',aliases:'numbered number ordered list 有序列表 编号'},
  {id:'code',label:'Code Block',description:'代码块',icon:'{ }',insert:'```\n\n```',caret:4,aliases:'code block fenced 代码块'},
  {id:'callout',label:'Callout',description:'提示块',icon:'▣',insert:'> [!note]\n> ',aliases:'callout note info 提示块 提示 高亮块'}
];
export const blockCommands = commands;
const selectCommand = StateEffect.define();
const closeMenu = StateEffect.define();
const composing = StateEffect.define();
const spanishAliases={text:'texto párrafo parrafo',h1:'título 1 titulo 1 encabezado 1',h2:'título 2 titulo 2 encabezado 2',h3:'título 3 titulo 3 encabezado 3',h4:'título 4 titulo 4 encabezado 4',quote:'cita',todo:'tareas pendiente casilla',bullet:'lista con viñetas vinetas',number:'lista numerada',code:'bloque de código codigo',callout:'aviso nota consejo'};

function context(state) {
  const selection = state.selection.main;
  if(state.readOnly || state.selection.ranges.length !== 1 || !selection.empty) return null;
  const line = state.doc.lineAt(selection.head);
  const before = line.text.slice(0,selection.head-line.from);
  // A slash starts a block command, while paths and slashes in prose stay literal.
  const match = /^( {0,3})(?:(?:#{1,6}|>|[-+*]|\d+[.)]) (?:\[[ xX]\] )?)?\/([^/\n]*)$/.exec(before);
  if(!match || /^\s/.test(match[2])) return null;
  const tree = ensureSyntaxTree(state,selection.head,30) || syntaxTree(state);
  for(let node=tree.resolveInner(selection.head,-1);node;node=node.parent) {
    if(['FencedCode','CodeBlock','InlineCode','HTMLBlock','Link','Image','LinkDestination'].includes(node.name)) return null;
  }
  const query = match[2].trim().toLowerCase();
  const words = query.split(/\s+/).filter(Boolean);
  const labels=uiMessages(state).commands;
  const options = commands.map(command=>({...command,label:labels[command.id][0],description:labels[command.id][1]}))
    .filter(command=>words.every(word=>(command.label+' '+command.description+' '+command.aliases+' '+spanishAliases[command.id]).toLowerCase().includes(word)));
  return {from:line.from,to:selection.head,slash:line.from+before.indexOf('/'),indent:match[1],query,options};
}

const menuState = StateField.define({
  create:()=>({open:false,composing:false,selected:0}),
  update(value,tr) {
    let isComposing = value.composing;
    let compositionEnded = false;
    for(const effect of tr.effects) {
      if(effect.is(composing)) { isComposing=effect.value;compositionEnded=!effect.value; }
      if(effect.is(closeMenu)) return {open:false,composing:isComposing,selected:0};
    }
    const typed = tr.docChanged && !tr.isUserEvent('undo') && !tr.isUserEvent('redo');
    if(isComposing || tr.state.readOnly || (!value.open && !typed && !compositionEnded)) return {open:false,composing:isComposing,selected:0};
    const next = context(tr.state);
    if(!next) return {open:false,composing:isComposing,selected:0};
    let selected = value.open && value.query===next.query ? value.selected : 0;
    for(const effect of tr.effects) if(effect.is(selectCommand)) selected=effect.value;
    selected=Math.max(0,Math.min(selected,next.options.length-1));
    return {...next,open:true,composing:isComposing,selected};
  },
  provide:field=>[
    showTooltip.from(field,value=>value.open ? {
      pos:value.slash,above:false,strictSide:false,arrow:false,create:createTooltip
    } : null),
    EditorView.contentAttributes.from(field,value=>({
      'aria-haspopup':'listbox','aria-expanded':String(value.open),
      ...(value.open ? {'aria-controls':'acdian-slash-menu',
        ...(value.options[value.selected] ? {'aria-activedescendant':'acdian-slash-'+value.options[value.selected].id} : {})} : {})
    }))
  ]
});

function applyCommand(view,id) {
  const menu=view.state.field(menuState),command=menu.options?.find(option=>option.id===id);
  if(!menu.open || !command || view.state.readOnly) return false;
  const suffix=view.state.doc.lineAt(menu.to).text.slice(menu.to-view.state.doc.lineAt(menu.to).from);
  // Wrap existing text when changing a block to code or callout.
  let insert=command.insert;
  let to=menu.to;
  if(command.id==='code' && suffix) { insert='```\n'+suffix+'\n```';to+=suffix.length; }
  else if(command.id==='callout' && suffix) { insert+=suffix;to+=suffix.length; }
  insert=menu.indent+insert;
  const anchor=menu.from+menu.indent.length+(command.caret ?? command.insert.length);
  view.dispatch({
    changes:{from:menu.from,to,insert},selection:{anchor},
    effects:closeMenu.of(null),annotations:isolateHistory.of('full'),
    userEvent:'input.slash-command',scrollIntoView:true
  });
  view.focus();return true;
}

function createTooltip(view) {
  const dom=document.createElement('div');dom.className='cm-slash-menu';dom.id='acdian-slash-menu';
  dom.setAttribute('role','listbox');
  const title=document.createElement('div');title.className='cm-slash-title';
  const list=document.createElement('div');list.className='cm-slash-options';
  dom.append(title,list);
  let signature='',selected=-1;
  const render=()=>{
    const menu=view.state.field(menuState);
    if(!menu.open)return;
    const strings=uiMessages(view.state);
    title.textContent=strings.menuTitle;dom.setAttribute('aria-label',strings.menuTitle);
    const nextSignature=view.state.facet(editorLanguage)+'|'+menu.query+'|'+menu.options.map(option=>option.id).join(',');
    if(signature!==nextSignature){
      signature=nextSignature;list.replaceChildren();
      if(!menu.options.length){const empty=document.createElement('div');empty.className='cm-slash-empty';empty.textContent=strings.menuEmpty;list.append(empty);}
      for(const [index,command] of menu.options.entries()){
        const option=document.createElement('button');option.type='button';option.tabIndex=-1;option.className='cm-slash-option';option.dataset.command=command.id;
        option.setAttribute('role','option');option.id='acdian-slash-'+command.id;
        const icon=document.createElement('span');icon.className='cm-slash-icon';icon.textContent=command.icon;icon.setAttribute('aria-hidden','true');
        const label=document.createElement('span');label.className='cm-slash-label';label.textContent=command.label;
        option.append(icon,label);
        option.addEventListener('mousedown',event=>event.preventDefault());
        option.addEventListener('click',()=>applyCommand(view,command.id));
        option.addEventListener('mousemove',()=>{if(view.state.field(menuState).selected!==index)view.dispatch({effects:selectCommand.of(index)});});
        list.append(option);
      }
      selected=-1;
    }
    for(const [index,option] of [...list.querySelectorAll('[role="option"]')].entries()) option.setAttribute('aria-selected',String(index===menu.selected));
    const active=list.querySelector('[aria-selected="true"]');
    if(active)dom.setAttribute('aria-activedescendant',active.id);else dom.removeAttribute('aria-activedescendant');
    if(selected!==menu.selected && active){
      if(active.offsetTop<list.scrollTop)list.scrollTop=active.offsetTop;
      else if(active.offsetTop+active.offsetHeight>list.scrollTop+list.clientHeight)list.scrollTop=active.offsetTop+active.offsetHeight-list.clientHeight;
    }
    selected=menu.selected;
  };
  render();return {dom,update:render};
}

function moveSelection(view,delta) {
  const menu=view.state.field(menuState);
  if(!menu.open || !menu.options.length || view.composing) return false;
  view.dispatch({effects:selectCommand.of((menu.selected+delta+menu.options.length)%menu.options.length)});return true;
}
function accept(view) {
  const menu=view.state.field(menuState);
  if(view.composing || !menu.open || !menu.options.length) return false;
  return applyCommand(view,menu.options[menu.selected].id);
}

export function slashCommands() {return [
  menuState,
  Prec.highest(keymap.of([
    {key:'ArrowDown',run:view=>moveSelection(view,1)},
    {key:'ArrowUp',run:view=>moveSelection(view,-1)},
    {key:'Enter',run:accept},{key:'Tab',run:accept},
    {key:'Escape',run(view){if(!view.state.field(menuState).open)return false;view.dispatch({effects:closeMenu.of(null)});return true;}}
  ])),
  EditorView.domEventHandlers({
    blur(_event,view){if(view.state.field(menuState).open)view.dispatch({effects:closeMenu.of(null)});},
    compositionstart(_event,view){view.dispatch({effects:composing.of(true)});},
    compositionend(_event,view){view.dispatch({effects:composing.of(false)});}
  })
];}
