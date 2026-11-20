(() => {
'use strict';
const d3 = window.d3;
const $ = id => document.getElementById(id);
const app = $('app'), svg = d3.select('#canvas'), world = d3.select('#world');
const post = message => { try { window.webkit.messageHandlers.acdian.postMessage(message); } catch { (window.__posted ||= []).push(message); } };
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const dur = ms => reduced.matches ? 0 : ms;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fold = s => String(s ?? '').normalize('NFKC').toLowerCase();
const now = () => Math.floor(Date.now() / 1000);

const NODE_H = 44, COL_GAP = 40, ROW_GAP = 80, PAD_X = 20, PAD_TOP = 56, PAD_BOTTOM = 24, REGION_GAP = 104, ARC_ROOM = 44;
const PER_ROW = 4, IN_GAP = 40, BAND_GAP = 76, FLOW_HEAD = 76, COLUMN_GAP = 220, GUTTER = 40;
const FAR = 0.5, NEAR = 1.3;
const panelSpace = () => $('panel').getBoundingClientRect().width + 12;
const LEVELS = ['入门', '基础', '进阶', '实战'];
const KIND_NAMES = { requires: '先学', applies: '应用', related: '相关' };
const COLORS = ['pink', 'black', 'rose', 'plum', 'amber', 'teal', 'sky', 'graphite'];

const STRINGS = {
  en: { '入门': 'Intro', '基础': 'Basics', '进阶': 'Advanced', '实战': 'In practice', '先学': 'Learn first', '应用': 'Applied in', '相关': 'Related',
    '%1 个节点 · %2 篇已写成页面': '%1 nodes · %2 with pages', '已写成页面': 'Has a page', '搜索节点': 'Search nodes', '图例': 'Legend', '先学 A 再学 B': 'Learn A before B', 'B 是 A 的实际应用': 'B applies A', '相关，聚焦时显示': 'Related, shown on focus', '待写': 'To write', '还没有页面': 'No page yet',
    '要点': 'Key points', '页面': 'Pages', '学完可以继续': 'Next', '学习路径': 'Learning path', '原理图': 'Figure', '页面互链': 'Page links', '适合窗口': 'Fit window', '放大': 'Zoom in', '缩小': 'Zoom out', '编辑': 'Edit', '完成': 'Done',
    '没有前置，可以从这里开始。': 'No prerequisites. Start here.', '这个节点还没有页面，摘要是通用常识。': 'This node has no page yet; the summary is general knowledge.', '页面不存在': 'Page not found', '用到的概念': 'Uses', '在这里用到': 'Used in',
    '这张路线图还是空的': 'This roadmap is empty', '打开「编辑」，双击空白处新建节点。': 'Turn on Edit and double-click the canvas to add a node.', '这样连会成环：%1 已经排在 %2 后面。': 'That would make a loop: %1 already comes after %2.', '未挂靠的页面': 'Unattached pages', '所有页面都已挂上': 'Every page is attached', '新节点': 'New node', '为什么有这条关系？一句话。': 'Why does this relation exist? One sentence.', '删除': 'Delete', '节点标题': 'Node title', '新建页面': 'New page', '已撤销': 'Undone', '没有可撤销的操作': 'Nothing to undo', '这两个节点之间已经有关系了。': 'These two nodes are already related.', '把页面拖到节点上挂靠': 'Drag a page onto a node to attach it', '目标': 'Goal', '移除节点': 'Remove node', '取消挂靠': 'Detach' },
  es: { '入门': 'Inicio', '基础': 'Bases', '进阶': 'Avanzado', '实战': 'En práctica', '先学': 'Aprende antes', '应用': 'Se aplica en', '相关': 'Relacionado',
    '%1 个节点 · %2 篇已写成页面': '%1 nodos · %2 con página', '已写成页面': 'Con página', '搜索节点': 'Buscar nodos', '图例': 'Leyenda', '先学 A 再学 B': 'Aprende A antes que B', 'B 是 A 的实际应用': 'B aplica A', '相关，聚焦时显示': 'Relacionado, visible al enfocar', '待写': 'Por escribir', '还没有页面': 'Aún sin página',
    '要点': 'Puntos clave', '页面': 'Páginas', '学完可以继续': 'Después', '学习路径': 'Ruta de aprendizaje', '原理图': 'Figura', '页面互链': 'Enlaces entre páginas', '适合窗口': 'Ajustar a la ventana', '放大': 'Acercar', '缩小': 'Alejar', '编辑': 'Editar', '完成': 'Listo',
    '没有前置，可以从这里开始。': 'Sin requisitos. Empieza aquí.', '这个节点还没有页面，摘要是通用常识。': 'Este nodo aún no tiene página; el resumen es conocimiento general.', '页面不存在': 'Página no encontrada', '用到的概念': 'Usa', '在这里用到': 'Se usa en',
    '这张路线图还是空的': 'Este mapa está vacío', '打开「编辑」，双击空白处新建节点。': 'Activa Editar y haz doble clic en el lienzo para añadir un nodo.', '这样连会成环：%1 已经排在 %2 后面。': 'Eso crearía un ciclo: %1 ya va después de %2.', '未挂靠的页面': 'Páginas sin asignar', '所有页面都已挂上': 'Todas las páginas están asignadas', '新节点': 'Nodo nuevo', '为什么有这条关系？一句话。': '¿Por qué existe esta relación? Una frase.', '删除': 'Eliminar', '节点标题': 'Título del nodo', '新建页面': 'Página nueva', '已撤销': 'Deshecho', '没有可撤销的操作': 'Nada que deshacer', '这两个节点之间已经有关系了。': 'Estos dos nodos ya están relacionados.', '把页面拖到节点上挂靠': 'Arrastra una página a un nodo para asignarla', '目标': 'Meta', '移除节点': 'Quitar nodo', '取消挂靠': 'Desvincular' },
};
const T = (key, ...args) => { let text = STRINGS[S.language]?.[key] ?? key; args.forEach((value, i) => { text = text.replace('%' + (i + 1), value); }); return text; };

const ICONS = {
  'activity': '<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2" />',
  'app-window': '<rect x="2" y="4" width="20" height="16" rx="2" /><path d="M10 4v4" /><path d="M2 8h20" /><path d="M6 4v4" />',
  'braces': '<path d="M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5c0 1.1.9 2 2 2h1" /><path d="M16 21h1a2 2 0 0 0 2-2v-5c0-1.1.9-2 2-2a2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1" />',
  'check': '<path d="M20 6 9 17l-5-5" />',
  'chevron-down': '<path d="m6 9 6 6 6-6" />',
  'chevron-right': '<path d="m9 18 6-6-6-6" />',
  'circle-dashed': '<path d="M10.1 2.182a10 10 0 0 1 3.8 0" /><path d="M13.9 21.818a10 10 0 0 1-3.8 0" /><path d="M17.609 3.721a10 10 0 0 1 2.69 2.7" /><path d="M2.182 13.9a10 10 0 0 1 0-3.8" /><path d="M20.279 17.609a10 10 0 0 1-2.7 2.69" /><path d="M21.818 10.1a10 10 0 0 1 0 3.8" /><path d="M3.721 6.391a10 10 0 0 1 2.7-2.69" /><path d="M6.391 20.279a10 10 0 0 1-2.69-2.7" />',
  'circle': '<circle cx="12" cy="12" r="10" />',
  'cloud': '<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z" />',
  'cpu': '<rect width="16" height="16" x="4" y="4" rx="2" /><rect width="6" height="6" x="9" y="9" rx="1" /><path d="M15 2v2" /><path d="M15 20v2" /><path d="M2 15h2" /><path d="M2 9h2" /><path d="M20 15h2" /><path d="M20 9h2" /><path d="M9 2v2" /><path d="M9 20v2" />',
  'database': '<ellipse cx="12" cy="5" rx="9" ry="3" /><path d="M3 5V19A9 3 0 0 0 21 19V5" /><path d="M3 12A9 3 0 0 0 21 12" />',
  'file-text': '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z" /><path d="M14 2v4a2 2 0 0 0 2 2h4" /><path d="M10 9H8" /><path d="M16 13H8" /><path d="M16 17H8" />',
  'gauge': '<path d="m12 14 4-4" /><path d="M3.34 19a10 10 0 1 1 17.32 0" />',
  'layers': '<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z" /><path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65" /><path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65" />',
  'link-2': '<path d="M9 17H7A5 5 0 0 1 7 7h2" /><path d="M15 7h2a5 5 0 1 1 0 10h-2" /><line x1="8" x2="16" y1="12" y2="12" />',
  laptop: '<path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16" />',
  receipt: '<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z" /><path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8" /><path d="M12 17.5v-11" />',
  package: '<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z" /><path d="M12 22V12" /><path d="m3.3 7 7.703 4.734a2 2 0 0 0 1.994 0L20.7 7" /><path d="m7.5 4.27 9 5.15" />',
  'chart-line': '<path d="M3 3v16a2 2 0 0 0 2 2h16" /><path d="m19 9-5 5-4-4-3 3" />',
  'list-checks': '<path d="m3 17 2 2 4-4" /><path d="m3 7 2 2 4-4" /><path d="M13 6h8" /><path d="M13 12h8" /><path d="M13 18h8" />',
  'log-in': '<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" /><polyline points="10 17 15 12 10 7" /><line x1="15" x2="3" y1="12" y2="12" />',
  'log-out': '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" /><polyline points="16 17 21 12 16 7" /><line x1="21" x2="9" y1="12" y2="12" />',
  'maximize': '<path d="M8 3H5a2 2 0 0 0-2 2v3" /><path d="M21 8V5a2 2 0 0 0-2-2h-3" /><path d="M3 16v3a2 2 0 0 0 2 2h3" /><path d="M16 21h3a2 2 0 0 0 2-2v-3" />',
  'minus': '<path d="M5 12h14" />',
  'network': '<rect x="16" y="16" width="6" height="6" rx="1" /><rect x="2" y="16" width="6" height="6" rx="1" /><rect x="9" y="2" width="6" height="6" rx="1" /><path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3" /><path d="M12 12V8" />',
  'pencil': '<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z" /><path d="m15 5 4 4" />',
  'plus': '<path d="M5 12h14" /><path d="M12 5v14" />',
  'pyramid': '<path d="M2.5 16.88a1 1 0 0 1-.32-1.43l9-13.02a1 1 0 0 1 1.64 0l9 13.01a1 1 0 0 1-.32 1.44l-8.51 4.86a2 2 0 0 1-1.98 0Z" /><path d="M12 2v20" />',
  'route': '<circle cx="6" cy="19" r="3" /><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15" /><circle cx="18" cy="5" r="3" />',
  'search': '<circle cx="11" cy="11" r="8" /><path d="m21 21-4.3-4.3" />',
  'shield-check': '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" /><path d="m9 12 2 2 4-4" />',
  'sparkles': '<path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z" /><path d="M20 3v4" /><path d="M22 5h-4" /><path d="M4 17v2" /><path d="M5 18H3" />',
  'workflow': '<rect width="8" height="8" x="3" y="3" rx="2" /><path d="M7 11v4a2 2 0 0 0 2 2h4" /><rect width="8" height="8" x="13" y="13" rx="2" />',
  'x': '<path d="M18 6 6 18" /><path d="m6 6 12 12" />',
};
const GLYPH_ICONS = { network: 'network', spark: 'sparkles', pulse: 'activity', cloud: 'cloud', window: 'app-window', database: 'database', prism: 'pyramid', nodes: 'workflow', chip: 'cpu', gauge: 'gauge', braces: 'braces', shield: 'shield-check', layers: 'layers', dot: 'circle', chart: 'chart-line', checks: 'list-checks' };
const glyph = name => ICONS[GLYPH_ICONS[name] || name] || ICONS.circle;
const ic = (name, cls = '') => `<svg viewBox="0 0 24 24" class="ic${cls ? ' ' + cls : ''}" aria-hidden="true">${ICONS[name] || ICONS.circle}</svg>`;
const glyphSVG = name => `<svg viewBox="0 0 24 24" class="ic glyph" aria-hidden="true">${glyph(name)}</svg>`;

const S = { doc: null, pages: new Map(), mentions: [], theme: 'dark', language: 'zh-Hans', editable: false, platform: 'mac', nodes: [], edges: [], byId: new Map(), domains: [], layout: null,
  zoom: 'mid', focus: null, query: '', matches: [], showMentions: false, editing: false, t: d3.zoomIdentity, chain: new Set(), highlighted: new Set(), dirtyNodes: new Set(), dirtyEdges: new Set(), removed: {}, undo: [], legendClosed: true, loaded: false };

// ---------- model ----------
const tint = color => `var(--rm-${COLORS.includes(color) && color !== 'pink' ? color : 'graphite'})`;
const directed = kind => kind === 'requires' || kind === 'applies';
function index() {
  const doc = S.doc;
  S.domains = [...(doc.domains || [])].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  const known = new Set(S.domains.map(d => d.id));
  S.nodes = (doc.nodes || []).filter(n => n && n.id).map((d, i) => ({ id: d.id, d, i, x: 0, y: 0, w: 0, h: NODE_H }));
  for (const node of S.nodes) if (!known.has(node.d.domain)) { node.d.domain = S.domains[0]?.id; }
  S.byId = new Map(S.nodes.map(n => [n.id, n]));
  S.edges = (doc.edges || []).filter(e => e && S.byId.has(e.from) && S.byId.has(e.to) && e.from !== e.to).map(d => ({ id: d.id, d, a: S.byId.get(d.from), b: S.byId.get(d.to) }));
  S.ins = new Map(S.nodes.map(n => [n.id, []])); S.outs = new Map(S.nodes.map(n => [n.id, []]));
  for (const edge of S.edges) { S.outs.get(edge.a.id).push(edge); S.ins.get(edge.b.id).push(edge); }
}
function ancestors(id) {
  const seen = new Set(), stack = [id];
  while (stack.length) for (const edge of S.ins.get(stack.pop()) || []) if (directed(edge.d.kind) && !seen.has(edge.a.id) && edge.a.id !== id) { seen.add(edge.a.id); stack.push(edge.a.id); }
  return seen;
}
function reaches(from, to, kinds = ['requires']) {
  const seen = new Set([from]), stack = [from];
  while (stack.length) { const at = stack.pop(); if (at === to) return true; for (const edge of S.outs.get(at) || []) if (kinds.includes(edge.d.kind) && !seen.has(edge.b.id)) { seen.add(edge.b.id); stack.push(edge.b.id); } }
  return false;
}
function distances(id, within) {
  const memo = new Map([[id, 0]]), visiting = new Set();
  const walk = at => {
    if (memo.has(at)) return memo.get(at);
    if (visiting.has(at)) return 0;
    visiting.add(at);
    let best = 0;
    for (const edge of S.outs.get(at) || []) if (directed(edge.d.kind) && (edge.b.id === id || within.has(edge.b.id))) best = Math.max(best, walk(edge.b.id) + 1);
    visiting.delete(at); memo.set(at, best); return best;
  };
  for (const other of within) walk(other);
  return memo;
}
function learningPath(id) {
  const chain = ancestors(id), dist = distances(id, chain);
  return [...chain].map(other => S.byId.get(other))
    .sort((a, b) => dist.get(b.id) - dist.get(a.id) || a.i - b.i)
    .map(node => {
      const via = (S.outs.get(node.id) || []).filter(edge => directed(edge.d.kind) && (edge.b.id === id || chain.has(edge.b.id))).sort((a, b) => dist.get(a.b.id) - dist.get(b.b.id))[0];
      return { id: node.id, why: via?.d.why || '', toward: via?.b.id };
    });
}

// ---------- layout ----------
let measureContext;
function textWidth(text, font) { measureContext ||= document.createElement('canvas').getContext('2d'); measureContext.font = font; return measureContext.measureText(text).width; }
const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", sans-serif';
function wrap(text, width, font) {
  const lines = []; let line = '';
  for (const token of String(text).match(/[A-Za-z0-9_.\-/:+#@%]+|\s+|./gu) || []) {
    if (textWidth(line + token, font) > width && line.trim()) { lines.push(line.trimEnd()); line = /^\s+$/.test(token) ? '' : token; }
    else line += token;
  }
  if (line.trim()) lines.push(line.trimEnd());
  for (let i = 1; i < lines.length; i++) if (/^[，。、；：！？）」』》]/.test(lines[i]) && lines[i - 1].length > 1) { lines[i] = lines[i - 1].slice(-1) + lines[i]; lines[i - 1] = lines[i - 1].slice(0, -1); }
  return lines;
}
function layout() {
  const titleFont = `550 14px ${FONT}`;
  const widest = Math.max(96, ...S.nodes.map(n => Math.max(textWidth(n.d.title || '', titleFont), textWidth(n.d.subtitle || '', `400 11.5px ${FONT}`))));
  const W = Math.round(Math.min(320, Math.max(148, widest + 56)));
  const groups = S.domains.map(domain => ({ domain, nodes: S.nodes.filter(n => n.d.domain === domain.id) })).filter(g => g.nodes.length || S.editing);
  const flows = S.doc.flows || [];
  const lines = [...flows.map(flow => ({ flow, groups: groups.filter(g => g.domain.flow === flow.id) })), { flow: null, groups: groups.filter(g => !flows.some(f => f.id === g.domain.flow)) }].filter(line => line.groups.length);
  const columns = lines.length > 1 ? [lines.slice(0, 1), lines.slice(1)] : [lines];
  const bandW = PER_ROW * W + (PER_ROW - 1) * COL_GAP + 2 * PAD_X, regions = [], heads = [], spine = [];
  columns.forEach((stack, col) => {
    const x = col * (bandW + COLUMN_GAP); let y = 0;
    stack.forEach((line, li) => {
      if (li) y += BAND_GAP;
      if (line.flow) { heads.push({ id: line.flow.id, flow: line.flow, x, y }); y += FLOW_HEAD; }
      const arrows = line.flow?.arrows !== false && !!line.flow;
      line.groups.forEach((group, step) => {
        const pending = new Set(group.nodes), ordered = [];
        while (pending.size) {
          const ready = [...pending].find(n => ![...(S.ins.get(n.id) || [])].some(e => directed(e.d.kind) && pending.has(e.a))) || [...pending][0];
          ordered.push(ready); pending.delete(ready);
        }
        group.nodes = ordered;
        const count = group.nodes.length, rows = Math.max(1, Math.ceil(count / PER_ROW));
        const h = PAD_TOP + rows * NODE_H + (rows - 1) * IN_GAP + PAD_BOTTOM;
        const region = { id: group.domain.id, domain: group.domain, nodes: group.nodes, x, y, w: bandW, h, col, flow: line.flow?.id || '', step: arrows ? step + 1 : 0 };
        if (step && arrows) spine.push({ key: regions[regions.length - 1].id + '>' + region.id, from: regions[regions.length - 1], to: region });
        regions.push(region);
        group.nodes.forEach((node, i) => {
          const row = Math.floor(i / PER_ROW), k = i % PER_ROW;
          node.w = W; node.col = k;
          node.gx = x + PAD_X + k * (W + COL_GAP);
          node.gy = y + PAD_TOP + row * (NODE_H + IN_GAP);
        });
        y += h + BAND_GAP;
      });
      y -= BAND_GAP;
    });
  });
  const summaryFont = `400 9px ${FONT}`;
  for (const node of S.nodes) {
    node.w ||= W; node.gx ??= 0; node.gy ??= 0;
    node.x = Number.isFinite(node.d.x) ? node.d.x : node.gx; node.y = Number.isFinite(node.d.y) ? node.d.y : node.gy;
    node.lines = wrap(node.d.summary || '', node.w - 24, summaryFont).slice(0, 6);
    node.hNear = node.lines.length ? NODE_H + node.lines.length * 12.5 + 8 : NODE_H;
  }
  for (const region of regions) {
    for (const node of region.nodes) {
      const left = Math.min(region.x, node.x - PAD_X), top = Math.min(region.y, node.y - PAD_TOP);
      region.w = Math.max(region.x + region.w, node.x + node.w + PAD_X) - left; region.h = Math.max(region.y + region.h, node.y + NODE_H + PAD_BOTTOM) - top; region.x = left; region.y = top;
    }
    region.tint = tint(region.domain.color);
  }
  const x0 = Math.min(0, ...regions.map(r => r.x)), y0 = Math.min(0, ...regions.map(r => r.y), ...heads.map(h => h.y));
  const bounds = { x: x0, y: y0, w: Math.max(1, ...regions.map(r => r.x + r.w)) - x0, h: Math.max(1, ...regions.map(r => r.y + r.h)) - y0 };
  S.layout = { regions, bounds, W, heads, spine };
  routeAll();
}

// ---------- edge routing ----------
function blocked(points, skip, pad = 5) {
  for (const node of S.nodes) {
    if (skip.has(node.id)) continue;
    const x0 = node.x - pad, y0 = node.y - pad, x1 = node.x + node.w + pad, y1 = node.y + NODE_H + pad;
    for (const [x, y] of points) if (x > x0 && x < x1 && y > y0 && y < y1) return true;
  }
  return false;
}
const cubic = (p0, p1, p2, p3, n = 28) => Array.from({ length: n + 1 }, (_, i) => { const t = i / n, u = 1 - t; return [u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0], u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]]; });
const segment = (a, b, n = 18) => Array.from({ length: n + 1 }, (_, i) => [a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n]);
function rounded(points, radius = 16) {
  const clean = points.filter((p, i) => !i || Math.hypot(p[0] - points[i - 1][0], p[1] - points[i - 1][1]) > 0.5);
  let d = `M${clean[0][0]},${clean[0][1]}`;
  for (let i = 1; i < clean.length - 1; i++) {
    const [px, py] = clean[i - 1], [cx, cy] = clean[i], [nx, ny] = clean[i + 1];
    const inLen = Math.hypot(cx - px, cy - py), outLen = Math.hypot(nx - cx, ny - cy), r = Math.min(radius, inLen / 2, outLen / 2);
    if (r < 1) { d += `L${cx},${cy}`; continue; }
    d += `L${cx - (cx - px) / inLen * r},${cy - (cy - py) / inLen * r}Q${cx},${cy} ${cx + (nx - cx) / outLen * r},${cy + (ny - cy) / outLen * r}`;
  }
  const last = clean[clean.length - 1];
  return d + `L${last[0]},${last[1]}`;
}
const spread = n => (n % 2 ? 1 : -1) * Math.ceil(n / 2) * 6;
function routeAll() {
  const gutters = new Map(), lanes = new Map(), ports = new Map();
  const take = (map, key) => { const n = map.get(key) || 0; map.set(key, n + 1); return spread(n); };
  const laneYs = [...new Set(S.nodes.flatMap(n => [Math.round(n.y - 14), Math.round(n.y + NODE_H + 14)]))];
  const order = [...S.edges].sort((a, b) => (a.a.d.domain !== a.b.d.domain) - (b.a.d.domain !== b.b.d.domain) || (a.d.kind === 'related') - (b.d.kind === 'related'));
  for (const edge of order) {
    let a = edge.a, b = edge.b;
    const arrow = directed(edge.d.kind), HEAD = arrow ? 7 : 0;
    if (!arrow && (a.x > b.x || (Math.abs(a.x - b.x) < 1 && a.y > b.y))) [a, b] = [b, a];
    const skip = new Set([a.id, b.id]), ay = a.y + NODE_H / 2, by = b.y + NODE_H / 2;
    edge.head = null;
    if (Math.abs(a.x - b.x) < a.w * 0.6) {
      const down = b.y > a.y, x = a.x + a.w / 2, between = S.nodes.some(n => n !== a && n !== b && Math.abs(n.x - a.x) < a.w * 0.6 && n.y > Math.min(a.y, b.y) && n.y < Math.max(a.y, b.y));
      if (!between) {
        const shift = take(ports, `${edge.a.id < edge.b.id ? edge.a.id + edge.b.id : edge.b.id + edge.a.id}`) * 2;
        const y0 = down ? a.y + NODE_H : a.y, y1 = down ? b.y : b.y + NODE_H, tip = y1 - (down ? 1 : -1) * 1;
        edge.path = `M${x + shift},${y0}L${x + shift},${y1 - (down ? HEAD : -HEAD)}`;
        if (arrow) edge.head = { x: x + shift, y: tip, angle: down ? 90 : -90 };
        edge.mid = [x + shift, (y0 + y1) / 2];
      } else {
        const span = Math.abs(by - ay), bulge = Math.min(ARC_ROOM - 20, 12 + span * 0.02) + take(gutters, 'arc' + Math.round(a.x)) * 0.8;
        const x0 = a.x + a.w, yA = ay + 8, yB = by - 8 * Math.sign(by - ay);
        edge.path = `M${x0},${yA}C${x0 + bulge * 1.5},${yA} ${x0 + bulge * 1.5},${yB} ${x0 + HEAD},${yB}`;
        if (arrow) edge.head = { x: x0 + 1, y: yB, angle: 180 };
        edge.mid = [x0 + bulge * 1.1, (yA + yB) / 2];
      }
      continue;
    }
    const s = b.x > a.x ? 1 : -1, x0 = s > 0 ? a.x + a.w : a.x, x1 = s > 0 ? b.x : b.x + b.w, dx = Math.abs(x1 - x0);
    const end = [x1 - s * HEAD, by];
    if (arrow) edge.head = { x: x1 - s, y: by, angle: s > 0 ? 0 : 180 };
    const pull = Math.max(22, Math.min(dx * 0.5, 120));
    const direct = [[x0, ay], [x0 + s * pull, ay], [x1 - s * pull, by], end];
    if (!blocked(cubic(...direct), skip)) { edge.path = `M${x0},${ay}C${direct[1]} ${direct[2]} ${end}`; edge.mid = cubic(...direct, 2)[1]; continue; }
    const g0 = x0 + s * COL_GAP / 2, g1 = x1 - s * COL_GAP / 2;
    let best = null;
    for (const ly of laneYs) {
      const points = [[x0, ay], [g0, ay], [g0, ly], [g1, ly], [g1, by], end];
      const hit = blocked([...segment(points[1], points[2]), ...segment(points[2], points[3], 60), ...segment(points[3], points[4])], skip, 3);
      const cost = Math.abs(ay - ly) + Math.abs(by - ly) + (hit ? 1e5 : 0) + (lanes.get(ly) || 0) * 9;
      if (!best || cost < best.cost) best = { cost, ly };
    }
    const ly = best.ly + take(lanes, best.ly), ga = g0 + take(gutters, Math.round(g0)), gb = g1 + take(gutters, Math.round(g1));
    edge.path = rounded([[x0, ay], [ga, ay], [ga, ly], [gb, ly], [gb, by], end]);
    edge.mid = [(ga + gb) / 2, ly];
  }
  const pairs = new Map();
  for (const edge of S.edges) {
    if (!directed(edge.d.kind) || edge.a.d.domain === edge.b.d.domain) continue;
    const key = edge.a.d.domain + '>' + edge.b.d.domain; if (!pairs.has(key)) pairs.set(key, []); pairs.get(key).push(edge);
  }
  const regions = S.layout.regions, tracks = new Map();
  const track = (key, outward = 0) => { const n = tracks.get(key) || 0; tracks.set(key, n + 1); return outward ? outward * n * 10 : (n % 2 ? 1 : -1) * Math.ceil(n / 2) * 10; };
  const cx = r => r.x + r.w / 2, cy = r => r.y + r.h / 2;
  const through = (from, to) => {
    if (from.col !== to.col) {
      const right = to.col > from.col, x = (right ? from.x + from.w : from.x) + (right ? 1 : -1) * COLUMN_GAP / 2 + track('mid', 0);
      return [[right ? from.x + from.w : from.x, cy(from)], [x, cy(from)], [x, cy(to)], [right ? to.x : to.x + to.w, cy(to)]];
    }
    const down = to.y > from.y, between = regions.some(r => r !== from && r !== to && r.col === from.col && r.y > Math.min(from.y, to.y) && r.y < Math.max(from.y, to.y));
    if (!between) { const x = cx(from) + (down ? -14 : 14); return [[x, down ? from.y + from.h : from.y], [x, down ? to.y : to.y + to.h]]; }
    const side = down ? -1 : 1, edge = side < 0 ? from.x : from.x + from.w, x = edge + side * GUTTER + track('side' + from.col + side, side);
    return [[edge, cy(from) + side * -6], [x, cy(from) + side * -6], [x, cy(to) + side * 6], [edge, cy(to) + side * 6]];
  };
  const span = key => { const [from, to] = key.split('>').map(id => regions.find(r => r.id === id)); return from && to ? Math.abs(cy(to) - cy(from)) + (from.col !== to.col) * 1e5 : 0; };
  S.layout.links = [...pairs].sort((a, b) => span(a[0]) - span(b[0])).map(([key, edges]) => {
    const [from, to] = key.split('>').map(id => regions.find(r => r.id === id)); if (!from || !to || from === to) return null;
    const points = through(from, to), last = points[points.length - 1], before = points[points.length - 2];
    const length = Math.hypot(last[0] - before[0], last[1] - before[1]) || 1, ux = (last[0] - before[0]) / length, uy = (last[1] - before[1]) / length;
    const first = points[0], after = points[1], lead = Math.hypot(after[0] - first[0], after[1] - first[1]) || 1;
    const body = [[first[0] + (after[0] - first[0]) / lead * 3, first[1] + (after[1] - first[1]) / lead * 3], ...points.slice(1, -1), [last[0] - ux * 9, last[1] - uy * 9]];
    return { key, from, to, edges, count: edges.length, tint: from.tint, path: rounded(body, 14), q: [last[0] - ux * 2, last[1] - uy * 2], angle: Math.atan2(uy, ux) * 180 / Math.PI, mid: points[Math.floor((points.length - 1) / 2)] };
  }).filter(Boolean);
  S.layout.mentions = (S.mentions || []).map(([from, to]) => {
    const a = S.byId.get(from), b = S.byId.get(to); if (!a || !b || a === b) return null;
    const p = [a.x + a.w / 2, a.y + NODE_H / 2], q = [b.x + b.w / 2, b.y + NODE_H / 2], bend = Math.hypot(q[0] - p[0], q[1] - p[1]) * 0.12;
    const nx = -(q[1] - p[1]), ny = q[0] - p[0], len = Math.hypot(nx, ny) || 1;
    return { key: from + '|' + to, path: `M${p}Q${(p[0] + q[0]) / 2 + nx / len * bend},${(p[1] + q[1]) / 2 + ny / len * bend} ${q}` };
  }).filter(Boolean);
}

// ---------- drawing ----------
const headPath = 'M0,0L-7.5,-3.6L-7.5,3.6Z';
function draw(animate = false) {
  const { regions, links, mentions } = S.layout, t = animate ? dur(240) : 0;
  const move = selection => t ? selection.transition().duration(t).ease(d3.easeCubicOut) : selection;

  const region = d3.select('#regions').selectAll('g.region').data(regions, d => d.id).join(enter => {
    const g = enter.append('g').attr('class', 'region');
    g.append('rect').attr('rx', 18);
    const label = g.append('g').attr('class', 'label');
    label.append('circle').attr('class', 'badge').attr('cx', 11).attr('cy', -5).attr('r', 11);
    label.append('text').attr('class', 'step').attr('x', 11).attr('y', -5);
    label.append('g').attr('class', 'glyph');
    label.append('text').attr('class', 'name');
    const far = g.append('g').attr('class', 'far');
    far.append('text').attr('class', 'name');
    return g;
  });
  region.style('--tint', d => d.tint);
  move(region.select('rect')).attr('x', d => d.x).attr('y', d => d.y).attr('width', d => d.w).attr('height', d => d.h);
  move(region.select('.label')).attr('transform', d => `translate(${d.x + PAD_X},${d.y + 30})`);
  region.select('.label .glyph').html(d => glyph(d.domain.glyph)).attr('transform', d => `translate(${d.step ? 32 : 0},-13)scale(.6667)`);
  region.select('.label .badge').attr('display', d => d.step ? null : 'none');
  region.select('.label .step').text(d => d.step || '');
  region.select('.label .name').attr('x', d => d.step ? 56 : 24);
  region.select('.label .name').each(function (d) { d3.select(this).html(`${esc(d.domain.title)}${d.domain.subtitle ? `<tspan class="sub" dx="8">${esc(d.domain.subtitle)}</tspan>` : ''}`); });

  move(region.select('.far')).attr('transform', d => `translate(${d.x + d.w / 2},${d.y + d.h / 2 + 14})`);
  region.select('.far .name').text(d => (d.step ? d.step + '  ' : '') + d.domain.title);

  const flowHead = d3.select('#regions').selectAll('g.flow').data(S.layout.heads || [], d => d.id).join(enter => {
    const g = enter.append('g').attr('class', 'flow');
    g.append('text').attr('class', 'title'); g.append('text').attr('class', 'sub');
    return g;
  });
  move(flowHead).attr('transform', d => `translate(${d.x + 4},${d.y + 34})`);
  flowHead.select('.title').text(d => d.flow.title);
  flowHead.select('.sub').attr('y', 24).text(d => d.flow.subtitle || '');
  const spine = d3.select('#regions').selectAll('g.spine').data(S.layout.spine || [], d => d.key).join(enter => {
    const g = enter.append('g').attr('class', 'spine');
    g.append('path').attr('class', 'shaft'); g.append('path').attr('class', 'tip');
    return g;
  });
  spine.style('--tint', d => d.to.tint);
  spine.select('.shaft').attr('d', d => `M${d.from.x + PAD_X + 11},${d.from.y + d.from.h + 8}V${d.to.y - 16}`);
  spine.select('.tip').attr('d', d => { const x = d.from.x + PAD_X + 11, y = d.to.y - 6; return `M${x},${y}L${x - 7},${y - 11}L${x + 7},${y - 11}Z`; });

  d3.select('#links').selectAll('g.link').data(links, d => d.key).join(enter => {
    const g = enter.append('g').attr('class', 'link');
    g.append('path').attr('class', 'line'); g.append('path').attr('class', 'tip').attr('d', 'M0,0L-10,-5L-10,5Z'); g.append('path').attr('class', 'hit');
    g.on('pointerenter', (event, d) => linkHover(d, event)).on('pointermove', (event, d) => linkHover(d, event)).on('pointerleave', () => linkHover(null));
    return g;
  }).attr('data-key', d => d.key).style('--tint', d => d.tint).each(function (d) {
    const g = d3.select(this);
    g.select('.line').attr('d', d.path).attr('stroke-width', 1.8);
    g.select('.hit').attr('d', d.path);
    g.select('.tip').attr('transform', `translate(${d.q})rotate(${d.angle})`);
  });
  d3.select('#mentions').selectAll('path.mention').data(mentions, d => d.key).join('path').attr('class', 'mention').attr('d', d => d.path);

  const edge = d3.select('#edges').selectAll('g.edge').data(S.edges, d => d.id).join(enter => {
    const g = enter.append('g').attr('class', 'edge');
    g.append('path').attr('class', 'line'); g.append('path').attr('class', 'head').attr('d', headPath); g.append('path').attr('class', 'hit');
    g.on('pointerenter', (event, d) => edgeHover(d, event)).on('pointermove', (event, d) => edgeHover(d, event)).on('pointerleave', () => edgeHover(null)).on('click', (event, d) => { if (S.editing) { event.stopPropagation(); editEdge(d, event); } });
    return g;
  });
  edge.attr('data-kind', d => d.d.kind).attr('data-id', d => d.id).classed('cross', d => d.a.d.domain !== d.b.d.domain);
  move(edge.select('.line')).attr('d', d => d.path);
  edge.select('.hit').attr('d', d => d.path);
  move(edge.select('.head')).attr('transform', d => d.head ? `translate(${d.head.x},${d.head.y})rotate(${d.head.angle})` : null).attr('display', d => d.head ? null : 'none');

  const node = d3.select('#nodes').selectAll('g.node').data(S.nodes, d => d.id).join(enter => {
    const g = enter.append('g').attr('class', 'node');
    g.append('rect').attr('class', 'halo').attr('x', -4).attr('y', -4).attr('rx', 13.5);
    g.append('rect').attr('class', 'card').attr('rx', 10).attr('height', NODE_H);
    g.append('g').attr('class', 'icon').attr('transform', `translate(11,${NODE_H / 2 - 7.5})scale(.625)`);
    g.append('text').attr('class', 'sub').attr('x', 33).attr('y', NODE_H / 2 + 9);
    g.append('text').attr('class', 'title').attr('x', 33).attr('y', NODE_H / 2 + 0.5);
    g.append('text').attr('class', 'summary');
    g.on('click', (event, d) => { event.stopPropagation(); if (!d.moved) focus(d.id); })
      .on('dblclick', (event, d) => { event.stopPropagation(); if (S.editing) editNode(d); else openPage(d.d.pages?.[0], false); })
      .on('pointerenter', (event, d) => { if (event.pointerType !== 'touch') hover(d); }).on('pointerleave', () => hover(null));
    return g;
  });
  node.attr('data-id', d => d.id).style('--tint', d => tint(S.domains.find(x => x.id === d.d.domain)?.color)).classed('draft', d => !!d.d.draft);
  move(node).attr('transform', d => `translate(${d.x},${d.y})`);
  const near = S.zoom === 'near';
  node.select('.halo').attr('width', d => d.w + 8).attr('height', d => (near ? d.hNear : NODE_H) + 8);
  node.select('.card').attr('width', d => d.w).attr('height', d => near ? d.hNear : NODE_H);
  node.select('.icon').html(d => ICONS[d.d.draft ? 'circle-dashed' : 'file-text']);
  const fit = (text, room) => { const font = `600 14px ${FONT}`; if (textWidth(text, font) <= room) return text; let s = text; while (s.length > 1 && textWidth(s + '…', font) > room) s = s.slice(0, -1); return s.trimEnd() + '…'; };
  node.select('.sub').text(d => d.d.subtitle || '');
  node.select('.title').attr('y', d => d.d.subtitle ? NODE_H / 2 - 6.5 : NODE_H / 2 + 0.5).text(d => fit(d.d.title, d.w - 45)).each(function (d) { d3.select(this).selectAll('title').data([d.d.subtitle ? `${d.d.title} · ${d.d.subtitle}` : d.d.title]).join('title').text(t => t); });
  node.select('.summary').each(function (d) { d3.select(this).selectAll('tspan').data(d.lines).join('tspan').attr('x', 12).attr('y', (_, i) => NODE_H + 7 + i * 12.5).text(line => line); });
  drawHandles(); drawMinimap(); drawHead(); applyState();
  $('empty').hidden = S.nodes.length > 0;
  if (!S.nodes.length) $('empty').innerHTML = `<div><b>${esc(T('这张路线图还是空的'))}</b>${S.editable ? esc(T('打开「编辑」，双击空白处新建节点。')) : ''}</div>`;
}
function drawHead() {
  const pages = S.nodes.filter(n => !n.d.draft).length;
  $('head-title').textContent = S.doc?.title || S.title || '';
  $('head-count').textContent = T('%1 个节点 · %2 篇已写成页面', S.nodes.length, pages);
}
function setZoomMode(mode) {
  if (mode === S.zoom) return;
  S.zoom = mode; svg.attr('data-zoom', mode);
  const near = mode === 'near';
  d3.selectAll('#nodes .card').transition().duration(dur(220)).ease(d3.easeCubicOut).attr('height', d => near ? d.hNear : NODE_H);
  d3.selectAll('#nodes .halo').transition().duration(dur(220)).ease(d3.easeCubicOut).attr('height', d => (near ? d.hNear : NODE_H) + 8);
}

// ---------- state classes ----------
let flowTimers = [];
function applyState(flow = false) {
  const node = d3.selectAll('#nodes g.node'), edge = d3.selectAll('#edges g.edge');
  flowTimers.forEach(clearTimeout); flowTimers = [];
  const focusNode = S.focus && S.byId.get(S.focus);
  S.chain = new Set(); S.highlighted = new Set(); S.matches = [];
  if (focusNode) {
    S.chain = ancestors(S.focus);
    S.highlighted = new Set([S.focus, ...S.chain]);
    for (const e of S.outs.get(S.focus)) S.highlighted.add(e.b.id);
    for (const e of S.ins.get(S.focus)) S.highlighted.add(e.a.id);
    const dist = distances(S.focus, S.chain), far = Math.max(1, ...[...S.chain].map(id => dist.get(id) || 0));
    const inChain = e => directed(e.d.kind) && S.chain.has(e.a.id) && (e.b.id === S.focus || S.chain.has(e.b.id));
    const touches = e => e.a.id === S.focus || e.b.id === S.focus;
    node.classed('selected', d => d.id === S.focus).classed('dim', d => !S.highlighted.has(d.id)).classed('match', false).classed('target', false);
    edge.classed('dim', e => !inChain(e) && !touches(e)).classed('lit', e => touches(e) && !inChain(e));
    edge.each(function (e) {
      const on = inChain(e), el = d3.select(this);
      if (!on || !flow || reduced.matches) { el.classed('flow', on); return; }
      el.classed('flow', false);
      flowTimers.push(setTimeout(() => el.classed('flow', true), (far - (dist.get(e.a.id) || 0)) / far * 380));
    });
  } else {
    const query = fold(S.query.trim());
    if (query) {
      const text = n => fold([n.d.title, n.d.subtitle, S.domains.find(d => d.id === n.d.domain)?.title, n.d.summary, ...(n.d.keyPoints || []).map(k => k.text)].join(' '));
      S.matches = S.nodes.filter(n => text(n).includes(query)).sort((a, b) => (fold(b.d.title).startsWith(query) - fold(a.d.title).startsWith(query)) || (fold(b.d.title).includes(query) - fold(a.d.title).includes(query)) || a.i - b.i).map(n => n.id);
    }
    const matched = new Set(S.matches);
    node.classed('selected', false).classed('target', false).classed('dim', d => !!query && !matched.has(d.id)).classed('match', d => matched.has(d.id));
    edge.classed('dim', !!query).classed('lit', false).classed('flow', false);
  }
  $('search-count').textContent = S.query.trim() && !focusNode ? String(S.matches.length) : '';
  app.classList.toggle('show-mentions', S.showMentions);
}

// ---------- viewport ----------
const zoom = d3.zoom().scaleExtent([0.18, 2.6]).filter(event => event.type !== 'wheel' && event.type !== 'dblclick' && !event.button && !(S.editing && event.target.closest?.('.node, .handle')))
  .on('start', event => { if (event.sourceEvent?.type === 'mousedown') svg.classed('grabbing', true); hover(null); })
  .on('zoom', event => { S.t = event.transform; world.attr('transform', S.t); backdrop(); setZoomMode(S.t.k < FAR ? 'far' : S.t.k >= NEAR ? 'near' : 'mid'); drawViewport(); viewChanged(); })
  .on('end', () => svg.classed('grabbing', false));
function backdrop() {
  const step = 28 * S.t.k * (S.t.k < 0.6 ? 2 : 1), canvas = $('canvas');
  canvas.style.backgroundSize = `${step}px ${step}px`; canvas.style.backgroundPosition = `${S.t.x}px ${S.t.y}px`;
  const level = $('zoom-level'); if (level) level.textContent = Math.round(S.t.k * 100) + '%';
}
function viewport() { const rect = $('canvas').getBoundingClientRect(); return { w: rect.width || innerWidth, h: rect.height || innerHeight }; }
function fitTransform() {
  const { w, h } = viewport(), b = S.layout.bounds, open = app.classList.contains('panel-open') && !app.classList.contains('touch');
  const left = 28, right = 28 + (open ? panelSpace() : 0), top = 72, bottom = 36;
  const k = Math.max(0.18, Math.min(1.15, (w - left - right) / b.w, (h - top - bottom) / b.h));
  return d3.zoomIdentity.translate(left + (w - left - right - b.w * k) / 2 - b.x * k, top + (h - top - bottom - b.h * k) / 2 - b.y * k).scale(k);
}
function go(transform, ms = 300) { const target = svg.interrupt(); (dur(ms) ? target.transition().duration(dur(ms)).ease(d3.easeCubicOut) : target).call(zoom.transform, transform); }
function flyTo(node, scale) {
  const { w, h } = viewport(), open = app.classList.contains('panel-open') && !app.classList.contains('touch');
  const left = 40, right = 40 + (open ? panelSpace() : 0), top = open ? 172 : 96, bottom = 56;
  const group = scale ? [node] : S.nodes.filter(n => n === node || S.highlighted.has(n.id));
  const x0 = Math.min(...group.map(n => n.x)), y0 = Math.min(...group.map(n => n.y)), x1 = Math.max(...group.map(n => n.x + n.w)), y1 = Math.max(...group.map(n => n.y + NODE_H));
  const k = scale || Math.max(0.6, Math.min(1.1, (w - left - right) / (x1 - x0), (h - top - bottom) / (y1 - y0)));
  let tx = left + (w - left - right - (x1 - x0) * k) / 2 - x0 * k, ty = top + (h - top - bottom - (y1 - y0) * k) / 2 - y0 * k;
  const sx = tx + (node.x + node.w / 2) * k, sy = ty + (node.y + NODE_H / 2) * k;
  tx += Math.min(0, w - right - 40 - node.w * k / 2 - sx) + Math.max(0, left + node.w * k / 2 - sx); ty += Math.min(0, h - bottom - sy) + Math.max(0, top - sy);
  go(d3.zoomIdentity.translate(tx, ty).scale(k), 320);
}
let viewTimer;
function viewChanged() { clearTimeout(viewTimer); viewTimer = setTimeout(() => post({ type: 'viewChanged', x: S.t.x, y: S.t.y, k: S.t.k }), 400); }
svg.call(zoom).on('dblclick.zoom', null);
$('canvas').addEventListener('wheel', event => {
  event.preventDefault();
  const [x, y] = d3.pointer(event, $('canvas'));
  if (event.ctrlKey || event.metaKey) svg.call(zoom.scaleBy, Math.exp(-event.deltaY * (event.ctrlKey && !event.metaKey ? 0.012 : 0.004)), [x, y]);
  else svg.call(zoom.translateBy, -event.deltaX / S.t.k, -event.deltaY / S.t.k);
}, { passive: false });
let gestureScale = 1;
$('canvas').addEventListener('gesturestart', event => { if (S.platform === 'ios') return; event.preventDefault(); gestureScale = S.t.k; });
$('canvas').addEventListener('gesturechange', event => { if (S.platform === 'ios') return; event.preventDefault(); svg.call(zoom.scaleTo, gestureScale * event.scale, [event.clientX, event.clientY]); });
svg.on('click', () => { if (popoverOpen()) { closePopover(); return; } if (S.focus) focus(null); });
svg.on('dblclick', event => { if (S.editing && !event.target.closest('.node, .edge')) newNodeAt(event); });

// ---------- minimap ----------
function drawMinimap() {
  const b = S.layout.bounds, pad = 30, mini = d3.select('#minimap-svg');
  mini.attr('viewBox', `${b.x - pad} ${b.y - pad} ${b.w + pad * 2} ${b.h + pad * 2}`);
  mini.selectAll('rect.mm-region').data(S.layout.regions, d => d.id).join('rect').attr('class', 'mm-region').style('--tint', d => d.tint).attr('x', d => d.x).attr('y', d => d.y).attr('width', d => d.w).attr('height', d => d.h).attr('rx', 18);
  mini.selectAll('rect.mm-node').data(S.nodes, d => d.id).join('rect').attr('class', 'mm-node').classed('draft', d => !!d.d.draft).attr('x', d => d.x).attr('y', d => d.y).attr('width', d => d.w).attr('height', NODE_H).attr('rx', 10);
  mini.selectAll('rect.mm-view').data([0]).join('rect').attr('class', 'mm-view').attr('rx', 12).raise();
  drawViewport();
}
function drawViewport() {
  const { w, h } = viewport(), [x0, y0] = S.t.invert([0, 0]), [x1, y1] = S.t.invert([w, h]);
  const b = S.layout.bounds;
  $('minimap').classList.toggle('whole', x0 <= b.x + 8 && y0 <= b.y + 8 && x1 >= b.x + b.w - 8 && y1 >= b.y + b.h - 8);
  d3.select('#minimap-svg .mm-view').attr('x', x0).attr('y', y0).attr('width', Math.max(0, x1 - x0)).attr('height', Math.max(0, y1 - y0));
}
function minimapDrag(event) {
  const el = $('minimap-svg'), point = el.createSVGPoint(); point.x = event.clientX; point.y = event.clientY;
  const at = point.matrixTransform(el.getScreenCTM().inverse()), { w, h } = viewport();
  svg.call(zoom.transform, d3.zoomIdentity.translate(w / 2 - at.x * S.t.k, h / 2 - at.y * S.t.k).scale(S.t.k));
}
$('minimap').addEventListener('pointerdown', event => { event.preventDefault(); $('minimap').setPointerCapture(event.pointerId); minimapDrag(event); const moveTo = e => minimapDrag(e), stop = () => { $('minimap').removeEventListener('pointermove', moveTo); $('minimap').removeEventListener('pointerup', stop); }; $('minimap').addEventListener('pointermove', moveTo); $('minimap').addEventListener('pointerup', stop); });

// ---------- hover ----------
let hoverTimer;
const themed = url => /\.svg(\?|$)/i.test(url.split('#')[0]) && url.startsWith('acdian-resource:') ? `${url.split('#')[0]}${url.includes('?') ? '&' : '?'}appearance=${S.theme}#acdian-${S.theme}` : url;
const figuresOf = node => (node.d.pages || []).flatMap(key => S.pages.get(key)?.figures || []);
function place(el, x, y, anchorWidth = 0) {
  el.hidden = false;
  const { w, h } = viewport(), box = el.getBoundingClientRect();
  let left = x + anchorWidth + 12, top = y;
  if (left + box.width > w - 12) left = x - box.width - 12;
  if (left < 12) left = Math.max(12, Math.min(w - box.width - 12, x));
  top = Math.max(12, Math.min(h - box.height - 12, top));
  el.style.left = left + 'px'; el.style.top = top + 'px';
}
function hover(node) {
  clearTimeout(hoverTimer);
  const card = $('hover');
  if (!node || S.zoom === 'far' || popoverOpen()) { card.hidden = true; return; }
  hoverTimer = setTimeout(() => {
    if (node.dragging) return;
    const figure = figuresOf(node)[0];
    card.className = 'float';
    card.innerHTML = `<h4>${esc(node.d.title)}${node.d.subtitle ? `<small>${esc(node.d.subtitle)}</small>` : ''}${node.d.draft ? `<span class="tag">${esc(T('待写'))}</span>` : ''}</h4><p>${esc(node.d.summary || '')}</p>${figure ? `<img alt="" src="${esc(themed(figure))}">` : ''}`;
    const image = card.querySelector('img');
    const show = () => place(card, S.t.applyX(node.x), S.t.applyY(node.y) - 4, node.w * S.t.k);
    if (image) { image.addEventListener('load', show); image.addEventListener('error', () => { image.remove(); show(); }); }
    show();
  }, 240);
}
function linkHover(link, event) {
  const tip = $('edge-tip');
  d3.selectAll('#links g.link').classed('hover', d => d === link).filter(d => d === link).raise();
  d3.selectAll('#edges g.edge').classed('hover', d => !!link && link.edges.includes(d));
  if (!link || popoverOpen()) { tip.hidden = true; return; }
  tip.className = 'float';
  tip.innerHTML = `<b><em>${esc(link.from.domain.title)}</em> → <em>${esc(link.to.domain.title)}</em></b><ul>${link.edges.map(e => `<li>${esc(e.a.d.title)} → ${esc(e.b.d.title)}</li>`).join('')}</ul>`;
  const [x, y] = event ? d3.pointer(event, app) : [S.t.applyX(link.mid[0]), S.t.applyY(link.mid[1])];
  place(tip, x + 4, y + 14);
}
function edgeHover(edge, event) {
  const tip = $('edge-tip');
  d3.selectAll('#edges g.edge').classed('hover', d => d === edge);
  if (!edge || S.zoom === 'far' || popoverOpen()) { tip.hidden = true; return; }
  const arrow = edge.d.kind === 'related' ? '—' : '→';
  tip.className = 'float';
  tip.innerHTML = `<b><em>${esc(edge.a.d.title)}</em> ${arrow} <em>${esc(edge.b.d.title)}</em> · ${esc(T(KIND_NAMES[edge.d.kind] || '相关'))}</b>${esc(edge.d.why || '')}`;
  const [x, y] = event ? d3.pointer(event, app) : [S.t.applyX(edge.mid[0]), S.t.applyY(edge.mid[1])];
  place(tip, x + 4, y + 14);
}

// ---------- focus and panel ----------
function focus(id, options = {}) {
  const node = id ? S.byId.get(id) : null;
  S.focus = node ? node.id : null;
  hover(null); closePopover();
  app.classList.toggle('panel-open', !!node);
  $('panel').setAttribute('aria-hidden', node ? 'false' : 'true');
  applyState(true);
  if (node) { renderPanel(); if (options.fly !== false) flyTo(node, options.scale); }
}
function relation(edge, other, label) {
  return `<li class="rel"><button class="chip${other.d.draft ? ' draft' : ''}" data-focus="${esc(other.id)}">${esc(other.d.title)}</button><span class="kind">${esc(label)}</span><p>${esc(edge.d.why || '')}</p></li>`;
}
function renderPanel() {
  const node = S.byId.get(S.focus); if (!node) return;
  const domain = S.domains.find(d => d.id === node.d.domain), figures = figuresOf(node);
  const before = S.ins.get(node.id).filter(e => directed(e.d.kind)), after = S.outs.get(node.id).filter(e => directed(e.d.kind));
  const related = [...S.ins.get(node.id), ...S.outs.get(node.id)].filter(e => e.d.kind === 'related');
  const path = learningPath(node.id);
  const pages = (node.d.pages || []).map(key => ({ key, info: S.pages.get(key) }));
  const pageIcon = ic('file-text'), goIcon = ic('chevron-right', 'go');
  const h3 = (name, text) => `<h3>${ic(name)}<span>${esc(T(text))}</span></h3>`;
  const step = S.layout.regions.find(r => r.id === domain?.id)?.step;
  const top = `<div class="top"><div class="crumb" style="--tint:${tint(domain?.color)}">${glyphSVG(domain?.glyph)}<span>${step ? `${step} · ` : ''}${esc(domain?.title || '')}</span>${node.d.topic ? `<span class="topic">${esc(node.d.topic)}</span>` : ''}<button class="close" data-close aria-label="Close">${ic('x')}</button></div>`
    + `<h2>${esc(node.d.title)}${node.d.draft ? `<span class="tag">${esc(T('待写'))}</span>` : ''}</h2>${node.d.subtitle ? `<p class="sub">${esc(node.d.subtitle)}</p>` : ''}<p class="lead">${esc(node.d.summary || '')}</p></div>`;
  let main = '', side = '';
  if (figures.length) main += `<button class="figure" data-figure="0"><img alt="${esc(T('原理图'))}" src="${esc(themed(figures[0]))}">${figures.length > 1 ? `<span>1 / ${figures.length}</span>` : ''}</button>`;
  if ((node.d.keyPoints || []).length) main += `${h3('list-checks', '要点')}<ol>${node.d.keyPoints.map((k, i) => `<li><button class="point" data-page="${esc(k.page)}" data-heading="${esc(k.heading)}"><i>${i + 1}</i><span>${esc(k.text)}<small>§ ${esc(k.heading)}</small></span></button></li>`).join('')}</ol>`;
  side += h3('file-text', '页面');
  side += pages.length ? `<ul>${pages.map(({ key, info }) => `<li><button class="page${info && info.exists === false ? ' missing' : ''}" data-page="${esc(key)}">${pageIcon}<span>${esc(info?.title || key.split('/').pop())}</span>${info && info.exists === false ? `<span class="tag">${esc(T('页面不存在'))}</span>` : goIcon}</button></li>`).join('')}</ul>`
    : `<p class="hint">${esc(node.d.note || T('这个节点还没有页面，摘要是通用常识。'))}</p>${S.editing ? `<button class="page" data-new-page>${pageIcon}<span>${esc(T('新建页面'))}</span></button>` : ''}`;
  if (before.length) side += `${h3('log-in', '先学')}<ul>${before.map(e => relation(e, e.a, e.d.kind === 'applies' ? T('用到的概念') : '')).join('')}</ul>`;
  if (after.length) side += `${h3('log-out', '学完可以继续')}<ul>${after.map(e => relation(e, e.b, e.d.kind === 'applies' ? T('在这里用到') : '')).join('')}</ul>`;
  if (related.length) side += `${h3('link-2', '相关')}<ul>${related.map(e => relation(e, e.a.id === node.id ? e.b : e.a, '')).join('')}</ul>`;
  side += h3('route', '学习路径');
  if (path.length) side += `<ol class="path">${path.map(step => { const other = S.byId.get(step.id); return `<li><button class="chip${other.d.draft ? ' draft' : ''}" data-focus="${esc(other.id)}">${esc(other.d.title)}</button><p>${esc(step.why)}</p></li>`; }).join('')}<li class="goal"><button class="chip" data-focus="${esc(node.id)}">${esc(node.d.title)}</button></li></ol>`;
  else side += `<p class="hint">${esc(T('没有前置，可以从这里开始。'))}</p>`;
  if (S.editing) side += `${h3('pencil', '编辑')}<ul><li><button class="page" data-edit-node>${esc(T('节点标题'))}…</button></li><li><button class="page" data-remove-node>${esc(T('移除节点'))}</button></li></ul>`;
  const html = `<div class="scroll">${top}<div class="cols${main ? '' : ' solo'}">${main ? `<div class="main">${main}</div>` : ''}<div class="side">${side}</div></div></div>`;
  const panel = $('panel'), keep = panel.dataset.node === node.id ? panel.querySelector('.scroll')?.scrollTop : 0;
  panel.dataset.node = node.id; panel.innerHTML = html;
  if (keep) panel.querySelector('.scroll').scrollTop = keep;
}
function openPage(key, newTab, heading) { if (!key) return; post({ type: 'openPage', key, newTab: !!newTab, ...(heading ? { heading } : {}) }); }
$('panel').addEventListener('click', event => {
  const target = event.target.closest('button'); if (!target) return;
  const node = S.byId.get(S.focus);
  if ('close' in target.dataset) focus(null);
  else if (target.dataset.focus) focus(target.dataset.focus);
  else if (target.dataset.figure) lightbox(figuresOf(node), 0);
  else if ('newPage' in target.dataset) post({ type: 'newPage', id: node.id, title: node.d.title });
  else if ('editNode' in target.dataset) editNode(node);
  else if ('removeNode' in target.dataset) removeNode(node);
  else if (target.dataset.page) openPage(target.dataset.page, true, target.dataset.heading);
});
function lightbox(figures, at) {
  const box = $('lightbox'); if (!figures.length) return;
  const show = () => { box.innerHTML = `<img alt="" src="${esc(themed(figures[at]))}">${figures.length > 1 ? `<div class="nav">${at + 1} / ${figures.length}</div>` : ''}`; box.hidden = false; };
  box.onclick = event => { if (figures.length > 1 && event.target.tagName === 'IMG') { at = (at + 1) % figures.length; show(); } else box.hidden = true; };
  show();
}

// ---------- saving ----------
let saveTimer;
function touch(node) { node.d.updated = Math.max(now(), (node.d.updated || 0) + 1); S.dirtyNodes.add(node.id); scheduleSave(); }
function touchEdge(edge) { edge.d.updated = Math.max(now(), (edge.d.updated || 0) + 1); S.dirtyEdges.add(edge.id); scheduleSave(); }
function scheduleSave() { clearTimeout(saveTimer); saveTimer = setTimeout(flush, 400); }
function flush() {
  clearTimeout(saveTimer);
  if (!S.dirtyNodes.size && !S.dirtyEdges.size && !Object.keys(S.removed).length) return;
  post({ type: 'save', nodes: [...S.dirtyNodes].map(id => S.byId.get(id)?.d).filter(Boolean), edges: S.edges.filter(e => S.dirtyEdges.has(e.id)).map(e => e.d), removed: S.removed });
  S.dirtyNodes = new Set(); S.dirtyEdges = new Set(); S.removed = {};
}

// ---------- chrome ----------
function drawChrome() {
  const canEdit = S.editable && S.platform !== 'ios';
  $('tools').innerHTML = `${canEdit ? `<div class="group"><button data-tool="edit" aria-pressed="${S.editing}" title="${esc(T(S.editing ? '完成' : '编辑'))}">${ic('pencil')}<span>${esc(T(S.editing ? '完成' : '编辑'))}</span></button></div>` : ''}<div class="group"><button data-tool="mentions" aria-pressed="${S.showMentions}" title="${esc(T('页面互链'))}">${ic('link-2')}</button></div><div class="group"><button data-tool="out" title="${esc(T('缩小'))}">${ic('minus')}</button><button data-tool="fit" title="${esc(T('适合窗口'))}"><span id="zoom-level">${Math.round(S.t.k * 100)}%</span></button><button data-tool="in" title="${esc(T('放大'))}">${ic('plus')}</button></div>`;
  $('search-input').placeholder = T('搜索节点');
  if (!$('search-kbd') && S.platform !== 'ios') $('search-count').insertAdjacentHTML('afterend', '<kbd id="search-kbd">⌘F</kbd>');
  const line = (kind, arrow) => `<svg viewBox="0 0 34 14"><g class="edge" data-kind="${kind}" style="opacity:1"><path class="line" d="M1,7H${arrow ? 26 : 33}" style="stroke:var(--rm-line-strong)"/>${arrow ? '<path class="head" d="M33,7L25.5,3.4L25.5,10.6Z" style="fill:var(--rm-line-strong)"/>' : ''}</g></svg>`;
  const card = draft => `<svg viewBox="0 0 34 14"><g class="node${draft ? ' draft' : ''}" style="--tint:var(--rm-muted)"><rect class="card" x=".75" y=".75" width="32.5" height="12.5" rx="4"/><path d="M7,7H27" stroke="var(--rm-muted)" stroke-width="1.6" stroke-linecap="round" opacity=".5"/></g></svg>`;
  $('legend').className = 'float' + (S.legendClosed ? ' closed' : '');
  $('legend').innerHTML = `<button class="toggle"><span>${esc(T('图例'))}</span><svg viewBox="0 0 10 10"><path d="M2 3.5 5 6.5 8 3.5"/></svg></button><div class="body">
    <div class="row">${line('requires', true)}<span>${esc(T('先学 A 再学 B'))}</span></div><div class="row">${line('applies', true)}<span>${esc(T('B 是 A 的实际应用'))}</span></div><div class="row">${line('related', false)}<span>${esc(T('相关，聚焦时显示'))}</span></div><hr>
    <div class="row">${card(false)}<span>${esc(T('已写成页面'))}</span></div><div class="row">${card(true)}<span>${esc(T('待写'))} · ${esc(T('还没有页面'))}</span></div><hr>
    <div class="domains">${S.domains.map(d => `<span style="--tint:${tint(d.color)}"><i></i>${esc(d.title)}</span>`).join('')}</div></div>`;
}
$('legend').addEventListener('click', event => { if (event.target.closest('.toggle')) { S.legendClosed = !S.legendClosed; drawChrome(); } });
$('tools').addEventListener('click', event => {
  const tool = event.target.closest('button')?.dataset.tool;
  if (tool === 'fit') go(fitTransform());
  else if (tool === 'in') svg.transition().duration(dur(180)).call(zoom.scaleBy, 1.3);
  else if (tool === 'out') svg.transition().duration(dur(180)).call(zoom.scaleBy, 1 / 1.3);
  else if (tool === 'mentions') { S.showMentions = !S.showMentions; drawChrome(); applyState(); }
  else if (tool === 'edit') setEditing(!S.editing);
});
const input = $('search-input');
input.addEventListener('input', () => { S.query = input.value; if (S.focus) focus(null); else applyState(); });
input.addEventListener('keydown', event => {
  event.stopPropagation();
  if (event.key === 'Enter' && S.matches.length) { const id = S.matches[0]; input.blur(); S.query = ''; input.value = ''; focus(id, { scale: 1 }); }
  if (event.key === 'Escape') { input.value = ''; S.query = ''; input.blur(); applyState(); }
});
function toast(text) { const el = $('toast'); el.className = 'float'; el.textContent = text; el.hidden = false; clearTimeout(toast.timer); toast.timer = setTimeout(() => { el.hidden = true; }, 2600); }
document.addEventListener('keydown', event => {
  if (event.target.closest?.('input, textarea')) return;
  const command = event.metaKey || event.ctrlKey;
  if (command && event.key.toLowerCase() === 'f') { event.preventDefault(); input.focus(); input.select(); }
  else if (command && (event.key === '=' || event.key === '+')) { event.preventDefault(); svg.transition().duration(dur(180)).call(zoom.scaleBy, 1.3); }
  else if (command && event.key === '-') { event.preventDefault(); svg.transition().duration(dur(180)).call(zoom.scaleBy, 1 / 1.3); }
  else if (command && event.key === '0') { event.preventDefault(); go(fitTransform()); }
  else if (command && event.key.toLowerCase() === 'z' && S.editing) { event.preventDefault(); undo(); }
  else if (event.key === 'Escape') { if (!$('lightbox').hidden) $('lightbox').hidden = true; else if (popoverOpen()) closePopover(); else if (S.focus) focus(null); }
  else if (S.editing && S.focus && (event.key === 'Backspace' || event.key === 'Delete')) removeNode(S.byId.get(S.focus));
});
addEventListener('resize', () => { drawViewport(); });

// ---------- editing ----------
const popoverOpen = () => !$('popover').hidden;
function closePopover() { const el = $('popover'); if (el.hidden) return; el.hidden = true; el.onclose?.(); el.onclose = null; }
function snapshot() { S.undo.push(JSON.stringify({ nodes: S.doc.nodes, edges: S.doc.edges })); if (S.undo.length > 60) S.undo.shift(); }
function undo() {
  const last = S.undo.pop(); if (!last) { toast(T('没有可撤销的操作')); return; }
  const before = JSON.parse(last), stamp = now();
  const nodeIds = new Set(before.nodes.map(n => n.id)), edgeIds = new Set(before.edges.map(e => e.id));
  for (const node of S.doc.nodes) if (!nodeIds.has(node.id)) S.removed['node:' + node.id] = stamp;
  for (const edge of S.doc.edges) if (!edgeIds.has(edge.id)) S.removed['edge:' + edge.id] = stamp;
  S.doc.nodes = before.nodes.map(n => ({ ...n, updated: stamp })); S.doc.edges = before.edges.map(e => ({ ...e, updated: stamp }));
  index(); layout(); draw(true);
  S.dirtyNodes = new Set(S.nodes.map(n => n.id)); S.dirtyEdges = new Set(S.edges.map(e => e.id)); scheduleSave();
  if (S.focus && !S.byId.has(S.focus)) focus(null); else if (S.focus) renderPanel();
  toast(T('已撤销'));
}
function setEditing(on) {
  S.editing = !!on && S.editable; app.classList.toggle('editing', S.editing); closePopover(); drawChrome(); layout(); draw(); drawDrawer();
  if (S.focus) renderPanel();
}
function drawHandles() {
  const handle = d3.select('#handles').selectAll('circle.handle').data(S.editing ? S.nodes : [], d => d.id).join('circle').attr('class', 'handle').attr('r', 5.5).attr('cx', d => d.x + d.w).attr('cy', d => d.y + NODE_H / 2);
  handle.on('pointerdown', startConnect);
  d3.selectAll('#nodes g.node').on('pointerdown.edit', S.editing ? startDrag : null);
  d3.selectAll('#nodes g.node').on('pointerenter.handle', (event, d) => handle.classed('near', h => h === d)).on('pointerleave.handle', () => handle.classed('near', false));
}
function startDrag(event, node) {
  if (event.button) return;
  event.stopPropagation();
  const start = d3.pointer(event, $('world')), origin = [node.x, node.y]; let moved = false;
  const moveTo = e => {
    const at = d3.pointer(e, $('world')), dx = at[0] - start[0], dy = at[1] - start[1];
    if (!moved && Math.hypot(dx, dy) * S.t.k < 4) return;
    if (!moved) { moved = true; snapshot(); node.dragging = true; hover(null); }
    node.x = Math.round(origin[0] + dx); node.y = Math.round(origin[1] + dy); node.d.x = node.x; node.d.y = node.y;
    relayout();
  };
  const stop = () => {
    removeEventListener('pointermove', moveTo); removeEventListener('pointerup', stop);
    node.dragging = false;
    if (moved) { node.moved = true; setTimeout(() => { node.moved = false; }, 0); touch(node); layout(); draw(); }
  };
  addEventListener('pointermove', moveTo); addEventListener('pointerup', stop);
}
function relayout() {
  for (const region of S.layout.regions) { region.x = Infinity; }
  layout(); draw();
}
function startConnect(event, from) {
  event.stopPropagation(); event.preventDefault();
  const rubber = d3.select('#handles').append('path').attr('class', 'rubber'); let over = null;
  const origin = [from.x + from.w, from.y + NODE_H / 2];
  const moveTo = e => {
    const at = d3.pointer(e, $('world'));
    rubber.attr('d', `M${origin}C${origin[0] + 40},${origin[1]} ${at[0] - 40},${at[1]} ${at}`);
    over = S.nodes.find(n => n !== from && at[0] > n.x && at[0] < n.x + n.w && at[1] > n.y && at[1] < n.y + NODE_H) || null;
    const bad = over && (reaches(over.id, from.id, ['requires', 'applies']) || exists(from.id, over.id));
    d3.selectAll('#nodes g.node').classed('drop', d => d === over && !bad).classed('deny', d => d === over && bad);
  };
  const stop = () => {
    removeEventListener('pointermove', moveTo); removeEventListener('pointerup', stop);
    rubber.remove(); d3.selectAll('#nodes g.node').classed('drop', false).classed('deny', false);
    if (over) connect(from, over);
  };
  addEventListener('pointermove', moveTo); addEventListener('pointerup', stop);
}
const exists = (a, b) => S.edges.some(e => (e.a.id === a && e.b.id === b) || (e.a.id === b && e.b.id === a));
function connect(from, to, kind = 'requires') {
  if (exists(from.id, to.id)) { toast(T('这两个节点之间已经有关系了。')); return null; }
  if (directed(kind) && reaches(to.id, from.id, ['requires', 'applies'])) { toast(T('这样连会成环：%1 已经排在 %2 后面。', from.d.title, to.d.title)); return null; }
  snapshot();
  const data = { id: from.id + (kind === 'related' ? '~' : '>') + to.id, from: from.id, to: to.id, kind, why: '', updated: now() };
  delete S.removed['edge:' + data.id];
  S.doc.edges.push(data); index(); layout(); draw();
  const edge = S.edges.find(e => e.id === data.id); S.dirtyEdges.add(edge.id); scheduleSave();
  editEdge(edge);
  return edge;
}
function editEdge(edge, event) {
  hover(null); edgeHover(null);
  const el = $('popover'); el.className = 'float';
  el.innerHTML = `<div class="segment">${['requires', 'applies', 'related'].map(kind => `<button data-kind="${kind}" aria-pressed="${edge.d.kind === kind}">${esc(T(KIND_NAMES[kind]))}</button>`).join('')}</div><textarea placeholder="${esc(T('为什么有这条关系？一句话。'))}">${esc(edge.d.why || '')}</textarea><div class="actions"><button class="danger" data-delete>${esc(T('删除'))}</button><button class="primary" data-done>${esc(T('完成'))}</button></div>`;
  const [x, y] = event ? d3.pointer(event, app) : [S.t.applyX(edge.mid[0]), S.t.applyY(edge.mid[1])];
  place(el, x, y + 10);
  const area = el.querySelector('textarea'); let before = JSON.stringify({ nodes: S.doc.nodes, edges: S.doc.edges }), changed = false;
  const commit = () => { const why = area.value.trim(); if (why !== (edge.d.why || '')) { if (!changed) { S.undo.push(before); changed = true; } edge.d.why = why; touchEdge(edge); } };
  area.addEventListener('input', commit);
  area.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Escape' || (e.key === 'Enter' && !e.shiftKey && !e.isComposing)) { e.preventDefault(); closePopover(); } });
  el.onclick = e => {
    const button = e.target.closest('button'); if (!button) return;
    if (button.dataset.kind && button.dataset.kind !== edge.d.kind) {
      const kind = button.dataset.kind;
      if (directed(kind) && !directed(edge.d.kind) && reaches(edge.b.id, edge.a.id, ['requires', 'applies'])) { toast(T('这样连会成环：%1 已经排在 %2 后面。', edge.a.d.title, edge.b.d.title)); return; }
      if (!changed) { S.undo.push(before); changed = true; }
      edge.d.kind = kind; touchEdge(edge); layout(); draw();
      el.querySelectorAll('[data-kind]').forEach(b => b.setAttribute('aria-pressed', b.dataset.kind === kind));
    } else if ('delete' in button.dataset) { if (!changed) S.undo.push(before); el.onclose = null; el.hidden = true; removeEdge(edge); }
    else if ('done' in button.dataset) closePopover();
  };
  el.onclose = () => { if (S.focus) renderPanel(); };
  setTimeout(() => area.focus(), 0);
}
function removeEdge(edge) {
  S.removed['edge:' + edge.id] = now(); S.dirtyEdges.delete(edge.id);
  S.doc.edges = S.doc.edges.filter(d => d !== edge.d); index(); layout(); draw(); scheduleSave();
  if (S.focus) renderPanel();
}
function slug(title) {
  const base = fold(title).replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'node';
  let id = base, n = 2; while (S.byId.has(id) || S.removed['node:' + id]) id = `${base}-${n++}`;
  return id;
}
function nearestRegion(x, y) {
  let best = S.layout.regions[0], distance = Infinity;
  for (const region of S.layout.regions) { const dx = Math.max(region.x - x, 0, x - region.x - region.w), dy = Math.max(region.y - y, 0, y - region.y - region.h), d = Math.hypot(dx, dy); if (d < distance) { distance = d; best = region; } }
  return best;
}
function newNodeAt(event) {
  const [x, y] = d3.pointer(event, $('world')), region = nearestRegion(x, y), domain = region?.domain || S.domains[0];
  if (!domain) return;
  snapshot();
  const W = S.layout.W, level = region?.capstone ? 3 : Math.max(0, Math.min(2, Math.round((x - (region?.x ?? 0) - PAD_X - W / 2) / (W + COL_GAP))));
  const data = { id: slug('node'), title: T('新节点'), domain: domain.id, level, pages: [], summary: '', keyPoints: [], draft: true, x: Math.round(x - W / 2), y: Math.round(y - NODE_H / 2), updated: now() };
  S.doc.nodes.push(data); index(); layout(); draw();
  const node = S.byId.get(data.id); S.dirtyNodes.add(node.id); scheduleSave();
  editNode(node);
}
function editNode(node) {
  hover(null);
  const el = $('popover'); el.className = 'float';
  el.innerHTML = `<label>${esc(T('节点标题'))}</label><input type="text" value="${esc(node.d.title)}"><textarea placeholder="${esc(T('这个节点还没有页面，摘要是通用常识。'))}">${esc(node.d.summary || '')}</textarea><div class="actions"><button class="danger" data-delete>${esc(T('移除节点'))}</button><button class="primary" data-done>${esc(T('完成'))}</button></div>`;
  place(el, S.t.applyX(node.x), S.t.applyY(node.y + NODE_H) + 8);
  const field = el.querySelector('input'), area = el.querySelector('textarea'), before = JSON.stringify({ nodes: S.doc.nodes, edges: S.doc.edges }); let changed = false;
  const commit = () => {
    const title = field.value.trim() || node.d.title, summary = area.value.trim();
    if (title === node.d.title && summary === (node.d.summary || '')) return;
    if (!changed) { S.undo.push(before); changed = true; }
    node.d.title = title; node.d.summary = summary; touch(node); layout(); draw(); if (S.focus === node.id) renderPanel();
  };
  field.addEventListener('input', commit); area.addEventListener('input', commit);
  for (const control of [field, area]) control.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Escape' || (e.key === 'Enter' && !e.shiftKey && !e.isComposing)) { e.preventDefault(); closePopover(); } });
  el.onclick = e => { const button = e.target.closest('button'); if (!button) return; if ('delete' in button.dataset) { el.hidden = true; el.onclose = null; if (changed) S.undo.pop(); removeNode(node); } else closePopover(); };
  setTimeout(() => { field.focus(); field.select(); }, 0);
}
function removeNode(node) {
  if (!node || !S.editing) return;
  snapshot();
  const stamp = now();
  S.removed['node:' + node.id] = stamp; S.dirtyNodes.delete(node.id);
  for (const edge of S.edges) if (edge.a === node || edge.b === node) { S.removed['edge:' + edge.id] = stamp; S.dirtyEdges.delete(edge.id); }
  S.doc.edges = S.doc.edges.filter(e => e.from !== node.id && e.to !== node.id); S.doc.nodes = S.doc.nodes.filter(d => d !== node.d);
  if (S.focus === node.id) focus(null);
  index(); layout(); draw(); drawDrawer(); scheduleSave();
}
function unattached() {
  const used = new Set(S.nodes.flatMap(n => n.d.pages || [])), excluded = new Set(S.doc.exclude || []);
  return [...S.pages.values()].filter(page => page.exists !== false && !used.has(page.key) && !excluded.has(page.key));
}
function drawDrawer() {
  const el = $('drawer'); el.hidden = !S.editing; if (!S.editing) return;
  const pages = unattached(); el.className = 'float';
  el.innerHTML = `<h5>${esc(T('未挂靠的页面'))}</h5>${pages.length ? pages.map(page => `<span class="item" draggable="true" data-key="${esc(page.key)}">${esc(page.title)}</span>`).join('') + `<div class="none">${esc(T('把页面拖到节点上挂靠'))}</div>` : `<div class="none">${esc(T('所有页面都已挂上'))}</div>`}`;
}
$('drawer').addEventListener('dragstart', event => { const key = event.target.dataset?.key; if (key) { event.dataTransfer.setData('text/plain', 'acdian-roadmap-page:' + key); event.dataTransfer.effectAllowed = 'link'; } });
function nodeAtClient(x, y) { const [wx, wy] = S.t.invert([x - $('canvas').getBoundingClientRect().left, y - $('canvas').getBoundingClientRect().top]); return S.nodes.find(n => wx > n.x && wx < n.x + n.w && wy > n.y && wy < n.y + NODE_H) || null; }
$('canvas').addEventListener('dragover', event => { if (!S.editing) return; event.preventDefault(); const over = nodeAtClient(event.clientX, event.clientY); d3.selectAll('#nodes g.node').classed('drop', d => d === over); });
$('canvas').addEventListener('dragleave', () => d3.selectAll('#nodes g.node').classed('drop', false));
$('canvas').addEventListener('drop', event => {
  if (!S.editing) return; event.preventDefault();
  d3.selectAll('#nodes g.node').classed('drop', false);
  const text = event.dataTransfer.getData('text/plain') || '', node = nodeAtClient(event.clientX, event.clientY);
  if (node && text.startsWith('acdian-roadmap-page:')) attach(node.id, text.slice(20));
});
function attach(id, key) {
  const node = S.byId.get(id); if (!node || !key || (node.d.pages || []).includes(key)) return false;
  snapshot();
  node.d.pages = [...(node.d.pages || []), key]; delete node.d.draft;
  const info = S.pages.get(key); if (!node.d.summary && info?.summary) node.d.summary = info.summary;
  touch(node); layout(); draw(); drawDrawer(); if (S.focus === id) renderPanel();
  return true;
}

// ---------- messages ----------
function setTheme(theme) {
  S.theme = theme === 'light' ? 'light' : 'dark'; document.documentElement.dataset.theme = S.theme;
  document.querySelectorAll('img[src^="acdian-resource:"]').forEach(image => { const next = themed(image.getAttribute('src')); if (next !== image.getAttribute('src')) image.setAttribute('src', next); });
}
function load(message, update) {
  const first = !S.loaded;
  if (message.theme) setTheme(message.theme);
  S.language = message.language || S.language; S.editable = !!message.editable; S.platform = message.platform || S.platform; S.title = message.title || S.title;
  document.documentElement.lang = S.language; app.classList.toggle('touch', S.platform === 'ios');
  S.doc = message.roadmap || { nodes: [], edges: [], domains: [] }; S.doc.nodes ||= []; S.doc.edges ||= []; S.doc.domains ||= [];
  S.pages = new Map((message.pages || []).map(page => [page.key, page])); S.mentions = message.mentions || [];
  if (!S.editable) S.editing = false;
  index(); layout(); drawChrome(); draw(update && !first); drawDrawer();
  if (S.focus && !S.byId.has(S.focus)) focus(null); else if (S.focus) { renderPanel(); applyState(); }
  if (first) {
    const view = message.view || S.doc.view, saved = view && Number.isFinite(view.k) && !(view.x === 0 && view.y === 0 && view.k === 1);
    svg.call(zoom.transform, saved ? d3.zoomIdentity.translate(view.x, view.y).scale(view.k) : fitTransform());
    S.loaded = true; app.classList.add('ready'); app.setAttribute('aria-busy', 'false');
    if (message.focus) focus(message.focus, { scale: 1 });
  }
}
window.acdianRoadmap = {
  receive(message) {
    if (!message || typeof message !== 'object') return;
    if (message.type === 'load') load(message, false);
    else if (message.type === 'update') { if (S.dirtyNodes.size || S.dirtyEdges.size || popoverOpen()) return; load(message, true); }
    else if (message.type === 'theme') setTheme(message.theme);
    else if (message.type === 'focus') { const node = S.byId.get(message.id); if (node) focus(node.id, { scale: 1 }); }
    else if (message.type === 'find') { input.focus(); input.select(); }
    else if (message.type === 'attach') attach(nodeAtClient(message.x, message.y)?.id, message.key);
    else if (message.type === 'flush') flush();
  },
  state: () => ({ focus: S.focus, zoom: S.zoom, k: S.t.k, highlighted: [...S.highlighted].sort(), chain: [...S.chain].sort(), path: S.focus ? learningPath(S.focus).map(step => step.id) : [], matches: [...S.matches], editing: S.editing, nodes: S.nodes.map(n => ({ id: n.id, x: n.x, y: n.y, w: n.w, h: NODE_H, draft: !!n.d.draft })), bounds: S.layout?.bounds }),
  focus, fit: () => svg.call(zoom.transform, fitTransform()), setZoom: k => { const { w, h } = viewport(); svg.call(zoom.scaleTo, k, [w / 2, h / 2]); }, search: text => { input.value = text; S.query = text; applyState(); }, flush, undo, setEditing, connect: (a, b, kind) => !!connect(S.byId.get(a), S.byId.get(b), kind), attach,
};
svg.attr('data-zoom', 'mid');
post({ type: 'ready' });
})();
