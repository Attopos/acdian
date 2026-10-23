// Run: ACDIAN_BROWSER_EXECUTABLE='/path/to/chromium' node --test live-editor-integration-tests.cjs
// This launches an isolated HEADLESS browser only. No user vault or browser profile is accessed.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const playwrightLocation = process.env.ACDIAN_PLAYWRIGHT || 'playwright';
const { chromium } = require(playwrightLocation);
const resources = path.join(__dirname, 'Resources');
let browser;

test.before(async () => {
  const executablePath = process.env.ACDIAN_BROWSER_EXECUTABLE;
  browser = await chromium.launch({
    headless: true,
    ...(executablePath ? { executablePath } : {}),
    args: ['--disable-background-networking', '--disable-component-update', '--no-first-run'],
    timeout: 20000
  });
});
test.after(async () => { if (browser) await browser.close(); });

async function editor(t, source = '# Fixture\n\nA paragraph.\n', extra = {}) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
  t.after(() => page.close());
  await page.route(/^https?:/, route => route.abort());
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    window.__acdianMessages = [];
    window.webkit = { messageHandlers: { acdian: { postMessage: message => window.__acdianMessages.push(structuredClone(message)) } } };
  });
  await page.goto(pathToFileURL(path.join(resources, 'live-editor.html')).href);
  await page.waitForFunction(() => typeof window.acdianSetDocument === 'function' && window.acdianEditor);
  await page.evaluate(payload => window.acdianSetDocument(payload), { text: source, currentPath: `${t.name}.md`, title: 'Synthetic fixture', ...extra });
  const get = () => page.evaluate(() => ({
    ...window.acdianGetDocument(),
    selection: { anchor: window.acdianEditor.state.selection.main.anchor, head: window.acdianEditor.state.selection.main.head },
    messages: window.__acdianMessages
  }));
  const position = async (anchor, head = anchor) => page.evaluate(({ anchor, head }) => {
    window.acdianEditor.dispatch({ selection: { anchor, head }, scrollIntoView: true });
    window.acdianEditor.focus();
  }, { anchor, head });
  t.after(() => assert.deepEqual(errors, [], 'no uncaught editor errors'));
  return { page, get, position, errors };
}

async function assertBoldDelimitersHidden(page, expected = 2) {
  const markers = await page.locator('.cm-live-bold-delimiter').evaluateAll(elements => elements.map(element => {
    const range = document.createRange();
    range.selectNodeContents(element);
    return { text: element.textContent, width: range.getBoundingClientRect().width, fontSize: getComputedStyle(element).fontSize };
  }));
  assert.equal(markers.length, expected, 'complete bold delimiters remain represented in source');
  for (const marker of markers) {
    assert.match(marker.text, /^(?:\*\*|__)$/);
    assert.ok(marker.width <= 0.5, 'bold delimiters have no visible glyph width');
    assert.equal(marker.fontSize, '0px');
  }
}

async function renderedText(page, selector = '.cm-content') {
  return page.locator(selector).first().evaluate(root => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let result = '';
    for (let node; (node = walker.nextNode());) {
      let hidden = false;
      for (let element = node.parentElement; element; element = element.parentElement) {
        const style = getComputedStyle(element);
        if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0 || style.fontSize === '0px') { hidden = true; break; }
        if (element === root) break;
      }
      if (hidden) continue;
      const range = document.createRange();range.selectNodeContents(node);
      if ([...range.getClientRects()].some(rect => rect.width > 0.1 && rect.height > 0.1)) result += node.textContent;
    }
    return result;
  });
}

async function assertFormattingHidden(page) {
  const markers = await page.locator('.cm-format-delimiter').evaluateAll(elements => elements.map(element => {
    const range = document.createRange();range.selectNodeContents(element);
    return { text: element.textContent, fontSize: getComputedStyle(element).fontSize, width: range.getBoundingClientRect().width };
  }));
  assert.ok(markers.length > 0, 'complete syntax remains represented by native hidden text');
  for (const marker of markers) {
    assert.equal(marker.fontSize, '0px', marker.text);
    assert.ok(marker.width <= 0.5, `hidden marker has no visible glyph width: ${marker.text}`);
  }
}

test('typing in rendered prose preserves caret, raw text and document identity', async t => {
  const r = await editor(t, 'Alpha beta gamma\n');
  await r.position(6);
  await r.page.keyboard.type('one ');
  await r.page.keyboard.insertText('中文🌸');
  const state = await r.get();
  assert.equal(state.text, 'Alpha one 中文🌸beta gamma\n');
  assert.equal(state.selection.anchor, 'Alpha one 中文🌸'.length);
  const changes = state.messages.filter(message => message.type === 'change');
  assert.ok(changes.length > 0);
  assert.equal(changes.at(-1).text, state.text);
  assert.equal(changes.at(-1).currentPath, state.currentPath);
});

test('initial document renders inactive syntax and reading layout without any click', async t => {
  const source = '# Initial heading\n\nAn inactive **bold phrase** and [[Notes/Hello|Alias]].\n\nLast paragraph.\n';
  const r = await editor(t, source, { fontSize: 16 });
  // Let initial parsing and layout settle without dispatching selection or input.
  await r.page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const initial = await r.page.evaluate(() => {
    const content = document.querySelector('.cm-content');
    const heading = document.querySelector('.cm-heading-1');
    return {
      hasHeadingClass: !!heading,
      headingFont: heading ? getComputedStyle(heading).fontSize : null,
      contentPaddingLeft: getComputedStyle(content).paddingLeft,
      visibleText: content.innerText,
      strongCount: document.querySelectorAll('.cm-live-strong').length,
      linkCount: document.querySelectorAll('.cm-live-link').length
    };
  });
  assert.equal(initial.hasHeadingClass, true);
  assert.equal(initial.headingFont, '34px');
  assert.equal(initial.contentPaddingLeft, '58px');
  assert.ok(initial.strongCount > 0);
  assert.equal(initial.linkCount, 1);
  assert.ok(initial.visibleText.includes('bold phrase'));
  await assertBoldDelimitersHidden(r.page);
  assert.equal((await r.get()).text, source);
});

test('native same-text echo preserves selection and undo history', async t => {
  const r = await editor(t, 'Alpha beta\n');
  await r.position(6);
  await r.page.keyboard.type('X');
  const before = await r.get();
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, fontSize: 19, editable: true }), { text: before.text, currentPath: before.currentPath });
  assert.deepEqual((await r.get()).selection, before.selection);
  await r.page.keyboard.type('Y');
  assert.equal((await r.get()).text, 'Alpha XYbeta\n');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, 'Alpha beta\n');
  await r.page.keyboard.press('Meta+Shift+z');
  assert.equal((await r.get()).text, 'Alpha XYbeta\n');
});

test('document revisions increase with input and agree across getter, change and metadata echoes', async t => {
  const r = await editor(t, 'Revision fixture\n');
  const initial = await r.get();
  assert.ok(Number.isSafeInteger(initial.revision) && initial.revision >= 0);
  await r.position(0);
  await r.page.keyboard.type('A');
  const first = await r.get();
  assert.ok(first.revision > initial.revision);
  let change = first.messages.filter(message => message.type === 'change').at(-1);
  assert.equal(change.revision, first.revision);
  assert.equal(change.text, first.text);
  assert.equal(change.currentPath, first.currentPath);
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, fontSize: 18, editable: true }), { text: first.text, currentPath: first.currentPath });
  assert.equal((await r.get()).revision, first.revision, 'metadata or same-text echoes do not reset revision');
  await r.page.keyboard.type('BC');
  const latest = await r.get();
  assert.ok(latest.revision > first.revision);
  const changes = latest.messages.filter(message => message.type === 'change');
  for (let i = 1; i < changes.length; i++) assert.ok(changes[i].revision > changes[i - 1].revision);
  change = changes.at(-1);
  assert.equal(change.revision, latest.revision);
  assert.equal(change.text, latest.text);
});

test('switching documents isolates undo history and change identities', async t => {
  const r = await editor(t, 'First document\n', { currentPath: 'first.md' });
  await r.position(0);
  await r.page.keyboard.type('Unsaved ');
  await r.page.evaluate(() => window.acdianSetDocument({ text: 'Second document\n', currentPath: 'second.md', title: 'Second' }));
  await r.position(0);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, 'Second document\n');
  await r.page.keyboard.type('New ');
  const state = await r.get();
  assert.equal(state.text, 'New Second document\n');
  assert.equal(state.messages.filter(message => message.type === 'change').at(-1).currentPath, 'second.md');
});

