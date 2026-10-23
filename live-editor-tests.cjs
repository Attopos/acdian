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
