import { Facet } from '@codemirror/state';

export const normalizeLanguage=value=>value==='es'?'es':value==='zh-Hans'||value==='zh'?'zh-Hans':'en';
export const editorLanguage=Facet.define({combine:values=>normalizeLanguage(values.at(-1))});
const translations={
  en:{
    placeholder:'Start typing…',editorLabel:'Markdown editor',completeTask:'Complete task',
    openLink:'Click to open link',openLinkShort:'Click to open',divider:'Divider',interactive:'Interactive',rerun:'Run again',editSource:'Edit source',copy:'Copy',copied:'Copied',doubleClickEdit:'Double-click to edit',imageMissing:'Image not found: ',calloutIcon:'Change icon and colour',copyImage:'Copy image',revealImage:'Show in Finder',viewImage:'View large',deleteImage:'Delete',toc:'Contents',tocEmpty:'Headings on this page will be listed here.',
    formatToolbar:'Text formatting',turnInto:'Turn into',linkPlaceholder:'Paste or type a link',format:{bold:'Bold',strike:'Strikethrough',italic:'Italic',link:'Link',code:'Inline code',highlight:'Highlight',color:'Colour',textColor:'Text colour',backColor:'Background',clearColor:'Clear colours',comment:'Comment'},
    comments:{title:'Comments (%d)',collapse:'Hide comments',expand:'Show comments',placeholder:'Add a comment…',reply:'Reply…',page:'Page comment',resolve:'Resolve',reopen:'Reopen',deleteThread:'Delete comment',deleteReply:'Delete',edit:'Edit',edited:'(edited)',justNow:'Just now',show:'Show comment',showSolved:'Show resolved (%d)',hideSolved:'Hide resolved (%d)'},
    menuTitle:'Insert block',menuFooter:'↑ ↓ Choose   ↵ Insert   esc Close',menuEmpty:'No matching blocks',
    commands:{text:['Text','Paragraph'],h1:['Heading 1','Large heading'],h2:['Heading 2','Medium heading'],h3:['Heading 3','Small heading'],h4:['Heading 4','Subheading'],quote:['Quote','Quotation'],todo:['Todo','Task'],bullet:['Bulleted List','Unordered list'],number:['Numbered List','Ordered list'],code:['Code Block','Code snippet'],callout:['Callout','Note or tip'],image:['Image','Picture from a file'],toc:['Contents','List of headings']}
  },
  es:{
    placeholder:'Empieza a escribir…',editorLabel:'Editor de Markdown',completeTask:'Completar tarea',
    openLink:'Clic para abrir el enlace',openLinkShort:'Clic para abrir',divider:'Separador',interactive:'Interactivo',rerun:'Volver a ejecutar',editSource:'Editar código',copy:'Copiar',copied:'Copiado',doubleClickEdit:'Doble clic para editar',imageMissing:'No se encuentra la imagen: ',calloutIcon:'Cambiar icono y color',copyImage:'Copiar imagen',revealImage:'Mostrar en Finder',viewImage:'Ver en grande',deleteImage:'Eliminar',toc:'Contenido',tocEmpty:'Aquí aparecerán los títulos de esta página.',
    formatToolbar:'Formato de texto',turnInto:'Convertir en',linkPlaceholder:'Pega o escribe un enlace',format:{bold:'Negrita',strike:'Tachado',italic:'Cursiva',link:'Enlace',code:'Código en línea',highlight:'Resaltado',color:'Color',textColor:'Color del texto',backColor:'Fondo',clearColor:'Quitar colores',comment:'Comentar'},
    comments:{title:'Comentarios (%d)',collapse:'Ocultar comentarios',expand:'Mostrar comentarios',placeholder:'Añade un comentario…',reply:'Responder…',page:'Comentario de la página',resolve:'Resolver',reopen:'Reabrir',deleteThread:'Eliminar comentario',deleteReply:'Eliminar',edit:'Editar',edited:'(editado)',justNow:'Ahora mismo',show:'Ver comentario',showSolved:'Ver resueltos (%d)',hideSolved:'Ocultar resueltos (%d)'},
    menuTitle:'Insertar elemento',menuFooter:'↑ ↓ Elegir   ↵ Insertar   esc Cerrar',menuEmpty:'No hay elementos coincidentes',
    commands:{text:['Texto','Párrafo'],h1:['Título 1','Título grande'],h2:['Título 2','Título mediano'],h3:['Título 3','Título pequeño'],h4:['Título 4','Subtítulo'],quote:['Cita','Texto citado'],todo:['Tareas','Tarea pendiente'],bullet:['Lista con viñetas','Sin numeración'],number:['Lista numerada','Con numeración'],code:['Bloque de código','Código'],callout:['Aviso','Nota o consejo'],image:['Imagen','Imagen de un archivo'],toc:['Contenido','Lista de títulos']}
  },
  'zh-Hans':{
    placeholder:'开始输入…',editorLabel:'Markdown 实时编辑器',completeTask:'完成任务',
    openLink:'点击打开链接',openLinkShort:'点击打开',divider:'分割线',interactive:'交互演示',rerun:'重新运行',editSource:'编辑源码',copy:'复制',copied:'已复制',doubleClickEdit:'双击编辑',imageMissing:'找不到图片：',calloutIcon:'更换图标和颜色',copyImage:'复制图片',revealImage:'在 Finder 中显示',viewImage:'放大查看',deleteImage:'删除',toc:'目录',tocEmpty:'这一页的标题会列在这里。',
    formatToolbar:'文本格式',turnInto:'转换为',linkPlaceholder:'粘贴或输入链接',format:{bold:'加粗',strike:'删除线',italic:'斜体',link:'链接',code:'行内代码',highlight:'高亮',color:'颜色',textColor:'文字颜色',backColor:'背景颜色',clearColor:'清除颜色',comment:'评论'},
    comments:{title:'评论（%d）',collapse:'收起评论栏',expand:'展开评论栏',placeholder:'添加评论…',reply:'回复…',page:'页面评论',resolve:'解决',reopen:'重新打开',deleteThread:'删除评论',deleteReply:'删除',edit:'编辑',edited:'（已编辑）',justNow:'刚刚',show:'查看评论',showSolved:'显示已解决（%d）',hideSolved:'隐藏已解决（%d）'},
    menuTitle:'插入元素',menuFooter:'↑ ↓ 选择   ↵ 插入   esc 关闭',menuEmpty:'没有匹配的元素',
    commands:{text:['文本','正文段落'],h1:['一级标题','大标题'],h2:['二级标题','中标题'],h3:['三级标题','小标题'],h4:['四级标题','子标题'],quote:['引用','引用内容'],todo:['待办事项','任务清单'],bullet:['无序列表','项目符号'],number:['有序列表','编号列表'],code:['代码块','代码片段'],callout:['提示块','笔记或提示'],image:['图片','从文件插入图片'],toc:['目录','列出本页标题']}
  }
};
export const messagesForLanguage=language=>translations[normalizeLanguage(language)];
export const uiMessages=state=>messagesForLanguage(state.facet(editorLanguage));
export const uiText=(state,key)=>uiMessages(state)[key];