test('attachment insertion replaces the selected range once and is undoable', async t => {
  const r = await editor(t, 'Before REPLACE after\n');
  await r.position(7, 14);
  await r.page.evaluate(() => window.acdianInsertText('![[Attachments/中文 图片.png]]'));
  assert.equal((await r.get()).text, 'Before ![[Attachments/中文 图片.png]] after\n');
  await r.page.evaluate(() => window.acdianUndo());
  assert.equal((await r.get()).text, 'Before REPLACE after\n');
  await r.page.evaluate(() => window.acdianRedo());
  assert.equal((await r.get()).text, 'Before ![[Attachments/中文 图片.png]] after\n');
});

test('editability updates block input without dropping source or selection', async t => {
  const r = await editor(t, 'Keep this text\n');
  await r.position(5);
  const before = await r.get();
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, editable: false }), { text: before.text, currentPath: before.currentPath });
  await r.page.keyboard.type('BLOCKED');
  assert.equal((await r.get()).text, before.text);
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, editable: true }), { text: before.text, currentPath: before.currentPath });
  assert.deepEqual((await r.get()).selection, before.selection);
  await r.page.evaluate(() => window.acdianEditor.focus());
  await r.page.keyboard.type('OK ');
  assert.equal((await r.get()).text, 'Keep OK this text\n');
});

test('untouched CRLF and trailing newline survive localized edits', async t => {
  const r = await editor(t, '# 标题\r\n\r\nAlpha\r\nBeta\r\n');
  await r.position('# 标题\n\nAlpha'.length);
  await r.page.keyboard.type('!');
  assert.equal((await r.get()).text, '# 标题\r\n\r\nAlpha!\r\nBeta\r\n');
  await r.page.evaluate(() => window.acdianUndo());
  assert.equal((await r.get()).text, '# 标题\r\n\r\nAlpha\r\nBeta\r\n');
});

test('formatting syntax can be typed without losing input or focus', async t => {
  const r = await editor(t, '');
  await r.position(0);
  const source = '# A heading\n\n**Bold text** and [[Note|alias]].\n\n```js\nconst n = 1;\n```\n';
  await r.page.keyboard.type(source);
  assert.equal((await r.get()).text, source);
  assert.equal(await r.page.evaluate(() => window.acdianEditor.hasFocus), true);
});

test('task list Enter continues the list and an empty item exits cleanly', async t => {
  const r = await editor(t, '- [ ] First task');
  await r.position('- [ ] First task'.length);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '- [ ] First task\n- [ ] ');
  await r.page.keyboard.type('Second task');
  await r.page.keyboard.press('Enter');
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '- [ ] First task\n- [ ] Second task\n');
});

test('synthetic composition event smoke check retains Unicode without duplication', async t => {
  const r = await editor(t, 'Start \n');
  await r.position(6);
  // Real macOS candidate selection must be tested in WKWebView separately.
  await r.page.evaluate(() => document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' })));
  await r.page.keyboard.insertText('输入法🌸');
  await r.page.evaluate(() => document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '输入法🌸' })));
  assert.equal((await r.get()).text, 'Start 输入法🌸\n');
});

test('browser composition updates commit Chinese once at a formatting boundary', async t => {
  const r = await editor(t, '**Bold** tail\n');
  await r.position('**Bold**'.length);
  const cdp = await r.page.context().newCDPSession(r.page);
  await cdp.send('Input.imeSetComposition', { text: 'zhongwen', selectionStart: 8, selectionEnd: 8 });
  await cdp.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 });
  await cdp.send('Input.insertText', { text: '中文' });
  await r.page.waitForFunction(() => window.acdianGetDocument().text === '**Bold**中文 tail\n');
  assert.equal((await r.get()).text, '**Bold**中文 tail\n');
  await r.page.keyboard.type('!');
  assert.equal((await r.get()).text, '**Bold**中文! tail\n');
});

test('native local and external navigation preserve source and include document identity', async t => {
  const source = '# Links\n\n[[Notes/Hello|Alias]]\n\n[Website](https://example.com)\n\nEnd\n';
  const r = await editor(t, source);
  await r.position(source.length);
  await r.page.locator('.cm-live-link').filter({ hasText: 'Alias' }).click({ modifiers: ['Meta'] });
  let state = await r.get();
  const local = state.messages.filter(message => message.type === 'navigate').at(-1);
  assert.equal(local.target, 'Notes/Hello');
  assert.equal(local.from, state.currentPath);
  await r.page.locator('.cm-live-link').filter({ hasText: 'Website' }).click({ modifiers: ['Meta'] });
  state = await r.get();
  const external = state.messages.filter(message => message.type === 'external').at(-1);
  assert.equal(external.target, 'https://example.com');
  assert.equal(external.from, state.currentPath);
  assert.equal(state.text, source);
});

test('images and native table cells render while fenced examples stay literal', async t => {
  const source = '# Widgets\n\n![[Attachments/sample.png|160]]\n\n| Name | Value |\n| --- | --- |\n| A | B |\n\n```md\n![[inside-fence.png]]\n$$\nx^2\n$$\n> [!note] Literal\n```\n\nEnd\n';
  const r = await editor(t, source);
  await r.position(source.length);
  await r.page.waitForSelector('.cm-table-cell');
  assert.equal(await r.page.locator('.cm-block-image').count(), 1);
  assert.equal(await r.page.locator('.cm-block-image img').getAttribute('width'), '160');
  assert.equal(await r.page.locator('.cm-block-math,.cm-callout-line').count(), 0);
  const imageURL = new URL(await r.page.locator('.cm-block-image img').getAttribute('src'));
  assert.equal(decodeURIComponent(imageURL.pathname.slice(1)), 'Attachments/sample.png');
  assert.equal(imageURL.searchParams.get('from'), (await r.get()).currentPath);
  assert.equal((await r.get()).text, source);
});

test('wiki and Markdown PDF embeds navigate internally without active frames', async t => {
  const source = '# PDFs\n\n![[Attachments/sample.pdf#page=2]]\n\n![Manual](Attachments/sample.pdf#page=1)\n\nEnd\n';
  const r = await editor(t, source);
  await r.position(source.length);
  const cards = r.page.locator('.cm-block-image a');
  assert.equal(await cards.count(), 2);
  assert.equal(await r.page.locator('.cm-editor iframe,.cm-editor embed,.cm-editor object').count(), 0);
  await cards.nth(0).click({ modifiers: ['Meta'] });
  assert.equal((await r.get()).messages.filter(message => message.type === 'navigate').at(-1).target, 'Attachments/sample.pdf#page=2');
  await cards.nth(1).click({ modifiers: ['Meta'] });
  assert.equal((await r.get()).messages.filter(message => message.type === 'navigate').at(-1).target, 'Attachments/sample.pdf#page=1');
  assert.equal((await r.get()).text, source);
});

test('table-cell clicks edit native text while the grid stays rendered and undo preserves Markdown', async t => {
  const source = '# Table\n\n| Name | Value |\n| --- | --- |\n| Alpha | Beta |\n\nEnd\n';
  const r = await editor(t, source);
  await r.position(source.length);
  await r.page.locator('.cm-table-cell').filter({ hasText: 'Beta' }).click();
  const state = await r.get();
  assert.ok(state.selection.anchor >= source.indexOf('Beta'));
  assert.ok(state.selection.anchor <= source.indexOf('Beta') + 'Beta'.length);
  assert.equal(state.text, source);
  assert.equal(await r.page.locator('.cm-table-cell').count(), 4);
  assert.ok(!(await renderedText(r.page)).includes('|'), 'table separators stay hidden after a cell click');
  await r.page.keyboard.insertText('中文🌸');
  assert.equal((await r.get()).text, source.slice(0, state.selection.anchor) + '中文🌸' + source.slice(state.selection.anchor));
  assert.equal(await r.page.locator('.cm-table-cell').count(), 4);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);
  assert.equal(await r.page.locator('.cm-table-cell').count(), 4);
});

