// From the source folder: npm install --no-save --no-package-lock jsdom
// Then run: node --test renderer-tests.cjs
// Or set ACDIAN_TEST_NODE_MODULES to an existing node_modules directory.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require(process.env.ACDIAN_TEST_NODE_MODULES
  ? path.join(path.resolve(process.env.ACDIAN_TEST_NODE_MODULES), 'jsdom')
  : 'jsdom');

function reader() {
  const resources = path.join(__dirname, 'Resources');
  const dom = new JSDOM('<!doctype html><html><body><article id="content"></article></body></html>', {
    url: 'file://' + path.join(resources, 'renderer.html'), runScripts: 'outside-only', pretendToBeVisual: true
  });
  const messages = [];
  const { window } = dom;
  window.webkit = { messageHandlers: { acdian: { postMessage: value => messages.push(value) } } };
  window.scrollTo = () => {};
  window.HTMLElement.prototype.scrollIntoView = function() { window.lastScrolled = this; };
  for (const name of ['vendor/marked.umd.js', 'vendor/purify.min.js', 'vendor/katex.min.js', 'renderer.js']) {
    window.eval(fs.readFileSync(path.join(resources, name), 'utf8'));
  }
  const render = (text, extra = {}) => window.acdianRender({ text, currentPath: '日记/今天.md', ...extra });
  return { window, document: window.document, messages, render, close: () => window.close() };
}

test('renders real GFM and Obsidian markup, keeping fenced code literal', () => {
  const r = reader();
  r.render(`---
tags: [阅读, 生活]
created: 2026-10-22
---
# 我的笔记

中文段落包含 **粗体**、==重点==、~~删除~~，以及 [[项目/灵感#下一步|一个想法]]。

| 事项 | 状态 |
| --- | --- |
| acdian | 完成 |

- [x] 阅读笔记
- [ ] 再写一点

> [!tip] 一点提示
> 保持好奇心。

> [!note]- 折叠内容
> 可以展开。



\`\`\`javascript
const text = "==not highlight== [[not link]]";
\`\`\`

这是一个脚注[^one]。

[^one]: 脚注内容包含 **强调**。

行内公式 $E=mc^2$。

$$
\\int_0^1 x^2 \\, dx = \\frac{1}{3}
$$
`);
  const d = r.document;
  assert.equal(d.querySelector('h1').textContent, '我的笔记');
  assert.equal(d.querySelectorAll('table tbody tr').length, 1);
  assert.equal(d.querySelector('mark').textContent, '重点');
  assert.equal(d.querySelectorAll('input[type="checkbox"]').length, 2);
  assert.ok(d.querySelector('input[type="checkbox"]').disabled);
  assert.equal(d.querySelector('[data-acdian-target]').dataset.acdianTarget, '项目/灵感#下一步');
  assert.equal(d.querySelector('.callout[data-callout="tip"] .callout-body').textContent.trim(), '保持好奇心。');
  assert.equal(d.querySelector('details.callout').open, false);
  assert.equal(d.querySelector('pre code').textContent.trim(), 'const text = "==not highlight== [[not link]]";');
  assert.equal(d.querySelectorAll('.katex').length, 2);
  assert.equal(d.querySelector('.footnotes strong').textContent, '强调');
  assert.equal(d.querySelectorAll('.properties dt').length, 2);
  assert.equal(r.window.acdianScrollTo('我的笔记'), true);
  assert.equal(r.window.acdianScrollTo('fn-1'), true);
  r.close();
});

