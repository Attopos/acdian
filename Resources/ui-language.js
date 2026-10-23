import { Facet } from '@codemirror/state';

export const normalizeLanguage=value=>value==='es'?'es':value==='zh-Hans'||value==='zh'?'zh-Hans':'en';
export const editorLanguage=Facet.define({combine:values=>normalizeLanguage(values.at(-1))});
const translations={
  en:{
    placeholder:'Start typing…',editorLabel:'Markdown editor',completeTask:'Complete task',
    openLink:'⌘ Click to open link',openLinkShort:'⌘ Click to open',divider:'Divider',
    formatToolbar:'Text formatting',turnInto:'Turn into',linkPlaceholder:'Paste or type a link',format:{bold:'Bold',strike:'Strikethrough',italic:'Italic',link:'Link',code:'Inline code',highlight:'Highlight'},
    menuTitle:'Insert block',menuFooter:'↑ ↓ Choose   ↵ Insert   esc Close',menuEmpty:'No matching blocks',
    commands:{text:['Text','Paragraph'],h1:['Heading 1','Large heading'],h2:['Heading 2','Medium heading'],h3:['Heading 3','Small heading'],h4:['Heading 4','Subheading'],quote:['Quote','Quotation'],todo:['Todo','Task'],bullet:['Bulleted List','Unordered list'],number:['Numbered List','Ordered list'],code:['Code Block','Code snippet'],callout:['Callout','Note or tip']}
  },
  es:{
    placeholder:'Empieza a escribir…',editorLabel:'Editor de Markdown',completeTask:'Completar tarea',
    openLink:'⌘ Clic para abrir el enlace',openLinkShort:'⌘ Clic para abrir',divider:'Separador',
    formatToolbar:'Formato de texto',turnInto:'Convertir en',linkPlaceholder:'Pega o escribe un enlace',format:{bold:'Negrita',strike:'Tachado',italic:'Cursiva',link:'Enlace',code:'Código en línea',highlight:'Resaltado'},
    menuTitle:'Insertar elemento',menuFooter:'↑ ↓ Elegir   ↵ Insertar   esc Cerrar',menuEmpty:'No hay elementos coincidentes',
    commands:{text:['Texto','Párrafo'],h1:['Título 1','Título grande'],h2:['Título 2','Título mediano'],h3:['Título 3','Título pequeño'],h4:['Título 4','Subtítulo'],quote:['Cita','Texto citado'],todo:['Tareas','Tarea pendiente'],bullet:['Lista con viñetas','Sin numeración'],number:['Lista numerada','Con numeración'],code:['Bloque de código','Código'],callout:['Aviso','Nota o consejo']}
  },
  'zh-Hans':{
    placeholder:'开始输入…',editorLabel:'Markdown 实时编辑器',completeTask:'完成任务',
    openLink:'⌘ 点击打开链接',openLinkShort:'⌘ 点击打开',divider:'分割线',
    formatToolbar:'文本格式',turnInto:'转换为',linkPlaceholder:'粘贴或输入链接',format:{bold:'加粗',strike:'删除线',italic:'斜体',link:'链接',code:'行内代码',highlight:'高亮'},
    menuTitle:'插入元素',menuFooter:'↑ ↓ 选择   ↵ 插入   esc 关闭',menuEmpty:'没有匹配的元素',
    commands:{text:['文本','正文段落'],h1:['一级标题','大标题'],h2:['二级标题','中标题'],h3:['三级标题','小标题'],h4:['四级标题','子标题'],quote:['引用','引用内容'],todo:['待办事项','任务清单'],bullet:['无序列表','项目符号'],number:['有序列表','编号列表'],code:['代码块','代码片段'],callout:['提示块','笔记或提示']}
  }
};
export const messagesForLanguage=language=>translations[normalizeLanguage(language)];
export const uiMessages=state=>messagesForLanguage(state.facet(editorLanguage));
export const uiText=(state,key)=>uiMessages(state)[key];