test('selection deletion across a rich widget preserves exact source and undo', async t => {
  const source = '# Selection\n\nBefore\n\n![[Attachments/sample.png]]\n\nAfter\n';
  const r = await editor(t, source);
  const start = source.indexOf('Before'), end = source.indexOf('After');
  await r.position(start, end);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text, source.slice(0, start) + source.slice(end));
  await r.page.evaluate(() => window.acdianUndo());
  assert.equal((await r.get()).text, source);
});

test('Markdown active content stays inert while idle decorations render', async t => {
  const source = '# Safe heading\n\n<script>window.__unsafe=true</script>\n\n<img src=x onerror="window.__unsafe=true">\n\n[bad](javascript:alert(1))\n\nEnd\n';
  const r = await editor(t, source);
  await r.position(source.length);
  assert.equal(await r.page.evaluate(() => window.__unsafe), undefined);
  assert.equal(await r.page.locator('.cm-editor script,.cm-editor iframe,.cm-editor [onerror]').count(), 0);
  assert.equal((await r.get()).text, source);
});

test('outline scrolling and empty notes preserve source', async t => {
  const source = '# First\n\n' + 'A paragraph.\n\n'.repeat(90) + '## Target 标题\n\nLast paragraph.\n';
  const r = await editor(t, source);
  await r.page.evaluate(() => window.acdianScrollTo('Target 标题'));
  assert.equal((await r.get()).text, source);
  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'empty.md', title: 'Empty' }));
  await r.position(0);
  await r.page.keyboard.insertText('第一句话🌸');
  assert.equal((await r.get()).text, '第一句话🌸');
});

test('typing slash at an empty block opens all insertable elements without changing source', async t => {
  const r = await editor(t, 'Before\nAfter\n');
  await r.position('Before'.length);
  await r.page.keyboard.press('Enter');
  await r.page.keyboard.press('Enter');
  await r.page.keyboard.type('/');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.waitFor({ state: 'visible' });
  assert.deepEqual(await menu.getByRole('option').evaluateAll(options => options.map(option => option.dataset.command)), [
    'text', 'h1', 'h2', 'h3', 'h4', 'quote', 'todo', 'bullet', 'number', 'code', 'callout'
  ]);
  assert.equal(await menu.locator('.cm-slash-icon').count(), 11, 'every insertable element retains its icon');
  assert.equal(await menu.locator('.cm-slash-label').count(), 11, 'every insertable element retains its label');
  assert.equal(await menu.locator('.cm-slash-description').count(), 0, 'the menu omits right-side descriptions from the DOM');
  assert.equal(await menu.locator('.cm-slash-footer').count(), 0, 'the menu omits the shortcut footer from the DOM');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'text');
  assert.equal((await r.get()).text, 'Before\n\n/\nAfter\n');
  assert.equal(await r.page.evaluate(() => window.acdianEditor.hasFocus), true);
});

test('slash search accepts English and Chinese keywords and preserves unmatched input', async t => {
  const r = await editor(t, '');
  const menu = r.page.locator('.cm-slash-menu');
  await r.position(0);
  await r.page.keyboard.type('/HEADING 4');
  await menu.locator('[data-command="h4"]').waitFor({ state: 'visible' });
  assert.equal(await menu.getByRole('option').count(), 1);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '#### ');
  assert.equal((await r.get()).selection.anchor, 5);
  assert.equal(await r.page.locator('.cm-heading-4').count(), 1);

  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'chinese-search.md' }));
  await r.position(0);
  await r.page.keyboard.insertText('/三级标题');
  await menu.locator('[data-command="h3"]').waitFor({ state: 'visible' });
  assert.equal(await menu.getByRole('option').count(), 1);
  await r.page.keyboard.press('Tab');
  assert.equal((await r.get()).text, '### ');

  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'unmatched-search.md' }));
  await r.position(0);
  await r.page.keyboard.type('/zzzz-no-command');
  assert.equal(await menu.getByRole('option').count(), 0);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '/zzzz-no-command\n');
});

test('slash keyboard navigation wraps, chooses with Enter and cancels with Escape', async t => {
  const r = await editor(t, '');
  await r.position(0);
  await r.page.keyboard.type('/');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.waitFor({ state: 'visible' });
  await r.page.keyboard.press('ArrowUp');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'callout');
  await r.page.keyboard.press('ArrowDown');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'text');
  await r.page.keyboard.press('ArrowDown');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'h1');
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '# ');
  assert.equal(await menu.count(), 0);

  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'slash-escape.md' }));
  await r.position(0);
  await r.page.keyboard.type('/quote');
  await menu.waitFor({ state: 'visible' });
  await r.page.keyboard.press('Escape');
  assert.equal(await menu.count(), 0);
  assert.equal((await r.get()).text, '/quote');
  assert.equal((await r.get()).selection.anchor, '/quote'.length);
  assert.equal(await r.page.evaluate(() => window.acdianEditor.hasFocus), true);
});

test('Chinese IME composition keeps slash choices inactive until the query is committed', async t => {
  const r = await editor(t, '');
  await r.position(0);
  await r.page.keyboard.type('/');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.waitFor({ state: 'visible' });
  const cdp = await r.page.context().newCDPSession(r.page);
  await cdp.send('Input.imeSetComposition', { text: 'sanji', selectionStart: 5, selectionEnd: 5 });
  await r.page.waitForFunction(() => window.acdianEditor.composing);
  assert.equal(await menu.count(), 0, 'candidate composition hides the command menu');
  const composingSource = (await r.get()).text;
  await r.page.evaluate(() => document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Enter', code: 'Enter', keyCode: 229, isComposing: true, bubbles: true, cancelable: true
  })));
  assert.equal((await r.get()).text, composingSource, 'composing Enter does not choose a command');
  await cdp.send('Input.imeSetComposition', { text: '三级标题', selectionStart: 4, selectionEnd: 4 });
  await cdp.send('Input.insertText', { text: '三级标题' });
  await r.page.waitForFunction(() => window.acdianGetDocument().text === '/三级标题' && !window.acdianEditor.composing);
  await menu.locator('[data-command="h3"]').waitFor({ state: 'visible' });
  assert.equal(await menu.getByRole('option').count(), 1);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '### ');
});

test('every slash choice inserts its Markdown template with an isolated undo step', async t => {
  const prefix = 'Before\n\n', suffix = '\nAfter\n';
  const choices = [
    ['text', '', 0],
    ['h1', '# ', 2],
    ['h2', '## ', 3],
    ['h3', '### ', 4],
    ['h4', '#### ', 5],
    ['quote', '> ', 2],
    ['todo', '- [ ] ', 6],
    ['bullet', '- ', 2],
    ['number', '1. ', 3],
    ['code', '```\n\n```', 4],
    ['callout', '> [!note]\n> ', 12]
  ];
  for (const [command, template, caret] of choices) {
    await t.test(command, async sub => {
      const r = await editor(sub, 'Before\nAfter\n');
      await r.position('Before'.length);
      await r.page.keyboard.press('Enter');
      await r.page.keyboard.press('Enter');
      await r.page.keyboard.type('/');
      const menu = r.page.locator('.cm-slash-menu');
      await menu.locator(`[data-command="${command}"]`).click();
      assert.equal((await r.get()).text, prefix + template + suffix);
      assert.equal((await r.get()).selection.anchor, prefix.length + caret);
      assert.equal(await menu.count(), 0);
      assert.equal(await r.page.evaluate(() => window.acdianEditor.hasFocus), true);
      await r.page.keyboard.press('Meta+z');
      assert.equal((await r.get()).text, prefix + '/' + suffix, 'one undo restores the typed slash');
      assert.equal(await menu.count(), 0, 'undo does not reopen the insertion menu');
      await r.page.keyboard.press('Meta+Shift+z');
      assert.equal((await r.get()).text, prefix + template + suffix);
    });
  }
});

test('slash choice removes its search query while preserving the rest of the block', async t => {
  const r = await editor(t, 'Existing words\n');
  await r.position(0);
  await r.page.keyboard.type('/quote');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.locator('[data-command="quote"]').click();
  assert.equal((await r.get()).text, '> Existing words\n');
  assert.equal((await r.get()).selection.anchor, 2);
  assert.equal(await r.page.locator('.cm-quote-line').count(), 1);
  await r.position('> Existing words\n'.length);
  assert.equal(await renderedText(r.page,'.cm-quote-line'), 'Existing words');
  assert.equal((await r.get()).text, '> Existing words\n', 'quote styling preserves exact Markdown');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, '/quoteExisting words\n');
});

