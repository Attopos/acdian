const { chromium } = require('playwright');
const path = require('path');
const assert = require('assert');

const node = (id, domain, level, status = 'new', extra = {}) => ({ id, title: extra.title || id, domain, level, pages: [], summary: extra.summary || '', keyPoints: [], status, updated: 1, ...extra });
const edge = (from, to, kind = 'requires', why = `${from} before ${to}`) => ({ id: from + (kind === 'related' ? '~' : '>') + to, from, to, kind, why, updated: 1 });
const roadmap = {
  component: 'roadmap', source: 'CS', version: 1, title: 'Test',
  flows: [{ id: 'call', title: 'Call', arrows: true }, { id: 'ship', title: 'Ship', arrows: true }],
  domains: [{ id: 'net', title: '网络', color: 'sky', order: 0, flow: 'call' }, { id: 'ai', title: 'AI', color: 'plum', order: 1, flow: 'call' }, { id: 'work', title: '实战', color: 'black', order: 2, flow: 'ship' }],
  nodes: [node('http', 'net', 0, 'learned', { title: 'HTTP 请求' }), node('nat', 'net', 0), node('proxy', 'net', 1, 'new', { title: '反向代理', summary: '站在网站那一边的代理' }), node('chain', 'net', 1), node('gfw', 'net', 2),
    node('key', 'ai', 0), node('switch', 'ai', 1), node('gateway', 'ai', 2, 'new', { summary: '带账号池的反向代理' }), node('alb', 'work', 3), node('lonely', 'ai', 1)],
  edges: [edge('http', 'proxy'), edge('proxy', 'gfw'), edge('chain', 'gfw'), edge('proxy', 'gateway'), edge('key', 'switch'), edge('key', 'gateway'), edge('switch', 'gateway'), edge('gateway', 'alb', 'applies'), edge('proxy', 'chain', 'related'), edge('nat', 'chain')],
};

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('file://' + path.resolve(__dirname, '../Resources/roadmap/roadmap.html'));
  const send = message => page.evaluate(m => window.acdianRoadmap.receive(m), message);
  const state = () => page.evaluate(() => window.acdianRoadmap.state());
  const posted = type => page.evaluate(t => (window.__posted || []).filter(m => m.type === t), type);
  await send({ type: 'load', roadmap, pages: [], mentions: [], theme: 'dark', language: 'zh-Hans', editable: true, platform: 'mac' });
  let checks = 0;
  const check = (condition, message) => { assert.ok(condition, message); checks++; };
  const same = (actual, expected, message) => { assert.deepStrictEqual(actual, expected, message); checks++; };

  check((await posted('ready')).length === 1, 'The page announces it is ready');
  let s = await state();
  const boxes = Object.fromEntries(s.nodes.map(n => [n.id, n]));
  const before = (a, b) => a.y < b.y - 1 || (Math.abs(a.y - b.y) < 1 && a.x < b.x);
  check(before(boxes.http, boxes.proxy) && before(boxes.proxy, boxes.gfw) && before(boxes.key, boxes.switch) && before(boxes.switch, boxes.gateway), 'Inside a stage, prerequisites come first in reading order');
  check(Math.min(boxes.key.y, boxes.switch.y) > Math.max(boxes.http.y, boxes.gfw.y), 'Stages of one flow stack top to bottom in order');
  check(boxes.alb.x > Math.max(...s.nodes.filter(n => n.id !== 'alb').map(n => n.x + n.w)), 'A second flow gets its own column');
  check(await page.evaluate(() => document.querySelectorAll('g.spine').length) === 1 && await page.evaluate(() => document.querySelectorAll('g.flow').length) === 2, 'Consecutive stages get one flow arrow and each flow a heading');
  for (const a of s.nodes) for (const b of s.nodes) if (a.id < b.id) check(a.x + a.w + 24 <= b.x || b.x + b.w + 24 <= a.x || a.y + a.h + 24 <= b.y || b.y + b.h + 24 <= a.y, `${a.id} and ${b.id} keep 24pt apart`);
  const again = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await again.goto('file://' + path.resolve(__dirname, '../Resources/roadmap/roadmap.html'));
  await again.evaluate(m => window.acdianRoadmap.receive(m), { type: 'load', roadmap, pages: [], mentions: [], theme: 'light', language: 'en', editable: false, platform: 'mac' });
  same((await again.evaluate(() => window.acdianRoadmap.state())).nodes, s.nodes, 'The layout is the same every time');
  await again.close();
  const phone = await browser.newPage({ viewport: { width: 393, height: 852 } });
  await phone.goto('file://' + path.resolve(__dirname, '../Resources/roadmap/roadmap.html'));
  await phone.evaluate(m => window.acdianRoadmap.receive(m), { type: 'load', roadmap, pages: [], mentions: [], theme: 'dark', language: 'zh-Hans', editable: false, platform: 'ios' });
  const small = await phone.evaluate(() => ({ nodes: window.acdianRoadmap.state().nodes, compact: document.getElementById('app').classList.contains('compact'), k: window.acdianRoadmap.state().k }));
  check(small.compact && new Set(small.nodes.map(n => Math.round(n.x))).size === 1 && small.k > 0.6, 'On a phone every stage is one readable column, wide enough to read without zooming');
  await phone.close();

  await page.evaluate(() => window.acdianRoadmap.focus('gateway'));
  s = await state();
  same(s.chain, ['http', 'key', 'proxy', 'switch'], 'Focusing lights every prerequisite, however far back');
  same(s.highlighted, ['alb', 'gateway', 'http', 'key', 'proxy', 'switch'], 'Direct successors light too, unrelated nodes do not');
  same(s.path, ['http', 'key', 'proxy', 'switch'], 'The learning path lists every prerequisite, earliest first');
  same(await page.$$eval('g.node.dim', nodes => nodes.map(n => n.dataset.id).sort()), ['chain', 'gfw', 'lonely', 'nat'], 'Everything else dims');
  check(await page.$eval('#panel', panel => panel.textContent.includes('proxy before gateway')), 'The panel gives the reason for each relation');

  await page.evaluate(() => window.acdianRoadmap.focus('proxy'));
  s = await state();
  same(s.highlighted, ['chain', 'gateway', 'gfw', 'http', 'proxy'], 'Related nodes light on focus');
  same(s.path, ['http'], 'The path of a node lists its own prerequisites');
  await page.waitForTimeout(400);
  check(await page.$eval('g.edge[data-id="proxy~chain"]', e => getComputedStyle(e).opacity === '1'), 'A related edge shows while one of its ends is focused');

  await page.keyboard.press('3');
  await page.waitForTimeout(600);
  check((await posted('save')).length === 0, 'Number keys no longer change anything');
  check(!(await page.$('#panel .segment')) && !(await page.$('g.node .dot')), 'No learning status is shown on nodes or in the panel');
  check((await page.$eval('#head-count', e => e.textContent)).includes('10 个节点'), 'The header counts nodes instead of progress');

  check(await page.evaluate(() => Math.abs(document.getElementById('panel').getBoundingClientRect().width / document.getElementById('app').getBoundingClientRect().width - 2 / 3) < 0.02), 'The detail panel takes two thirds of the view');
  check(await page.$$eval('#links g.link', links => links.length > 0 && links.every(l => l.querySelector('.line').getAttribute('d'))), 'Domains are joined by routed links');
  check(await page.$$eval('g.edge.cross:not(.lit):not(.flow)', edges => edges.every(e => getComputedStyle(e).opacity === '0')), 'Edges between domains stay hidden until they are lit');
  await page.keyboard.press('Escape');
  check((await state()).focus === null, 'Esc leaves focus');
  await page.waitForTimeout(400);
  check(await page.$eval('g.edge[data-id="proxy~chain"]', e => getComputedStyle(e).opacity === '0'), 'Related edges hide again');
  await page.evaluate(() => window.acdianRoadmap.search('代理'));
  same((await state()).matches, ['proxy', 'gateway'], 'Search matches titles first, then summaries');
  await page.evaluate(() => window.acdianRoadmap.search('HTTP'));
  same((await state()).matches, ['http'], 'Search ignores case and finds one node');
  await page.evaluate(() => window.acdianRoadmap.search('网络'));
  same((await state()).matches, ['http', 'nat', 'proxy', 'chain', 'gfw'], 'Search matches a domain name');
  await page.evaluate(() => window.acdianRoadmap.search(''));

  const lonely = await page.$eval('g.node[data-id="lonely"] .card', e => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  await page.mouse.dblclick(lonely[0], lonely[1]);
  check((await posted('openPage')).length === 0, 'A node without a page opens nothing');
  await page.evaluate(() => { window.acdianRoadmap.setZoom(0.3); });
  check((await state()).zoom === 'far', 'Zooming out switches to the far view');
  await page.evaluate(() => { window.acdianRoadmap.setZoom(1.6); });
  check((await state()).zoom === 'near', 'Zooming in switches to the near view');

  await page.evaluate(() => { window.acdianRoadmap.fit(); window.acdianRoadmap.setEditing(true); });
  check(await page.evaluate(() => window.acdianRoadmap.connect('alb', 'http')) === false, 'An edge that would close a loop is refused');
  check(await page.evaluate(() => window.acdianRoadmap.connect('nat', 'gfw')) === true, 'A new edge is accepted');
  await page.keyboard.press('Escape');
  await page.evaluate(() => window.acdianRoadmap.flush());
  const edits = (await posted('save')).pop();
  check(edits.edges.length === 1 && edits.edges[0].id === 'nat>gfw', 'The new edge is posted');
  await page.evaluate(() => { window.acdianRoadmap.undo(); window.acdianRoadmap.flush(); });
  const undone = (await posted('save')).pop();
  check(undone.removed['edge:nat>gfw'] > 0, 'Undo posts the deletion');

  await page.keyboard.press('Escape');
  const where = () => page.evaluate(() => { const r = document.querySelector('g.node').getBoundingClientRect(); return [Math.round(r.x), Math.round(r.y)]; });
  await page.mouse.move(500, 400);
  await page.keyboard.down('Control'); await page.mouse.wheel(0, -30); await page.keyboard.up('Control');
  await page.mouse.wheel(40, 30);
  const lifted = await page.evaluate(() => [document.getElementById('app').classList.contains('moving'), document.getElementById('canvas').style.transform]);
  check(lifted[0] && /scale/.test(lifted[1]), 'Scrolling and pinching move the drawn canvas instead of redrawing it');
  const during = await where();
  await page.waitForTimeout(300);
  check(!(await page.evaluate(() => document.getElementById('app').classList.contains('moving') || document.getElementById('canvas').style.transform)), 'The canvas is redrawn once the gesture ends');
  same(await where(), during, 'Nodes stay where they were when the canvas is redrawn');

  same(errors, [], 'No script errors');
  await browser.close();
  console.log(`Roadmap page tests passed: ${checks} checks`);
})().catch(error => { console.error(error); process.exit(1); });
