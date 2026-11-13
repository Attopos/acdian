// npm install --no-save --no-package-lock jsdom@29.1.1
// node --test live-editor-tests.cjs
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.ACDIAN_TEST_NODE_MODULES?path.join(path.resolve(process.env.ACDIAN_TEST_NODE_MODULES),'jsdom'):'jsdom');
function setup(text='',currentPath='笔记.md'){
 const dom=new JSDOM('<!doctype html><html><body><main id="editor"></main></body></html>',{url:'file://'+path.join(__dirname,'Resources/live-editor.html'),runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,messages=[];w.webkit={messageHandlers:{acdian:{postMessage:m=>messages.push(m)}}};
 const style=w.document.createElement('style');style.textContent=fs.readFileSync(path.join(__dirname,'Resources/live-editor.css'),'utf8');w.document.head.append(style);
 w.ResizeObserver=class{observe(){}unobserve(){}disconnect(){}};
 w.Range.prototype.getClientRects=()=>[];w.Range.prototype.getBoundingClientRect=()=>({left:0,right:0,top:0,bottom:0,width:0,height:0});
 for(const file of ['vendor/marked.umd.js','vendor/purify.min.js','vendor/katex.min.js','vendor/live-editor.bundle.js'])w.eval(fs.readFileSync(path.join(__dirname,'Resources',file),'utf8'));
 w.acdianSetDocument({text,currentPath,title:'测试',editable:true});
 return{w,messages,view:w.acdianEditor,get:()=>w.acdianGetDocument(),close:()=>{w.acdianEditor.destroy();w.close();}};
}
test('initial source is byte faithful, including mixed newlines, and emits no changes',()=>{
 const source='---\r\ntags: [中文]\r\n---\n# 标题\r\n\r\n![[attachment/照片.png]]\r\n';const r=setup(source);
 assert.equal(r.get().text,source);assert.equal(r.messages.filter(m=>m.type==='change').length,0);
 const pos=r.w.acdianLiveEditorTest.canonical(source).indexOf('标题');r.view.dispatch({changes:{from:pos,to:pos,insert:'好'}});
 assert.equal(r.get().text,source.replace('标题','好标题'));r.w.acdianUndo();assert.equal(r.get().text,source);r.close();
});
test('native same-text echoes and metadata updates preserve selection, undo and exact edits',()=>{
 const r=setup('一行\r\n第二行\r\n');r.view.dispatch({selection:{anchor:2}});r.w.acdianInsertText(' 中文');
 const source=r.get().text,head=r.view.state.selection.main.head;
 assert.equal(source,'一行 中文\r\n第二行\r\n');
 r.w.acdianSetDocument({text:source,currentPath:'笔记.md',fontSize:18,editable:true});
 r.w.acdianSetDocument({fontSize:20,editable:true});assert.equal(r.view.state.selection.main.head,head);
 assert.equal(r.w.acdianUndo(),true);assert.equal(r.get().text,'一行\r\n第二行\r\n');
 assert.equal(r.w.acdianRedo(),true);assert.equal(r.get().text,source);r.close();
});
test('bold delimiters stay hidden while editing either Markdown delimiter style',()=>{
 const source='Before **bold** and __更多__.\r\n\r\nEnd\r\n',r=setup(source);
 assert.equal(r.w.document.querySelectorAll('.cm-live-bold-delimiter').length,4);
 r.view.dispatch({selection:{anchor:source.indexOf('bold')+2}});
 assert.equal(r.w.document.querySelectorAll('.cm-live-bold-delimiter').length,4);
 assert.deepEqual(Array.from(r.w.document.querySelectorAll('.cm-live-bold-delimiter'),node=>node.textContent),['**','**','__','__']);
 r.w.acdianInsertText('中文');assert.equal(r.get().text,source.replace('bold','bo中文ld'));
 assert.equal(r.w.document.querySelectorAll('.cm-live-bold-delimiter').length,4);
 r.w.acdianUndo();assert.equal(r.get().text,source);r.close();
});
test('bold delimiter parsing handles nesting and keeps code syntax literal',()=>{
 const source='***bold*** and **outer *inner***\n\n`**inline code**`\n\n```md\n__fenced code__\n```\n',r=setup(source);
 r.view.dispatch({selection:{anchor:5}});
 assert.equal(r.w.document.querySelectorAll('.cm-live-bold-delimiter').length,4);
 assert.equal(r.w.document.querySelectorAll('.cm-live-strong').length,2);
 assert.equal(r.get().text,source);r.close();
});
test('Backspace and Delete skip hidden bold markers, retain Unicode and remove empty pairs',()=>{
 const press=(r,key)=>{r.view.focus();r.view.contentDOM.dispatchEvent(new r.w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));};
 const source='A **中🌸** Z\r\n',r=setup(source);
 r.view.dispatch({selection:{anchor:'A **中🌸**'.length}});press(r,'Backspace');
 assert.equal(r.get().text,'A **中** Z\r\n');r.w.acdianUndo();assert.equal(r.get().text,source);
 r.view.dispatch({selection:{anchor:'A **'.length}});press(r,'Backspace');
 assert.equal(r.get().text,'A**中🌸** Z\r\n');r.w.acdianUndo();assert.equal(r.get().text,source);
 r.view.dispatch({selection:{anchor:'A **中🌸'.length}});press(r,'Delete');
 assert.equal(r.get().text,'A **中🌸**Z\r\n');r.w.acdianUndo();assert.equal(r.get().text,source);
 r.w.acdianSetDocument({text:'__中__',currentPath:'empty-bold.md'});
 r.view.dispatch({selection:{anchor:3}});press(r,'Backspace');assert.equal(r.get().text,'');
 r.w.acdianUndo();assert.equal(r.get().text,'__中__');r.close();
});
test('typing star-space immediately produces a bullet, Enter continues/exits, Backspace removes markup',()=>{
 const r=setup();r.w.acdianInsertText('* ');assert.equal(r.w.document.querySelector('.cm-list-bullet').textContent,'•');
 r.w.acdianInsertText('第一项');r.w.acdianLiveEditorTest.simpleListEnter(r.view);assert.equal(r.get().text,'* 第一项\n* ');
 r.w.acdianLiveEditorTest.simpleListEnter(r.view);assert.equal(r.get().text,'* 第一项\n');
 r.w.acdianInsertText('- ');r.w.acdianLiveEditorTest.simpleListBackspace(r.view);assert.equal(r.get().text,'* 第一项\n');r.close();
});
test('list lines carry a hanging indent that follows their indent and marker, without changing the source',()=>{
 const source='- 项目\n    - 嵌套\n100. 编号\n- [ ] 待办\n> - 引用\n',r=setup(source);
 const lines=[...r.w.document.querySelectorAll('.cm-line')],hang=line=>parseFloat(line.style.getPropertyValue('--cm-list-hang'));
 assert.deepEqual(lines.slice(0,4).map(line=>line.classList.contains('cm-list-line')),[true,true,true,true]);
 assert.equal(hang(lines[0]),1.25);assert.ok(hang(lines[1])>hang(lines[0]));assert.ok(hang(lines[2])>1.25);assert.equal(hang(lines[3]),1.55);
 assert.equal(lines[2].style.getPropertyValue('--cm-list-marker'),lines[2].style.getPropertyValue('--cm-list-hang'));
 assert.ok(lines[4].classList.contains('cm-quote-list-line'));assert.ok(hang(lines[4])>0);
 assert.equal(r.get().text,source);r.close();
});
test('typing three dashes and space immediately renders a divider without changing Markdown',()=>{
 const r=setup();for(const text of ['-','-','-',' '])r.w.acdianInsertText(text);
 assert.equal(r.get().text,'--- ');assert.equal(r.view.state.selection.main.head,4);
 assert.equal(r.w.document.querySelectorAll('.cm-live-divider hr').length,1);
 assert.equal(r.w.document.querySelectorAll('.cm-list-bullet').length,0);
 assert.equal(r.w.acdianLiveEditorTest.simpleListEnter(r.view),false);
 r.w.acdianInsertText('\n');assert.equal(r.get().text,'--- \n');assert.ok(r.w.document.querySelector('.cm-live-divider'));r.close();
});
test('divider rendering follows Markdown syntax and leaves setext headings and code literal',()=>{
 const source='Heading\n--- \n\n```md\n--- \n```\n\n    --- \n\n- ordinary item\n\n* * * \n\n> ___ \n';
 const r=setup(source);
 assert.equal(r.w.document.querySelectorAll('.cm-live-divider').length,2,r.w.acdianLiveEditorTest.treeString());
 assert.equal(r.w.document.querySelectorAll('.cm-list-bullet').length,1);
 assert.equal(r.get().text,source);r.close();
});
test('divider clicks and selections retain the rendered rule in editable and read-only documents',()=>{
 const source='--- \r\n\r\nEnd\r\n',r=setup(source);
 r.w.document.querySelector('.cm-live-divider').dispatchEvent(new r.w.MouseEvent('mousedown',{bubbles:true,cancelable:true}));
 assert.ok(r.w.document.querySelector('.cm-live-divider'));assert.equal(r.get().text,source);
 assert.equal(r.view.state.selection.main.head,4);
 r.w.acdianInsertText('edited');assert.equal(r.get().text,'--- edited\r\n\r\nEnd\r\n');
 r.w.acdianUndo();assert.equal(r.get().text,source);
 r.w.acdianSetDocument({editable:false});
 assert.ok(r.w.document.querySelector('.cm-live-divider'),'read-only toggle retains the same rendered rule');
 r.w.document.querySelector('.cm-live-divider').dispatchEvent(new r.w.MouseEvent('mousedown',{bubbles:true,cancelable:true}));
 assert.ok(r.w.document.querySelector('.cm-live-divider'));assert.equal(r.get().text,source);
 r.w.acdianSetDocument({editable:true});r.w.document.querySelector('.cm-live-divider').dispatchEvent(new r.w.MouseEvent('mousedown',{bubbles:true,cancelable:true}));
 assert.ok(r.w.document.querySelector('.cm-live-divider'));
 r.view.dispatch({selection:{anchor:0,head:4}});assert.ok(r.w.document.querySelector('.cm-live-divider'));
 r.view.dispatch({selection:{anchor:r.view.state.doc.length}});assert.ok(r.w.document.querySelector('.cm-live-divider'));r.close();
});
test('task widgets edit their underlying Markdown and source changes include document identity',()=>{
 const r=setup('- [ ] 任务\n');const checkbox=r.w.document.querySelector('.cm-task-widget input');assert.ok(checkbox);
 checkbox.checked=true;checkbox.dispatchEvent(new r.w.Event('change',{bubbles:true}));
 assert.equal(r.get().text,'- [x] 任务\n');assert.equal(r.messages.at(-1).currentPath,'笔记.md');r.close();
});
test('document switches isolate history and read-only insertion retries are idempotent',()=>{
 const r=setup('甲');r.w.acdianInsertText('改动','one');const edited=r.get().text;r.w.acdianInsertText('改动','one');assert.equal(r.get().text,edited);
 r.w.acdianSetDocument({text:'乙',currentPath:'乙.md'});assert.equal(r.w.acdianUndo(),false);assert.equal(r.get().text,'乙');
 r.w.acdianSetDocument({editable:false});assert.equal(r.w.acdianInsertText('不应写入','two'),false);assert.equal(r.get().text,'乙');
 r.w.acdianSetDocument({editable:true});assert.equal(r.w.acdianInsertText('可以写入','two'),true);assert.equal(r.get().text,'可以写入乙');r.close();
});
test('rich blocks stay rendered and literal code never becomes a widget',()=>{
 const r=setup('# 标题\n\n![[attachment/照片.png]]\n\n| 列 | 值 |\n| --- | --- |\n| A | B |\n\n> [!note] 提示\n> 内容\n\n```md\n![[literal.png]]\n[[literal link]]\n```\n\n`[[code link]]`\n\n[[目标|别名]]');
 assert.ok(r.w.document.querySelector('.cm-block-image img'));assert.ok(r.w.document.querySelector('.cm-table-row'),r.w.acdianLiveEditorTest.treeString()+'\n'+r.w.document.querySelector('.cm-content').innerHTML);assert.ok(r.w.document.querySelector('.cm-callout-line'));
 assert.equal(r.w.document.querySelectorAll('.cm-block-image').length,1);assert.equal(r.w.document.querySelectorAll('.cm-live-link').length,1);
 assert.ok(r.get().text.includes('![[literal.png]]'));r.close();
});
test('all complete formatting delimiters remain suppressed for carets and spanning selections',()=>{
 const source='# Heading\n\n*emphasis* ~~strike~~ `inline` ==highlight== [Label](https://example.com) [[Note|Alias]]\n\n> Quote\n\n> [!note] Title\n> Callout body\n\n```js\nconst literal = "**keep**";\n```\n',r=setup(source);
 const positions=[0,source.indexOf('Heading')+2,source.indexOf('emphasis')+2,source.indexOf('strike')+2,source.indexOf('inline')+2,source.indexOf('Label')+2,source.indexOf('Alias')+2,source.indexOf('Quote')+2,source.indexOf('Callout body')+3,source.indexOf('```')];
 const assertHidden=()=>{
  const markers=[...r.w.document.querySelectorAll('.cm-format-delimiter')];assert.ok(markers.length>=15,'formatting syntax remains represented by hidden native text');
  for(const marker of markers)assert.equal(r.w.getComputedStyle(marker).fontSize,'0px',marker.textContent);
  assert.equal(r.get().text,source);
  assert.ok(r.w.document.querySelector('.cm-callout-line'));assert.ok(r.w.document.querySelector('.cm-live-link'));
  const code=[...r.w.document.querySelectorAll('.cm-code-line')].find(line=>line.textContent.includes('const literal'));
  assert.ok(code);assert.equal(code.querySelector('.cm-format-delimiter'),null,'literal Markdown inside code is not formatting syntax');
 };
 for(const anchor of positions){r.view.dispatch({selection:{anchor}});assertHidden();}
 r.view.dispatch({selection:{anchor:0,head:r.view.state.doc.length}});assertHidden();
 assert.equal(r.messages.filter(message=>message.type==='change').length,0,'selection-only rendering never mutates saved Markdown');r.close();
});
test('active heading, emphasis, quote and callout Unicode edits preserve raw syntax and undo',()=>{
 const fixtures=[['## 标题🌸\r\n','标题',1],['*中文🌸*\r\n','中文',1],['> 引用🌸\r\n','引用',1],['> [!note] 标题\r\n> 内容🌸\r\n','内容',1]];
 for(const [source,word,offset] of fixtures){
  const r=setup(source),canonical=r.w.acdianLiveEditorTest.canonical(source),cursor=canonical.indexOf(word)+offset;
  r.view.dispatch({selection:{anchor:cursor}});r.w.acdianInsertText('新🌸');
  const rawPosition=source.indexOf(word)+offset;assert.equal(r.get().text,source.slice(0,rawPosition)+'新🌸'+source.slice(rawPosition));
  assert.ok([...r.w.document.querySelectorAll('.cm-format-delimiter')].every(marker=>r.w.getComputedStyle(marker).fontSize==='0px'));
  r.w.acdianUndo();assert.equal(r.get().text,source);r.w.acdianRedo();assert.equal(r.get().text,source.slice(0,rawPosition)+'新🌸'+source.slice(rawPosition));r.close();
 }
});
test('tab switches keep each tab’s text, selection, undo history and CRLF source',()=>{
 const r=setup();const tab=(id,documentID,text,currentPath)=>r.w.acdianSetDocument({tabID:id,documentID,text,currentPath,openTabs:['A','B']});
 tab('A','a1','第一页\r\n正文\r\n','甲.md');
 r.view.dispatch({selection:{anchor:3}});r.w.acdianInsertText('🌸');r.view.dispatch({selection:{anchor:1,head:4}});
 const edited=r.get().text;assert.equal(edited,'第一页🌸\r\n正文\r\n');
 tab('B','b1','乙','乙.md');assert.equal(r.get().text,'乙');assert.equal(r.w.acdianUndo(),false,'a new tab has its own empty history');
 r.w.acdianInsertText('改');
 tab('A','a2',edited,'甲.md');
 assert.equal(r.get().text,edited);assert.equal(r.get().documentID,'a2');assert.equal(r.get().revision,0);
 assert.deepEqual([r.get().selectionAnchor,r.get().selectionHead],[1,4],'selection comes back');
 assert.equal(r.w.acdianUndo(),true,'edits made before the switch can still be undone');assert.equal(r.get().text,'第一页\r\n正文\r\n');
 assert.equal(r.w.acdianRedo(),true);assert.equal(r.get().text,edited);
 tab('B','b2','改乙','乙.md');assert.equal(r.w.acdianUndo(),true);assert.equal(r.get().text,'乙');
 const changes=r.messages.filter(m=>m.type==='change');assert.ok(changes.every(m=>typeof m.documentID==='string'&&m.documentID));
 assert.equal(changes.at(-1).documentID,'b2','messages name the document they came from');r.close();
});
test('a tab starts fresh when its file changed, moved or became a new page, and closed tabs are forgotten',()=>{
 const r=setup();const tab=(id,documentID,text,currentPath,extra={})=>r.w.acdianSetDocument({tabID:id,documentID,text,currentPath,...extra});
 tab('A','a1','Alpha beta gamma','A.md');r.view.dispatch({selection:{anchor:6,head:10}});r.w.acdianInsertText('X');
 tab('B','b1','Other','B.md');
 tab('A','a2','Changed elsewhere and longer','A.md');
 assert.equal(r.get().text,'Changed elsewhere and longer');assert.equal(r.w.acdianUndo(),false,'disk text replaces the kept history');
 assert.deepEqual([r.get().selectionAnchor,r.get().selectionHead],[7,7],'the caret stays near where it was');
 tab('B','b2','Other','Moved/B.md');assert.equal(r.w.acdianUndo(),false,'a moved page starts a fresh editor state');
 tab('D','d1','','.acdian-draft-1.md');r.w.acdianInsertText('x');r.view.dispatch({changes:{from:0,to:1,insert:''}});
 tab('D','d2','','.acdian-draft-2.md');assert.equal(r.w.acdianUndo(),false,'a new page in a reused tab never inherits the old history');
 tab('C','c1','Gamma','C.md',{view:{anchor:2,head:4,scroll:{pos:3,offset:-2}}});
 assert.deepEqual([r.get().selectionAnchor,r.get().selectionHead],[2,4],'a remembered place is used when no editor state was kept');
 assert.deepEqual([r.get().scrollPosition,r.get().scrollOffset],[3,-2],'a place not yet laid out is still reported, e.g. while the window is covered');
 assert.deepEqual(Array.from(r.w.acdianLiveEditorTest.keptTabs()).sort(),['A','B','D']);
 r.w.acdianSetDocument({openTabs:['C','B']});assert.deepEqual(Array.from(r.w.acdianLiveEditorTest.keptTabs()),['B']);
 for(let n=0;n<20;n++)tab('T'+n,'t'+n,'Page '+n,`T${n}.md`);
 assert.ok(r.w.acdianLiveEditorTest.keptTabs().length<=12,'kept editor states are capped');r.close();
});
test('documents without a tab keep the earlier single-document behaviour',()=>{
 const r=setup('一');r.w.acdianInsertText('二');
 r.w.acdianSetDocument({text:'一',currentPath:'笔记.md'});assert.equal(r.get().text,'一');assert.equal(r.w.acdianUndo(),false);
 assert.deepEqual(Array.from(r.w.acdianLiveEditorTest.keptTabs()),[]);r.close();
});
test('the Image slash command clears its line and asks the app for an image, which goes in on lines of its own',()=>{
 const r=setup('- ');r.view.focus();r.view.dispatch({selection:{anchor:2}});
 for(const ch of '/图片')r.view.dispatch({changes:{from:r.view.state.selection.main.head,insert:ch},selection:{anchor:r.view.state.selection.main.head+ch.length},userEvent:'input.type'});
 const option=r.w.document.querySelector('.cm-slash-option[data-command="image"]');assert.ok(option,'image command is offered');
 option.click();
 assert.equal(r.get().text,'');assert.equal(r.view.state.selection.main.head,0);
 assert.equal(r.messages.filter(m=>m.type==='pickImage'&&m.currentPath==='笔记.md').length,1);
 r.w.acdianInsertText('![[Attachments/a.png]]','one',true);assert.equal(r.get().text,'![[Attachments/a.png]]\n');assert.equal(r.view.state.selection.main.head,r.view.state.doc.length);
 r.w.acdianSetDocument({text:'Hello World',currentPath:'笔记.md'});r.view.dispatch({selection:{anchor:6}});
 r.w.acdianInsertText('![[Attachments/a.png]]\n![[Attachments/b.png]]','two',true);
 assert.equal(r.get().text,'Hello \n![[Attachments/a.png]]\n![[Attachments/b.png]]\nWorld');
 r.w.acdianUndo();assert.equal(r.get().text,'Hello World');
 r.w.acdianSetDocument({text:'A\n\nB',currentPath:'笔记.md'});r.view.dispatch({selection:{anchor:4}});
 r.w.acdianInsertText('![[Attachments/c.png]]','three',true);assert.equal(r.get().text,'A\n\nB\n![[Attachments/c.png]]\n');r.close();
});
test('pastes that carry files go to the app, while plain text pastes stay in the editor',()=>{
 const r=setup('文字');r.view.focus();
 const paste=(types,files)=>{const event=new r.w.Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{types,files,getData:()=>'粘贴'}});r.view.contentDOM.dispatchEvent(event);return event;};
 const withFile=paste(['Files'],[{name:'image.png',type:'image/png'}]);
 assert.equal(withFile.defaultPrevented,true);assert.equal(r.messages.filter(m=>m.type==='paste').length,1);assert.equal(r.get().text,'文字');
 paste(['text/plain'],[]);assert.equal(r.messages.filter(m=>m.type==='paste').length,1);r.close();
});
const plain=value=>JSON.parse(JSON.stringify(value));
test('saved comments find their text again after other apps edit the page',()=>{
 const r=setup('x');const {anchorComment}=r.w.acdianLiveEditorTest.comments;
 const text='启动后检查。对应日期写入失败，应补预建和检查重试链路。';
 const at=text.indexOf('日期写入失败');
 const saved={from:at,to:at+6,quote:'日期写入失败',prefix:text.slice(at-8,at),suffix:text.slice(at+6,at+14)};
 assert.deepEqual(plain(anchorComment(text,saved)),{from:at,to:at+6},'unchanged offsets are kept');
 const shifted='新加的一行。\n'+text;
 assert.deepEqual(plain(anchorComment(shifted,saved)),{from:at+7,to:at+13},'text added above moves the comment with it');
 const twice='日期写入失败是常见问题。\n'+text;
 const second=twice.lastIndexOf('日期写入失败');
 assert.deepEqual(plain(anchorComment(twice,saved)),{from:second,to:second+6},'context picks the right one of two equal quotes');
 const edited=text.replace('日期写入失败','日期数据写入失败');
 const place=anchorComment(edited,{...saved,quote:'对应日期写入失败，应补',prefix:'启动后检查。',suffix:'预建和检查重试链路。',from:6,to:17});
 assert.ok(place&&edited.slice(place.from,place.to).includes('日期数据写入失败'),'a lightly edited quote is still found');
 assert.equal(anchorComment(text.replace('日期写入失败',''),{...saved,prefix:'',suffix:''}),null,'a deleted quote is not found');
 r.close();
});
test('comments move with edits, are deleted with their text, and come back on undo',async()=>{
 const text='第一段。\n\n这里是被评论的文字，后面还有。\n';
 const at=text.indexOf('被评论的文字');
 const saved=JSON.stringify({version:1,threads:[{id:'c1',from:at,to:at+6,quote:'被评论的文字',prefix:'',suffix:'',created:1,replies:[{id:'r1',text:'Commit 1',created:1},{id:'r2',text:'Commit 2',created:2}]},{id:'page',whole:true,created:1,replies:[{id:'r3',text:'整页',created:3}]}]});
 const r=setup('');r.w.acdianSetDocument({text,currentPath:'评论.md',documentID:'doc',tabID:'tab',comments:saved,editable:true});
 const {commentsField,serializeComments}=r.w.acdianLiveEditorTest.comments;
 const threads=()=>r.view.state.field(commentsField).threads;
 assert.deepEqual(plain(threads().map(t=>[t.id,r.view.state.sliceDoc(t.from,t.to),t.replies.length])),[['c1','被评论的文字',2],['page','',1]]);
 assert.equal(r.w.document.querySelectorAll('.cm-comment-mark').length,1);
 assert.equal(r.w.document.querySelectorAll('.cm-comment-card').length,2);
 r.view.dispatch({changes:{from:0,insert:'新的开头'},userEvent:'input.type'});
 assert.equal(r.view.state.sliceDoc(threads()[0].from,threads()[0].to),'被评论的文字','the comment moves with text typed above it');
 const from=r.view.state.doc.toString().indexOf('被评论的文字');
 r.view.dispatch({changes:{from:from-2,to:from+8},userEvent:'delete'});
 assert.deepEqual(plain(threads().map(t=>t.id)),['page'],'deleting the text deletes its comment');
 await new Promise(resolve=>setTimeout(resolve,10));
 const last=r.messages.filter(m=>m.type==='comments').at(-1);
 assert.equal(last.currentPath,'评论.md');assert.ok(!JSON.parse(last.data).threads.some(t=>t.id==='c1'),'the deletion is saved');
 r.w.acdianUndo();
 const back=threads().find(t=>t.id==='c1');
 assert.ok(back,'undo brings the comment back');assert.equal(r.view.state.sliceDoc(back.from,back.to),'被评论的文字');assert.equal(back.replies.length,2);
 const data=JSON.parse(serializeComments(r.view.state));
 assert.deepEqual(data.threads.map(t=>t.id).sort(),['c1','page']);
 assert.equal(data.threads.find(t=>t.id==='c1').quote,'被评论的文字');
 assert.equal(r.get().text,'新的开头'+text,'comments never change the page text');
 r.close();
});
test('a new comment is saved only once it has text, and can be edited',async()=>{
 const r=setup('');r.w.acdianSetDocument({text:'一段可以评论的文字。\n',currentPath:'新.md',documentID:'d',tabID:'t',editable:true,language:'zh-Hans'});
 const {commentsField,startComment}=r.w.acdianLiveEditorTest.comments;
 r.view.dispatch({selection:{anchor:2,head:7}});startComment(r.view);
 const thread=r.view.state.field(commentsField).threads[0];
 assert.equal(r.view.state.sliceDoc(thread.from,thread.to),'可以评论的');assert.equal(thread.replies.length,0);
 await new Promise(resolve=>setTimeout(resolve,10));
 assert.equal(r.messages.filter(m=>m.type==='comments').length,0,'an empty draft is not written');
 const input=r.w.document.querySelector('.cm-comment-card .cm-comment-input');
 input.value='第一条';input.dispatchEvent(new r.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
 input.value='第二条';input.dispatchEvent(new r.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
 assert.deepEqual(plain(r.view.state.field(commentsField).threads[0].replies.map(reply=>reply.text)),['第一条','第二条']);
 assert.equal(r.w.document.querySelectorAll('.cm-comment-reply').length,2);
 r.w.document.querySelector('.cm-comment-reply .cm-comment-text').dispatchEvent(new r.w.MouseEvent('dblclick',{bubbles:true}));
 const editor=r.w.document.querySelector('.cm-comment-editor');
 editor.value='改过的第一条';editor.dispatchEvent(new r.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
 const replies=r.view.state.field(commentsField).threads[0].replies;
 assert.equal(replies[0].text,'改过的第一条');assert.ok(replies[0].edited);
 await new Promise(resolve=>setTimeout(resolve,10));
 const saved=JSON.parse(r.messages.filter(m=>m.type==='comments').at(-1).data);
 assert.deepEqual(saved.threads[0].replies.map(reply=>reply.text),['改过的第一条','第二条']);
 assert.equal(r.view.state.doc.toString(),'一段可以评论的文字。\n');
 r.close();
});

test('a table typed row by row stays one table',()=>{
 const r=setup('| Name | Count |\n');const end=()=>r.view.state.doc.length;
 const type=text=>{for(const ch of text){const at=r.view.state.selection.main.head;r.view.dispatch({changes:{from:at,insert:ch},selection:{anchor:at+ch.length},userEvent:'input.type'});}};
 r.view.dispatch({selection:{anchor:end()}});type('| --- | --- |\n| Ink | 2 |');
 assert.equal(r.get().text,'| Name | Count |\n| --- | --- |\n| Ink | 2 |');r.close();
});
test('Command-Shift-H highlights the selection and takes the highlight off again',()=>{
 const source='Some words here.\n',r=setup(source),from=source.indexOf('words');
 const press=()=>{const mac=/Mac/.test(r.w.navigator.platform);r.view.contentDOM.dispatchEvent(new r.w.KeyboardEvent('keydown',{key:'H',code:'KeyH',keyCode:72,shiftKey:true,metaKey:mac,ctrlKey:!mac,bubbles:true,cancelable:true}));};
 r.view.focus();r.view.dispatch({selection:{anchor:from,head:from+5}});
 press();assert.equal(r.get().text,'Some ==words== here.\n');
 assert.ok(r.w.document.querySelector('.cm-live-highlight'),'the highlight is drawn');
 press();assert.equal(r.get().text,source);r.close();
});
test('the link button lights up on selected link text and a second click removes the link',async()=>{
 const source='Visit [ACdian](https://a.com) and [more](b.md) now\n',r=setup(source);
 r.view.focus();await new Promise(f=>setTimeout(f,5));
 const select=(from,to)=>r.view.dispatch({selection:{anchor:from,head:to}});
 const button=()=>r.w.document.querySelector('.cm-format-link');
 select(source.indexOf('ACdian'),source.indexOf('ACdian')+6);await new Promise(f=>setTimeout(f,5));
 assert.equal(button().getAttribute('aria-pressed'),'true');assert.equal(button().title.startsWith('Remove link'),true);
 button().click();
 assert.equal(r.get().text,'Visit ACdian and [more](b.md) now\n');
 const range=r.view.state.selection.main;assert.equal(r.view.state.sliceDoc(range.from,range.to),'ACdian');
 await new Promise(f=>setTimeout(f,5));assert.equal(button().getAttribute('aria-pressed'),'false');
 r.w.acdianUndo();assert.equal(r.get().text,source);
 select(0,source.indexOf(' now'));await new Promise(f=>setTimeout(f,5));
 assert.equal(button().getAttribute('aria-pressed'),'true');button().click();
 assert.equal(r.get().text,'Visit ACdian and more now\n');
 assert.equal(r.view.state.sliceDoc(r.view.state.selection.main.from,r.view.state.selection.main.to),'Visit ACdian and more');
 select(0,5);await new Promise(f=>setTimeout(f,5));
 assert.equal(button().getAttribute('aria-pressed'),'false');r.close();
});
test('a link spanning a line break of the selection still lights the button',async()=>{
 const source='First line\nsee [here](https://a.com)\n',r=setup(source);
 r.view.focus();await new Promise(f=>setTimeout(f,5));
 r.view.dispatch({selection:{anchor:0,head:source.indexOf('here')+4}});await new Promise(f=>setTimeout(f,5));
 assert.equal(r.w.document.querySelector('.cm-format-link').getAttribute('aria-pressed'),'true');
 r.w.document.querySelector('.cm-format-link').click();
 assert.equal(r.get().text,'First line\nsee here\n');r.close();
});