test('slash does not trigger inside prose, URLs, inline code or fenced code', async t => {
  const fixtures = [
    ['prose', 'A paragraph ', 'A paragraph '.length],
    ['URL', 'https:', 'https:'.length],
    ['inline code', '`inline `\n', '`inline '.length],
    ['fenced code', '```js\n\n```\n', '```js\n'.length]
  ];
  for (const [name, source, cursor] of fixtures) {
    await t.test(name, async sub => {
      const r = await editor(sub, source);
      await r.position(cursor);
      await r.page.keyboard.type('/');
      assert.equal(await r.page.locator('.cm-slash-menu').count(), 0);
      assert.equal((await r.get()).text, source.slice(0, cursor) + '/' + source.slice(cursor));
    });
  }
});

test('loaded slash content, read-only mode and document switches keep insertion menus closed', async t => {
  const r = await editor(t, '/quote');
  const menu = r.page.locator('.cm-slash-menu');
  await r.position('/quote'.length);
  assert.equal(await menu.count(), 0);
  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'editable-slash.md' }));
  await r.position(0);
  await r.page.keyboard.type('/');
  await menu.waitFor({ state: 'visible' });
  await r.page.evaluate(() => window.acdianSetDocument({ text: '/', currentPath: 'editable-slash.md', editable: false }));
  assert.equal(await menu.count(), 0);
  await r.page.keyboard.type('quote');
  assert.equal((await r.get()).text, '/');
  await r.page.evaluate(() => window.acdianSetDocument({ text: '', currentPath: 'new-slash.md', editable: true }));
  await r.position(0);
  await r.page.keyboard.type('/');
  await menu.waitFor({ state: 'visible' });
  await r.page.evaluate(() => window.acdianSetDocument({ text: '/quote', currentPath: 'different-slash.md' }));
  assert.equal(await menu.count(), 0);
  assert.equal((await r.get()).text, '/quote');
});

test('slash menu stays in a small viewport and scrolls to keyboard selection', async t => {
  const r = await editor(t, 'Paragraph.\n\n'.repeat(35));
  await r.page.setViewportSize({ width: 390, height: 310 });
  await r.position((await r.get()).text.length);
  await r.page.keyboard.type('/');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.waitFor({ state: 'visible' });
  await r.page.keyboard.press('ArrowUp');
  await r.page.waitForFunction(() => {
    const menu = document.querySelector('.cm-slash-menu');
    const selected = menu && menu.querySelector('[aria-selected="true"]');
    if (!selected) return false;
    const outer = menu.getBoundingClientRect(), item = selected.getBoundingClientRect();
    return outer.left >= 0 && outer.top >= 0 && outer.right <= innerWidth + 1 && outer.bottom <= innerHeight + 1
      && item.top >= outer.top && item.bottom <= outer.bottom;
  });
  const box = await menu.boundingBox();
  assert.ok(box.x >= 0 && box.y >= 0, 'menu starts inside the viewport');
  assert.ok(box.x + box.width <= 391 && box.y + box.height <= 311, 'menu fits the viewport');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'callout');
});

test('typing three dashes, a space and Enter renders a divider without losing the caret', async t => {
  const r = await editor(t, '');
  await r.position(0);
  await r.page.keyboard.type('---');
  await r.page.keyboard.press('Space');
  await r.page.locator('.cm-live-divider hr').waitFor({ state: 'visible' });
  assert.equal((await r.get()).text, '--- ');
  assert.equal((await r.get()).selection.anchor, 4);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '--- \n');
  assert.equal((await r.get()).selection.anchor, 5);
  assert.equal(await r.page.locator('.cm-live-divider hr').count(), 1);
  assert.equal(await r.page.evaluate(() => window.acdianEditor.hasFocus), true);
  await r.page.keyboard.type('After divider');
  assert.equal((await r.get()).text, '--- \nAfter divider');
});

test('divider clicks and selections keep the rule rendered while keyboard edits remain undoable', async t => {
  const source = '--- \n\nAfter\n';
  const r = await editor(t, source);
  await r.position(source.length);
  await r.page.locator('.cm-live-divider hr').click();
  assert.equal(await r.page.locator('.cm-live-divider').count(), 1);
  assert.equal((await r.get()).text, source);
  assert.equal((await r.get()).selection.anchor, 4);
  assert.ok(!(await renderedText(r.page)).includes('---'));
  await r.position(0, 4);
  assert.equal(await r.page.locator('.cm-live-divider').count(), 1);
  assert.ok(!(await renderedText(r.page)).includes('---'));
  await r.position(4);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text, '\n\nAfter\n', 'Backspace removes the rendered rule as one block');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);
  await r.position(source.length);
  await r.page.locator('.cm-live-divider hr').waitFor({ state: 'visible' });
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, editable: false }), { text: source, currentPath: (await r.get()).currentPath });
  await r.page.locator('.cm-live-divider hr').click();
  assert.equal(await r.page.locator('.cm-live-divider hr').count(), 1);
  assert.equal((await r.get()).text, source);
});

test('clicks after headings map to the visible paragraph despite trailing blank lines', async t => {
  for (const level of [1, 2, 3, 4]) {
    await t.test(`heading ${level}`, async sub => {
      const source = '#'.repeat(level) + ' Escritura sin distracciones\n\nHaz clic en **este texto en negrita** y sigue escribiendo.\n\n';
      const r = await editor(sub, source, { language: 'es', fontSize: 16 });
      await r.position(source.length);
      await r.page.evaluate(() => document.fonts.ready);
      await r.page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const box = await r.page.locator('.cm-live-strong').filter({ hasText: 'este texto en negrita' }).boundingBox();
      const point = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      const mapping = await r.page.evaluate(point => {
        const view = window.acdianEditor, caret = document.caretPositionFromPoint(point.x, point.y);
        const line = caret.offsetNode.parentElement.closest('.cm-line');
        return {
          nativePosition: view.posAtDOM(caret.offsetNode, caret.offset),
          editorPosition: view.posAtCoords(point),
          nativeTop: line.getBoundingClientRect().top,
          editorTop: view.documentTop + view.lineBlockAt(view.posAtDOM(caret.offsetNode, caret.offset)).top
        };
      }, point);
      assert.equal(mapping.editorPosition, mapping.nativePosition, 'editor click coordinates agree with the browser text position');
      assert.ok(Math.abs(mapping.nativeTop - mapping.editorTop) <= 1, 'heading spacing is included in measured line geometry');
      await r.page.mouse.click(point.x, point.y);
      assert.equal((await r.get()).selection.anchor, mapping.nativePosition);
      assert.ok(mapping.nativePosition >= source.indexOf('este texto') && mapping.nativePosition <= source.indexOf('** y sigue'));
      await assertBoldDelimitersHidden(r.page);

      const plain = await r.page.evaluate(() => {
        const walker = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT);
        for (let node; (node = walker.nextNode());) {
          const start = node.textContent.indexOf('sigue');
          if (start < 0) continue;
          const range = document.createRange();range.setStart(node, start);range.setEnd(node, start + 5);
          const rect = range.getBoundingClientRect();return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        }
      });
      await r.page.mouse.click(plain.x, plain.y);
      const state = await r.get();
      assert.ok(state.selection.anchor >= source.indexOf('sigue') && state.selection.anchor <= source.indexOf('sigue') + 5, 'plain text clicks map to the visible word too');
      assert.equal(state.text, source);
    });
  }
});