test('resolves wiki and Markdown images with spaces and Unicode against the current note', () => {
  const r = reader();
  r.render('先看这张图： ![[attachment/我的 图片.png|320]]\n\n![照片](<../attachment/旅行 图片.jpg>)\n\n![[attachment/手册.pdf#page=2]]');
  const images = [...r.document.querySelectorAll('img')];
  assert.equal(images.length, 2);
  const first = new URL(images[0].src);
  assert.equal(first.protocol, 'acdian-resource:');
  assert.equal(decodeURIComponent(first.pathname.slice(1)), 'attachment/我的 图片.png');
  assert.equal(first.searchParams.get('from'), '日记/今天.md');
  assert.equal(images[0].getAttribute('width'), '320');
  assert.equal(decodeURIComponent(new URL(images[1].src).pathname.slice(1)), '../attachment/旅行 图片.jpg');
  assert.equal(r.document.querySelectorAll('iframe,.pdf-frame').length, 0);
  assert.equal(r.document.querySelector('.pdf-badge').textContent, 'PDF');
  assert.equal(r.document.querySelector('.pdf-header').dataset.acdianTarget, 'attachment/手册.pdf#page=2');
  r.document.querySelector('.pdf-header').click();
  assert.equal(r.messages.at(-1).type, 'navigate');
  assert.equal(r.messages.at(-1).target, 'attachment/手册.pdf#page=2');
  r.close();
});

test('native navigation separates external, local, and heading targets', () => {
  const r = reader();
  r.render('# 标题 一\n\n[[笔记/下一篇|继续阅读]] [官网](https://example.com) [本页](#标题%20一)');
  r.document.querySelector('[data-acdian-target]').click();
  assert.equal(r.messages.at(-1).target, '笔记/下一篇');
  assert.equal(r.messages.at(-1).from, '日记/今天.md');
  r.document.querySelector('a[href="https://example.com"]').click();
  assert.equal(r.messages.at(-1).type, 'external');
  assert.equal(r.messages.at(-1).target, 'https://example.com');
  r.document.querySelector('a[href="#标题%20一"]').click();
  assert.equal(r.window.lastScrolled.textContent, '标题 一');
  r.close();
});

test('note HTML cannot execute code, access local files, or insert active frames', () => {
  const r = reader();
  r.render(`<script>window.pwned = true</script>
<img src="missing.png" onerror="window.pwned=true">
<img src="file:///etc/passwd">
<img src="data:text/html;base64,PHNjcmlwdD4=">
<iframe src="https://evil.example"></iframe>
<object data="file:///etc/passwd"></object>
<form><input autofocus onfocus="window.pwned=true"></form>
<p style="background:url(https://evil.example)">safe paragraph</p>
<svg><a xlink:href="javascript:alert(1)">bad</a></svg>

[unsafe](javascript:alert(1))
[[javascript:alert(1)|malicious wiki link]]
`);
  assert.equal(r.window.pwned, undefined);
  assert.equal(r.document.querySelectorAll('script,iframe,object,svg,form').length, 0);
  assert.equal(r.document.querySelectorAll('[onerror],[onfocus],[style]').length, 0);
  assert.equal(r.document.querySelectorAll('img[src^="file:"],img[src^="data:text"]').length, 0);
  const count = r.messages.length;
  r.document.querySelector('[data-acdian-target="javascript:alert(1)"]').click();
  assert.equal(r.messages.length, count);
  assert.equal(r.window.acdianReader.resourceURL('javascript:alert(1)'), '');
  assert.equal(r.window.acdianReader.resourceURL('file:///etc/passwd'), '');
  assert.equal(r.window.acdianReader.resourceURL('data:text/html;base64,xxxx'), '');
  r.close();
});

test('consecutive renders clear per-note state, handle empty notes and malformed input', () => {
  const r = reader();
  r.render('引用[^a]\n\n[^a]: 内容\n\n$2+2$');
  r.render('# 下一篇\n\n正文', { currentPath: '下一篇.md' });
  assert.equal(r.document.querySelectorAll('.footnotes,.katex').length, 0);
  r.render('', { currentPath: '空白.md', title: '空白' });
  assert.equal(r.document.querySelector('.empty-note h1').textContent, '空白');
  r.render('![broken](<bad%zz.png>)\n\n# 同名\n\n# 同名');
  assert.equal(r.document.querySelectorAll('.render-error').length, 0);
  assert.equal(r.document.querySelectorAll('h1')[1].id, '同名-1');
  r.close();
});