test('clicking and editing rendered bold keeps its delimiters hidden and preserves undo', async t => {
  const source = 'Before **bold words** after\n';
  const r = await editor(t, source);
  await r.position(source.length);
  const bold = r.page.locator('.cm-live-strong').filter({ hasText: 'bold words' }).first();
  const box = await bold.boundingBox();
  await r.page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  const clicked = await r.get();
  const start = source.indexOf('bold words'), end = start + 'bold words'.length;
  assert.equal(clicked.text, source);
  assert.ok(clicked.selection.anchor >= start && clicked.selection.anchor <= end, 'mouse click maps inside the bold text');
  await assertBoldDelimitersHidden(r.page);
  assert.ok(Number(await bold.evaluate(element => getComputedStyle(element).fontWeight)) >= 600);
  await r.page.keyboard.type('X');
  assert.equal((await r.get()).text, source.slice(0, clicked.selection.anchor) + 'X' + source.slice(clicked.selection.anchor));
  assert.equal((await r.get()).selection.anchor, clicked.selection.anchor + 1);
  await assertBoldDelimitersHidden(r.page);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);
  await assertBoldDelimitersHidden(r.page);
  await r.page.keyboard.press('Meta+Shift+z');
  assert.equal((await r.get()).text, source.slice(0, clicked.selection.anchor) + 'X' + source.slice(clicked.selection.anchor));
  await assertBoldDelimitersHidden(r.page);
});

test('bold delimiter boundaries support arrow movement and adjacent character deletion', async t => {
  const source = 'A **bold** Z\n', start = source.indexOf('bold'), end = start + 4;
  const r = await editor(t, source);
  await r.position(start);
  await r.page.keyboard.press('ArrowLeft');
  assert.equal((await r.get()).selection.anchor, start - 2, 'left skips the hidden opening delimiter');
  await r.page.keyboard.press('ArrowRight');
  assert.equal((await r.get()).selection.anchor, start);
  await r.position(end);
  await r.page.keyboard.press('ArrowRight');
  assert.equal((await r.get()).selection.anchor, end + 2, 'right skips the hidden closing delimiter');
  await r.page.keyboard.press('ArrowLeft');
  assert.equal((await r.get()).selection.anchor, end);
  await assertBoldDelimitersHidden(r.page);

  await r.position(start + 1);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text, 'A **old** Z\n');
  await assertBoldDelimitersHidden(r.page);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);
  await r.position(end - 1);
  await r.page.keyboard.press('Delete');
  assert.equal((await r.get()).text, 'A **bol** Z\n');
  await assertBoldDelimitersHidden(r.page);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);

  const boundaryDeletes = [
    [start - 2, 'Delete', 'A **old** Z\n'],
    [end + 2, 'Backspace', 'A **bol** Z\n'],
    [start, 'Backspace', 'A**bold** Z\n'],
    [end, 'Delete', 'A **bold**Z\n']
  ];
  for (const [cursor, key, expected] of boundaryDeletes) {
    await r.position(cursor);
    await r.page.keyboard.press(key);
    assert.equal((await r.get()).text, expected, `${key} removes the visible character across a hidden delimiter`);
    await assertBoldDelimitersHidden(r.page);
    await r.page.keyboard.press('Meta+z');
    assert.equal((await r.get()).text, source);
  }
});

test('bold boundary deletion is safe at document edges and removes empty formatting pairs', async t => {
  const r = await editor(t, '**bold**');
  await r.position(2);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text, '**bold**');
  await r.position(6);
  await r.page.keyboard.press('Delete');
  assert.equal((await r.get()).text, '**bold**');
  await assertBoldDelimitersHidden(r.page);
  await r.page.evaluate(() => window.acdianSetDocument({ text: '**b**', currentPath: 'bold-single-character.md' }));
  await r.position(3);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text, '');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, '**b**');
  await assertBoldDelimitersHidden(r.page);
});

test('nested bold hides only its formatting delimiters while code stays literal', async t => {
  const source = '**Bold *nested* word** and __under__ plus `**literal**`\n\n```md\n**literal fence**\n```\n';
  const r = await editor(t, source);
  await r.position(source.length);
  const bold = r.page.locator('.cm-live-strong').filter({ hasText: 'Bold' }).first();
  const box = await bold.boundingBox();
  await r.page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await assertBoldDelimitersHidden(r.page, 4);
  assert.equal((await r.get()).text, source);
  const code = r.page.locator('.cm-live-code').filter({ hasText: '**literal**' });
  assert.equal(await code.count(), 1);
  assert.ok((await code.innerText()).includes('**literal**'));
  const literalFence = r.page.locator('.cm-code-line').filter({ hasText: '**literal fence**' });
  assert.equal(await literalFence.count(), 1);
  assert.equal(await literalFence.locator('.cm-live-bold-delimiter').count(), 0);
  assert.ok((await code.boundingBox()).width > 30, 'literal code markers keep visible width');
  await r.position(source.indexOf('under') + 2);
  await r.page.keyboard.type('X');
  assert.equal((await r.get()).text, source.replace('__under__', '__unXder__'));
  await assertBoldDelimitersHidden(r.page, 4);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, source);
});

test('Chinese composition inside active bold preserves content once with hidden delimiters', async t => {
  const source = 'A **bold** Z\n', cursor = source.indexOf('bold') + 2;
  const r = await editor(t, source);
  await r.position(cursor);
  await assertBoldDelimitersHidden(r.page);
  const cdp = await r.page.context().newCDPSession(r.page);
  await cdp.send('Input.imeSetComposition', { text: 'zhongwen', selectionStart: 8, selectionEnd: 8 });
  await cdp.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 });
  await cdp.send('Input.insertText', { text: '中文' });
  const expected = source.slice(0, cursor) + '中文' + source.slice(cursor);
  await r.page.waitForFunction(expected => window.acdianGetDocument().text === expected, expected);
  assert.equal((await r.get()).text, expected);
  await assertBoldDelimitersHidden(r.page);
  await r.page.keyboard.type('!');
  assert.equal((await r.get()).text, source.slice(0, cursor) + '中文!' + source.slice(cursor));
  await assertBoldDelimitersHidden(r.page);
});

test('Enter uses compact line spacing and preserves normal Markdown newlines', async t => {
  const r = await editor(t, 'First line', { fontSize: 16 });
  await r.position('First line'.length);
  await r.page.keyboard.press('Enter');
  await r.page.keyboard.type('Second line');
  assert.equal((await r.get()).text, 'First line\nSecond line');
  const layout = await r.page.evaluate(() => {
    const lines = [...document.querySelectorAll('.cm-line')];
    const style = getComputedStyle(document.querySelector('.cm-scroller'));
    return { font: parseFloat(style.fontSize), lineHeight: parseFloat(style.lineHeight), distance: lines[1].getBoundingClientRect().top - lines[0].getBoundingClientRect().top };
  });
  assert.ok(Math.abs(layout.lineHeight / layout.font - 1.6) < 0.02);
  assert.ok(layout.distance >= 25 && layout.distance <= 27, 'adjacent 16px lines stay close to the 25.6px line height');
});

test('every active rich format keeps syntax hidden for carets, raw-marker positions and spanning selections', async t => {
  const source = '# Heading\n\n*Italic* ~~Struck~~ `Inline` ==Marked== [WebLabel](https://example.com/secret) [[Notes/Target|WikiLabel]]\n\n> Quote body\n\n> [!note] Callout title\n> Callout body\n\n```js\nconst answer = 42;\n```\n\n--- \n\nEnd\n';
  const r = await editor(t, source);
  const initial = await r.get();
  const visible = async () => {
    await assertFormattingHidden(r.page);
    const text = await renderedText(r.page);
    for (const body of ['Heading','Italic','Struck','Inline','Marked','WebLabel','WikiLabel','Quote body','Callout title','Callout body','const answer = 42;']) assert.ok(text.includes(body), `${body} remains visible`);
    for (const marker of ['# ','*Italic*','~~Struck~~','`Inline`','==Marked==','https://example.com/secret','Notes/Target','> ','[!note]','```','---']) assert.ok(!text.includes(marker), `syntax stays hidden: ${marker}`);
    assert.ok(await r.page.locator('.cm-callout-line').count() >= 2);
    assert.equal(await r.page.locator('.cm-live-divider').count(), 1);
    assert.equal((await r.get()).text, source);
    assert.equal((await r.get()).revision, initial.revision, 'selection-only changes do not alter the document revision');
  };
  for (const body of ['Heading','Italic','Struck','Inline','Marked','WebLabel','WikiLabel','Quote body','Callout body']) {
    await r.position(source.indexOf(body) + 2);await visible();
  }
  for (const marker of ['# ','*Italic*','[WebLabel]','> Quote','> [!note]','```js','--- ']) {
    await r.position(source.indexOf(marker));await visible();
  }
  await r.position(0, source.length);await visible();
});

test('active headings, inline styles, links, quotes and callouts retain Unicode typing and undo', async t => {
  const fixtures = [
    ['heading','## 内容🌸\r\n\r\nTail\r\n'],
    ['emphasis','*内容🌸* tail\r\n'],
    ['inline code','`内容🌸` tail\r\n'],
    ['link label','[内容🌸](https://example.com) tail\r\n'],
    ['quote','> 内容🌸\r\n'],
    ['callout','> [!note] Title\r\n> 内容🌸\r\n']
  ];
  for (const [name, source] of fixtures) await t.test(name, async sub => {
    const r = await editor(sub, source);
    const raw = source.indexOf('内容') + 1, cursor = source.replace(/\r\n/g,'\n').indexOf('内容') + 1;
    await r.position(cursor);await assertFormattingHidden(r.page);
    await r.page.keyboard.insertText('新🌸');
    const edited = source.slice(0,raw) + '新🌸' + source.slice(raw);
    assert.equal((await r.get()).text, edited);
    assert.equal((await r.get()).selection.anchor, cursor + '新🌸'.length);
    await assertFormattingHidden(r.page);
    await r.page.keyboard.press('Meta+z');assert.equal((await r.get()).text, source);
    await r.page.keyboard.press('Meta+Shift+z');assert.equal((await r.get()).text, edited);
    await r.page.keyboard.press('Backspace');
    assert.equal((await r.get()).text, source.slice(0,raw) + '新' + source.slice(raw), 'Backspace removes a complete emoji without exposing or deleting syntax');
    await assertFormattingHidden(r.page);
  });
});

test('initial focus, Home and ArrowLeft cannot type before hidden heading or quote prefixes', async t => {
  for (const [name,prefix,body] of [['heading','## ','Heading'],['quote','> ','Quote']]) {
    for (const movement of ['initial focus','Home','ArrowLeft']) await t.test(`${name}: ${movement}`,async sub=>{
      const source=prefix+body+'\n',r=await editor(sub,source);
      if(movement==='initial focus')await r.page.evaluate(()=>window.acdianEditor.focus());
      else if(movement==='Home'){await r.position(prefix.length+2);await r.page.keyboard.press('Home');}
      else{await r.position(prefix.length);await r.page.keyboard.press('ArrowLeft');}
      await r.page.keyboard.insertText('新🌸');
      assert.equal((await r.get()).text,prefix+'新🌸'+body+'\n','typing at the visible block start preserves its hidden structural prefix');
      await assertFormattingHidden(r.page);
      await r.page.keyboard.press('Meta+z');assert.equal((await r.get()).text,source);
    });
    await t.test(`${name}: Backspace removes only the block prefix`,async sub=>{
      const source=prefix+body+'\n',r=await editor(sub,source);
      await r.position(prefix.length);await r.page.keyboard.press('Backspace');
      assert.equal((await r.get()).text,body+'\n');
      await r.page.keyboard.press('Meta+z');assert.equal((await r.get()).text,source);
      await assertFormattingHidden(r.page);
    });
  }
});

test('Chinese IME commits once inside active heading, inline code, link and callout bodies', async t => {
  const fixtures = [
    ['heading','### Before内容After\n'],
    ['inline code','`Before内容After`\n'],
    ['link','[Before内容After](https://example.com)\n'],
    ['callout','> [!note] Title\n> Before内容After\n']
  ];
  for (const [name, source] of fixtures) await t.test(name, async sub => {
    const r = await editor(sub, source), cursor = source.indexOf('内容');
    await r.position(cursor);
    const cdp = await r.page.context().newCDPSession(r.page);
    await cdp.send('Input.imeSetComposition',{text:'zhongwen',selectionStart:8,selectionEnd:8});
    await assertFormattingHidden(r.page);
    await cdp.send('Input.imeSetComposition',{text:'中文',selectionStart:2,selectionEnd:2});
    await cdp.send('Input.insertText',{text:'中文'});
    const expected = source.slice(0,cursor) + '中文' + source.slice(cursor);
    await r.page.waitForFunction(expected=>window.acdianGetDocument().text===expected,expected);
    assert.equal((await r.get()).text, expected);await assertFormattingHidden(r.page);
    await r.page.keyboard.type('!');
    assert.equal((await r.get()).text, source.slice(0,cursor) + '中文!' + source.slice(cursor));
  });
});

test('heading, blank-line and divider geometry is compact and unchanged by active selections', async t => {
  const source = '# First heading\n\nFirst paragraph\n\n## Second heading\n\nSecond paragraph\n\n### Third heading\n\nThird paragraph\n\n#### Fourth heading\n\nFourth paragraph\n\n--- \n\nAfter divider\n';
  const r = await editor(t, source, {fontSize:16});
  const geometry = () => r.page.evaluate(() => ({
    headings:[...document.querySelectorAll('.cm-heading')].map(element=>element.getBoundingClientRect().height),
    headingGaps:[...document.querySelectorAll('.cm-heading')].map(element=>element.nextElementSibling.nextElementSibling.getBoundingClientRect().top-element.getBoundingClientRect().bottom),
    blanks:[...document.querySelectorAll('.cm-blank-line')].map(element=>element.getBoundingClientRect().height),
    divider:document.querySelector('.cm-divider-line').getBoundingClientRect().height,
    dividerGap:(()=>{const rule=document.querySelector('.cm-divider-line');return rule.nextElementSibling.nextElementSibling.getBoundingClientRect().top-rule.getBoundingClientRect().bottom;})(),
    bufferMargins:[...document.querySelectorAll('img.cm-widgetBuffer')].map(element=>{const style=getComputedStyle(element);return [style.marginTop,style.marginRight,style.marginBottom,style.marginLeft];}),
    lines:[...document.querySelectorAll('.cm-line')].map(element=>({top:element.getBoundingClientRect().top,height:element.getBoundingClientRect().height}))
  }));
  await r.page.evaluate(()=>document.fonts.ready);
  const before = await geometry();
  assert.equal(before.headings.length,4);
  for (const [index, maximum] of [60,52,40,38].entries()) assert.ok(before.headings[index] <= maximum, `heading ${index+1} avoids the previous oversized block gap`);
  assert.ok(before.blanks.length >= 8);
  for (const height of before.blanks) assert.ok(Math.abs(height) <= 0.5,'separator blank lines have zero visual height');
  for (const gap of before.headingGaps) assert.ok(Math.abs(gap) <= 0.5,'separator blank lines add no visual gap after headings');
  assert.ok(before.divider >= 25 && before.divider <= 27,'a divider occupies one ordinary line without extra padding');
  assert.ok(Math.abs(before.dividerGap) <= 0.5,'separator blank lines add no visual gap after a divider');
  for (const margins of before.bufferMargins) assert.deepEqual(margins,['0px','0px','0px','0px'],'internal caret buffers must not inherit reader-image margins');
  await r.position(0,source.length);
  const active = await geometry();
  assert.equal(active.lines.length,before.lines.length);
  active.lines.forEach((line,index)=>assert.ok(Math.abs(line.height-before.lines[index].height)<=1,'selection does not expand rendered line heights'));
  for (const height of active.blanks) assert.ok(Math.abs(height) <= 0.5,'spanning selections do not expand separator blank lines');
  assert.equal((await r.get()).text,source);
});

test('selecting an existing separator skips to visible heading text without expanding or changing Markdown', async t => {
  const source = 'Before\r\n\r\n## Heading\r\n\r\nAfter\r\n';
  const canonical = source.replace(/\r\n/g,'\n');
  const r = await editor(t,source,{fontSize:16});
  const before = await r.get();
  await r.position(canonical.indexOf('\n\n')+1);
  const selected = await r.get();
  assert.equal(selected.selection.anchor,canonical.indexOf('Heading'),'the caret lands after the hidden heading prefix');
  assert.equal(selected.text,source);
  assert.equal(selected.revision,before.revision,'moving past a separator does not edit the document');
  assert.equal(await r.page.locator('.cm-input-blank-line').count(),0,'old separators never become input paragraphs');
  const heights = await r.page.locator('.cm-blank-line').evaluateAll(lines=>lines.map(line=>line.getBoundingClientRect().height));
  for (const height of heights) assert.ok(Math.abs(height)<=0.5,'old separators keep zero visual height after a caret move');
  await r.page.keyboard.insertText('新🌸');
  const edited = source.replace('## Heading','## 新🌸Heading');
  assert.equal((await r.get()).text,edited);
  assert.equal(await r.page.locator('.cm-heading-2').count(),1);
  await assertFormattingHidden(r.page);
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text,source,'undo restores exact CRLF Markdown after typing at the skipped-to heading');
  await r.page.keyboard.press('Meta+Shift+z');
  assert.equal((await r.get()).text,edited);
});

test('Enter creates a writable normal-height paragraph while existing separators remain collapsed', async t => {
  const source = 'First\r\n\r\nSecond\r\n';
  const r = await editor(t,source,{fontSize:16});
  await r.position('First'.length);
  await r.page.keyboard.press('Enter');
  const withParagraph = 'First\r\n\r\n\r\nSecond\r\n';
  assert.equal((await r.get()).text,withParagraph);
  assert.equal((await r.get()).selection.anchor,'First\n'.length);
  const input = r.page.locator('.cm-input-blank-line');
  assert.equal(await input.count(),1,'only the newly created paragraph has a visible input line');
  const height = await input.evaluate(line=>line.getBoundingClientRect().height);
  assert.ok(height>=25&&height<=27,'the active empty paragraph retains the normal 25.6px body line height');
  const separators = await r.page.locator('.cm-blank-line:not(.cm-input-blank-line)').evaluateAll(lines=>lines.map(line=>line.getBoundingClientRect().height));
  assert.ok(separators.length>0);
  for (const separator of separators) assert.ok(Math.abs(separator)<=0.5);
  await r.page.keyboard.insertText('新🌸');
  assert.equal((await r.get()).text,'First\r\n新🌸\r\n\r\nSecond\r\n');
  assert.equal(await r.page.locator('.cm-input-blank-line').count(),0);
  await r.page.keyboard.press('Meta+z');
  let undone = (await r.get()).text;
  if (undone === withParagraph) {
    await r.page.keyboard.press('Meta+z');
    undone = (await r.get()).text;
  }
  assert.equal(undone,source,'undo restores exact source whether typing joins the Enter history event or not');
});

test('ArrowLeft across separators skips hidden closing syntax and lands on visible editable content', async t => {
  const fixtures = [
    ['fenced code','```js\nconst x=1;\n```\n\nAfter','const x=1;', '.cm-code-line'],
    ['Setext heading','Heading\n---\n\nAfter','Heading', '.cm-heading-2'],
    ['empty code line','```js\n\n```\n\nAfter','', '.cm-code-line']
  ];
  for (const [name,source,content,selector] of fixtures) await t.test(name,async sub=>{
    const r = await editor(sub,source,{fontSize:16});
    const target = content ? source.indexOf(content)+content.length : source.indexOf('\n')+1;
    await r.position(source.indexOf('After'));
    const before = await r.get();
    await r.page.keyboard.press('ArrowLeft');
    const selected = await r.get();
    assert.equal(selected.selection.anchor,target,`${name}: the caret skips the separator and hidden closing syntax`);
    assert.equal(selected.text,source);
    assert.equal(selected.revision,before.revision,'caret navigation preserves the document revision');
    const height = await r.page.locator(selector).last().evaluate(line=>line.getBoundingClientRect().height);
    assert.ok(height>0,'the navigation target is a visible content line, including an empty code line');
    await r.page.keyboard.insertText('新🌸');
    assert.equal((await r.get()).text,source.slice(0,target)+'新🌸'+source.slice(target));
    await r.page.keyboard.press('Meta+z');
    assert.equal((await r.get()).text,source,'undo restores all hidden fences and heading syntax exactly');
  });
});

test('an all-whitespace note starts with one visible writable input line and preserves its source', async t => {
  for (const [name,source] of [['LF',' \n\n'],['CRLF',' \r\n\t\r\n']]) await t.test(name,async sub=>{
    const r = await editor(sub,source,{fontSize:16});
    const assertInput = async () => {
      const input = r.page.locator('.cm-input-blank-line');
      assert.equal(await input.count(),1,'a whitespace-only note always exposes its current input line');
      const height = await input.evaluate(line=>line.getBoundingClientRect().height);
      assert.ok(height>=25&&height<=27,'the input line has the normal body line height');
    };
    const before = await r.get();
    await assertInput();
    assert.equal(before.text,source,'initial rendering leaves whitespace and line endings untouched');
    await r.page.evaluate(()=>window.acdianEditor.focus());
    await r.page.keyboard.insertText('新🌸');
    assert.equal((await r.get()).text,'新🌸'+source);
    await r.page.keyboard.press('Meta+z');
    assert.equal((await r.get()).text,source);
    await assertInput();
    const middle = source.replace(/\r\n/g,'\n').indexOf('\n')+1;
    await r.position(middle);
    await assertInput();
    assert.equal((await r.get()).selection.anchor,middle,'moving within a whitespace-only note keeps the chosen input line');
    const rawMiddle = source.indexOf('\n')+1;
    await r.page.keyboard.insertText('中');
    assert.equal((await r.get()).text,source.slice(0,rawMiddle)+'中'+source.slice(rawMiddle));
    await r.page.keyboard.press('Meta+z');
    assert.equal((await r.get()).text,source);
  });
});

test('table Tab navigation and final-cell row insertion preserve a rendered native grid', async t => {
  const source='| Name | Value |\n| --- | --- |\n| Alpha | Beta |',r=await editor(t,source);
  await r.position(source.indexOf('Alpha')+2);
  await r.page.keyboard.press('Tab');
  let state=await r.get();assert.ok(state.selection.anchor>=source.indexOf('Beta')&&state.selection.anchor<=source.indexOf('Beta')+4);
  await r.page.keyboard.press('Shift+Tab');
  state=await r.get();assert.ok(state.selection.anchor>=source.indexOf('Alpha')&&state.selection.anchor<=source.indexOf('Alpha')+5);
  await r.position(source.indexOf('Beta')+2);await r.page.keyboard.press('Tab');
  state=await r.get();assert.ok(state.text.startsWith(source+'\n'));
  assert.match(state.text.slice(source.length),/^\n\|[ \t]*\|[ \t]*\|$/,'final Tab appends a matching empty row');
  assert.equal(await r.page.locator('.cm-table-cell').count(),6);
  assert.ok(!(await renderedText(r.page)).includes('|'));
  await r.page.keyboard.insertText('新🌸');
  assert.ok((await r.get()).text.includes('新🌸'));assert.equal(await r.page.locator('.cm-table-cell').count(),6);
  await r.page.keyboard.press('Meta+z');
  assert.ok(!(await r.get()).text.includes('新🌸'));
});

test('table range deletion protects structure and escaped pipes stay in their original cells', async t => {
  const source='| Name | Value |\r\n| --- | --- |\r\n| Alpha \\| literal | Beta🌸 |\r\n',r=await editor(t,source);
  assert.equal(await r.page.locator('.cm-table-cell').count(),4,'an escaped pipe does not create an extra column');
  const canonical=source.replace(/\r\n/g,'\n'),start=canonical.indexOf('Alpha'),end=canonical.indexOf('Beta🌸')+'Beta🌸'.length;
  await r.position(start,end);assert.equal(await r.page.locator('.cm-table-cell').count(),4);
  await r.page.keyboard.press('Backspace');
  const deleted=(await r.get()).text;
  assert.ok(deleted.startsWith('| Name | Value |\r\n| --- | --- |\r\n'));
  assert.match(deleted.split('\r\n')[2],/^\|[ \t]*\|[ \t]*\|$/,'a multi-cell delete clears content while retaining cell separators');
  assert.equal(await r.page.locator('.cm-table-cell').count(),4);
  await r.page.keyboard.press('Meta+z');assert.equal((await r.get()).text,source);
});

test('table IME, emoji deletion and read-only mode retain native cells without source reveal', async t => {
  const source='| Name | Value |\n| --- | --- |\n| Alpha | Beta |\n',r=await editor(t,source),cursor=source.indexOf('Beta')+2;
  await r.position(cursor);
  const cdp=await r.page.context().newCDPSession(r.page);
  await cdp.send('Input.imeSetComposition',{text:'zhongwen',selectionStart:8,selectionEnd:8});
  assert.equal(await r.page.locator('.cm-table-cell').count(),4);
  await cdp.send('Input.imeSetComposition',{text:'中文🌸',selectionStart:4,selectionEnd:4});
  await cdp.send('Input.insertText',{text:'中文🌸'});
  const expected=source.slice(0,cursor)+'中文🌸'+source.slice(cursor);
  await r.page.waitForFunction(expected=>window.acdianGetDocument().text===expected,expected);
  assert.equal((await r.get()).text,expected);assert.equal(await r.page.locator('.cm-table-cell').count(),4);
  await r.page.keyboard.press('Backspace');
  assert.equal((await r.get()).text,source.slice(0,cursor)+'中文'+source.slice(cursor));
  const before=await r.get();
  await r.page.evaluate(payload=>window.acdianSetDocument({...payload,editable:false}),{text:before.text,currentPath:before.currentPath});
  await r.page.keyboard.type('BLOCKED');await r.page.keyboard.press('Tab');
  assert.equal((await r.get()).text,before.text);
  assert.equal(await r.page.locator('.cm-table-cell').count(),4);
  assert.ok(!(await renderedText(r.page)).includes('|'));
});

test('nested bold and links in table cells preserve two-column geometry during clicks and IME', async t => {
  const source='| Name | Value |\n| --- | --- |\n| **Bold中文** | [Label中文](https://example.com) |\n';
  for(const [name,selector,word] of [['bold','.cm-live-strong','Bold中文'],['link','.cm-live-link','Label中文']])await t.test(name,async sub=>{
    const r=await editor(sub,source);
    const grid=()=>r.page.evaluate(()=>[...document.querySelectorAll('.cm-table-row:not(.cm-table-separator)')].map(row=>({
      height:row.getBoundingClientRect().height,
      cells:[...row.querySelectorAll('.cm-table-cell')].map(cell=>{const rect=cell.getBoundingClientRect();return {width:rect.width,top:rect.top};})
    })));
    const assertGrid=async(before)=>{
      const rows=await grid();assert.equal(rows.length,2);
      for(const row of rows){assert.equal(row.cells.length,2,'nested syntax and composition must not split one visual cell into extra columns');assert.ok(Math.abs(row.cells[0].width-row.cells[1].width)<=1);assert.ok(Math.abs(row.cells[0].top-row.cells[1].top)<=1,'both cells stay on the same row');}
      if(before)rows.forEach((row,index)=>{assert.ok(Math.abs(row.height-before[index].height)<=1,'clicking or composing does not expand the row');row.cells.forEach((cell,column)=>assert.ok(Math.abs(cell.width-before[index].cells[column].width)<=1));});
      return rows;
    };
    const before=await assertGrid();
    const target=r.page.locator(`.cm-table-cell ${selector}`).filter({hasText:word}).first(),box=await target.boundingBox();
    await r.page.mouse.click(box.x+box.width/2,box.y+box.height/2);
    const clicked=await r.get(),start=source.indexOf(word);
    assert.ok(clicked.selection.anchor>=start&&clicked.selection.anchor<=start+word.length);
    await assertGrid(before);await assertFormattingHidden(r.page);
    const cdp=await r.page.context().newCDPSession(r.page);
    await cdp.send('Input.imeSetComposition',{text:'zhongwen',selectionStart:8,selectionEnd:8});
    await assertGrid(before);await assertFormattingHidden(r.page);
    await cdp.send('Input.imeSetComposition',{text:'中文',selectionStart:2,selectionEnd:2});
    await cdp.send('Input.insertText',{text:'中文'});
    const expected=source.slice(0,clicked.selection.anchor)+'中文'+source.slice(clicked.selection.anchor);
    await r.page.waitForFunction(expected=>window.acdianGetDocument().text===expected,expected);
    assert.equal((await r.get()).text,expected);await assertGrid(before);await assertFormattingHidden(r.page);
    await r.page.keyboard.press('Meta+z');assert.equal((await r.get()).text,source);
  });
});

test('slash menus default to English and translate their labels for Spanish and Chinese', async t => {
  const cases = [
    ['default English', {}, 'Insert block', 'Text', 'Heading 1', 'Quote', 'Todo', 'Code Block', 'Callout'],
    ['Spanish', { language: 'es' }, 'Insertar elemento', 'Texto', 'Título 1', 'Cita', 'Tareas', 'Bloque de código', 'Aviso'],
    ['Chinese', { language: 'zh-Hans' }, '插入元素', '文本', '一级标题', '引用', '待办事项', '代码块', '提示块']
  ];
  for (const [name, extra, title, text, heading, quote, todo, code, callout] of cases) {
    await t.test(name, async sub => {
      const r = await editor(sub, '', extra);
      await r.position(0);
      await r.page.keyboard.type('/');
      const menu = r.page.getByRole('listbox', { name: title, exact: true });
      await menu.waitFor({ state: 'visible' });
      assert.equal(await menu.locator('.cm-slash-title').innerText(), title);
      for (const [id, label] of [['text', text], ['h1', heading], ['quote', quote], ['todo', todo], ['code', code], ['callout', callout]]) {
        assert.equal(await menu.locator(`[data-command="${id}"] .cm-slash-label`).innerText(), label);
      }
      assert.equal((await r.get()).text, '/');
    });
  }
});

test('language metadata changes preserve source, selection, revision and undo history', async t => {
  const r = await editor(t, 'Alpha beta\n');
  await r.position(6);
  await r.page.keyboard.type('X');
  const before = await r.get();
  for (const language of ['es', 'zh-Hans', 'en']) {
    await r.page.evaluate(payload => window.acdianSetDocument(payload), { text: before.text, currentPath: before.currentPath, language });
    const state = await r.get();
    assert.equal(state.text, before.text);
    assert.deepEqual(state.selection, before.selection);
    assert.equal(state.revision, before.revision);
    assert.equal(state.messages.filter(message => message.type === 'change').length, before.messages.filter(message => message.type === 'change').length);
  }
  await r.page.keyboard.type('Y');
  assert.equal((await r.get()).text, 'Alpha XYbeta\n');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, 'Alpha beta\n');
  await r.page.keyboard.press('Meta+Shift+z');
  assert.equal((await r.get()).text, 'Alpha XYbeta\n');
});

test('draft title metadata preserves body editing and uses compact title spacing', async t => {
  const r = await editor(t, '', { draft: true, title: '' });
  await r.position(0);
  await r.page.keyboard.type('Draft body');
  const before = await r.get();
  await r.page.evaluate(payload => window.acdianSetDocument(payload), {
    currentPath: before.currentPath, title: 'My page', draft: true, language: 'es'
  });
  const after = await r.get();
  assert.equal(after.text, 'Draft body');
  assert.deepEqual(after.selection, before.selection);
  assert.equal(after.revision, before.revision);
  assert.equal(await r.page.evaluate(() => document.title), 'My page');
  assert.equal(await r.page.locator('.cm-content').evaluate(el => getComputedStyle(el).paddingTop), '12px');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, '');
  await r.page.evaluate(() => window.acdianSetDocument({ draft: false }));
  assert.equal(await r.page.locator('.cm-content').evaluate(el => getComputedStyle(el).paddingTop), '43px');
});

test('changing language refreshes an open slash menu without resetting its query or choice', async t => {
  const r = await editor(t, '');
  await r.position(0);
  await r.page.keyboard.type('/');
  const menu = r.page.locator('.cm-slash-menu');
  await menu.waitFor({ state: 'visible' });
  await r.page.keyboard.press('ArrowDown');
  const before = await r.get();
  await r.page.evaluate(payload => window.acdianSetDocument({ ...payload, language: 'es' }), { text: before.text, currentPath: before.currentPath });
  assert.equal(await menu.getAttribute('aria-label'), 'Insertar elemento');
  assert.equal(await menu.locator('[aria-selected="true"]').getAttribute('data-command'), 'h1');
  assert.equal(await menu.locator('[aria-selected="true"] .cm-slash-label').innerText(), 'Título 1');
  assert.deepEqual((await r.get()).selection, before.selection);
  assert.equal((await r.get()).revision, before.revision);
  await r.page.keyboard.press('Enter');
  assert.equal((await r.get()).text, '# ');
  await r.page.keyboard.press('Meta+z');
  assert.equal((await r.get()).text, '/');
});
