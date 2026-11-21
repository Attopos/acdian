(() => {
  const paths = new Map();
  const path2d = d => { let p = paths.get(d); if (!p) { p = new Path2D(d); paths.set(d, p); } return p; };
  const num = v => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };
  const multiply = (a, b) => [a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1], a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3], a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]];
  const local = el => {
    const list = el.transform?.baseVal;
    if (!list || !list.numberOfItems) return null;
    const m = list.consolidate().matrix;
    return [m.a, m.b, m.c, m.d, m.e, m.f];
  };
  const paintable = value => value && value !== 'none' && value !== 'transparent' && !/rgba\([^)]*,\s*0\)$/.test(value);
  const dashes = value => !value || value === 'none' ? null : value.split(/[\s,]+/).map(num).filter(n => n >= 0);

  function styleOf(cs) {
    return {
      fill: cs.fill, fillOpacity: num(cs.fillOpacity || 1), stroke: cs.stroke, strokeOpacity: num(cs.strokeOpacity || 1),
      width: num(cs.strokeWidth || 1), dash: dashes(cs.strokeDasharray), cap: cs.strokeLinecap || 'butt', join: cs.strokeLinejoin || 'miter',
      strokeFirst: (cs.paintOrder || '').startsWith('stroke'),
    };
  }

  function texts(el, cs, m, opacity, out) {
    const base = styleOf(cs), runs = [];
    let x = num(el.getAttribute('x')), y = num(el.getAttribute('y')), chunk = null;
    const start = (nx, ny) => { chunk = { x: nx, y: ny, runs: [], anchor: cs.textAnchor }; runs.push(chunk); };
    const push = (text, style, font, baseline, spacing) => { text = text.replace(/\s+/g, ' '); if (!text.trim()) return; if (!chunk) start(x, y); chunk.runs.push({ text, style, font, baseline, spacing }); };
    const fontOf = s => `${s.fontStyle === 'italic' ? 'italic ' : ''}${s.fontWeight} ${s.fontSize} ${s.fontFamily}`;
    const baselineOf = s => /central|middle/.test(s.dominantBaseline) ? 'middle' : /hanging/.test(s.dominantBaseline) ? 'hanging' : 'alphabetic';
    for (const child of el.childNodes) {
      if (child.nodeType === 3) { push(child.data, base, fontOf(cs), baselineOf(cs), num(cs.letterSpacing)); continue; }
      if (child.nodeName !== 'tspan') continue;
      const ts = getComputedStyle(child);
      if (ts.display === 'none' || ts.visibility === 'hidden') continue;
      const hasX = child.hasAttribute('x'), hasY = child.hasAttribute('y');
      if (hasX || hasY) { start(hasX ? num(child.getAttribute('x')) : x, hasY ? num(child.getAttribute('y')) : y); x = chunk.x; y = chunk.y; }
      if (!chunk) start(x, y);
      const opacityHere = num(ts.opacity || 1);
      chunk.runs.push({ text: child.textContent.replace(/\s+/g, ' '), style: { ...styleOf(ts), alpha: opacityHere }, font: fontOf(ts), baseline: baselineOf(ts.dominantBaseline ? ts : cs), spacing: num(ts.letterSpacing), gap: num(child.getAttribute('dx')) });
    }
    for (const c of runs) if (c.runs.length) out.push({ type: 'text', m, opacity, chunk: c, el });
  }

  function walk(el, parent, opacity, out) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none') return;
    const alpha = opacity * num(cs.opacity === '' ? 1 : cs.opacity);
    if (alpha <= 0.002) return;
    const own = local(el), m = own ? multiply(parent, own) : parent;
    const tag = el.nodeName;
    if (tag === 'g' || tag === 'svg') { for (const child of el.children) walk(child, m, alpha, out); return; }
    if (cs.visibility === 'hidden' || tag === 'title' || tag === 'defs') return;
    if (tag === 'text') { texts(el, cs, m, alpha, out); return; }
    const style = styleOf(cs);
    if (!paintable(style.fill) && !paintable(style.stroke)) return;
    let shape = null;
    if (tag === 'path') { const d = el.getAttribute('d'); if (d) shape = { kind: 'path', d }; }
    else if (tag === 'rect') shape = { kind: 'rect', x: num(el.getAttribute('x')), y: num(el.getAttribute('y')), w: num(el.getAttribute('width')), h: num(el.getAttribute('height')), r: num(el.getAttribute('rx')) };
    else if (tag === 'circle') shape = { kind: 'circle', x: num(el.getAttribute('cx')), y: num(el.getAttribute('cy')), r: num(el.getAttribute('r')) };
    else if (tag === 'ellipse') shape = { kind: 'ellipse', x: num(el.getAttribute('cx')), y: num(el.getAttribute('cy')), rx: num(el.getAttribute('rx')), ry: num(el.getAttribute('ry')) };
    else if (tag === 'line') shape = { kind: 'path', d: `M${num(el.getAttribute('x1'))},${num(el.getAttribute('y1'))}L${num(el.getAttribute('x2'))},${num(el.getAttribute('y2'))}` };
    else if (tag === 'polyline' || tag === 'polygon') { const pts = (el.getAttribute('points') || '').trim(); if (pts) shape = { kind: 'path', d: 'M' + pts.split(/\s+/).join('L') + (tag === 'polygon' ? 'Z' : '') }; }
    if (shape) out.push({ type: 'shape', m, opacity: alpha, shape, style, el });
  }

  function trace(ctx, s) {
    if (s.kind === 'path') return path2d(s.d);
    const p = new Path2D();
    if (s.kind === 'rect') { if (s.r && p.roundRect) p.roundRect(s.x, s.y, s.w, s.h, Math.min(s.r, s.w / 2, s.h / 2)); else p.rect(s.x, s.y, s.w, s.h); }
    else if (s.kind === 'circle') p.arc(s.x, s.y, s.r, 0, Math.PI * 2);
    else if (s.kind === 'ellipse') p.ellipse(s.x, s.y, s.rx, s.ry, 0, 0, Math.PI * 2);
    return p;
  }

  function strokeWith(ctx, style, alpha) {
    if (!paintable(style.stroke) || style.width <= 0) return false;
    ctx.globalAlpha = alpha * style.strokeOpacity; ctx.strokeStyle = style.stroke; ctx.lineWidth = style.width;
    ctx.lineCap = style.cap; ctx.lineJoin = style.join; ctx.setLineDash(style.dash && style.dash.some(Boolean) ? style.dash : []);
    return true;
  }

  const widths = new Map();
  const measure = (ctx, r) => {
    const key = r.font + '|' + r.spacing + '|' + r.text;
    let w = widths.get(key);
    if (w === undefined) { ctx.font = r.font; if ('letterSpacing' in ctx) ctx.letterSpacing = r.spacing + 'px'; w = ctx.measureText(r.text).width; widths.set(key, w); }
    return w;
  };

  function draw(ctx, ops, K, X, Y, view) {
    for (const op of ops) {
      const m = op.m;
      ctx.setTransform(K * m[0], K * m[1], K * m[2], K * m[3], K * m[4] + X, K * m[5] + Y);
      if (op.type === 'shape') {
        const s = op.shape;
        if (s.kind === 'rect' && m[0] === 1 && m[3] === 1 && (m[4] + s.x > view[2] || m[5] + s.y > view[3] || m[4] + s.x + s.w < view[0] || m[5] + s.y + s.h < view[1])) continue;
        const p = trace(ctx, s), st = op.style;
        const fill = () => { if (paintable(st.fill)) { ctx.globalAlpha = op.opacity * st.fillOpacity; ctx.fillStyle = st.fill; ctx.fill(p); } };
        const stroke = () => { if (strokeWith(ctx, st, op.opacity)) ctx.stroke(p); };
        if (st.strokeFirst) { stroke(); fill(); } else { fill(); stroke(); }
      } else {
        const c = op.chunk;
        if (m[0] === 1 && m[3] === 1 && (m[5] + c.y < view[1] - 80 || m[5] + c.y > view[3] + 80)) continue;
        let width = 0;
        for (const r of c.runs) { r.w = measure(ctx, r); width += r.w + (r.gap || 0); }
        let x = c.x - (c.anchor === 'middle' ? width / 2 : c.anchor === 'end' ? width : 0);
        for (const r of c.runs) {
          x += r.gap || 0;
          ctx.font = r.font; if ('letterSpacing' in ctx) ctx.letterSpacing = r.spacing + 'px'; ctx.textBaseline = r.baseline; ctx.textAlign = 'left';
          const st = r.style, alpha = op.opacity * (st.alpha ?? 1);
          const fill = () => { if (paintable(st.fill)) { ctx.globalAlpha = alpha * st.fillOpacity; ctx.fillStyle = st.fill; ctx.fillText(r.text, x, c.y); } };
          const stroke = () => { if (strokeWith(ctx, st, alpha)) { ctx.setLineDash([]); ctx.strokeText(r.text, x, c.y); } };
          if (st.strokeFirst) { stroke(); fill(); } else { fill(); }
          x += r.w;
        }
      }
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
    if ('letterSpacing' in ctx) ctx.letterSpacing = '0px';
  }

  const TILE = 512, CELL = 400, KEEP = 64, OVERVIEW = 2400;

  function boxOf(op) {
    let b;
    try { b = op.el.getBBox(); } catch { b = null; }
    if (!b || (!b.width && !b.height && op.type === 'text')) return null;
    const m = op.m, pad = (op.style?.width || 0) / 2 + 2;
    const xs = [b.x, b.x + b.width].flatMap(x => [b.y, b.y + b.height].map(y => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]));
    const X = xs.map(p => p[0]), Y = xs.map(p => p[1]);
    return [Math.min(...X) - pad, Math.min(...Y) - pad, Math.max(...X) + pad, Math.max(...Y) + pad];
  }

  const free = el => { if (el.tagName === 'IMG') URL.revokeObjectURL(el.src); else el.width = el.height = 0; };

  function layerEl(host, level) {
    const el = document.createElement('div');
    el.className = 'raster-layer';
    Object.assign(el.style, { position: 'absolute', left: '0', top: '0', transformOrigin: '0 0', willChange: 'transform' });
    host.appendChild(el);
    return { el, level, tiles: new Map(), stale: false };
  }

  class SvgRaster {
    constructor(root, host) {
      this.root = root; this.host = host; this.ops = []; this.cells = new Map(); this.dirty = true;
      this.layers = []; this.overview = null; this.queue = []; this.pumping = 0; this.renders = 0;
      this.t = { k: 1, x: 0, y: 0 }; this.w = 0; this.h = 0; this.dpr = 1;
    }
    invalidate() { this.dirty = true; }
    rebuild() {
      const out = [];
      for (const child of this.root.children) walk(child, [1, 0, 0, 1, 0, 0], 1, out);
      const cells = new Map(), bounds = [Infinity, Infinity, -Infinity, -Infinity];
      out.forEach((op, i) => {
        const b = boxOf(op);
        op.box = b; op.i = i; delete op.el;
        if (!b) return;
        bounds[0] = Math.min(bounds[0], b[0]); bounds[1] = Math.min(bounds[1], b[1]); bounds[2] = Math.max(bounds[2], b[2]); bounds[3] = Math.max(bounds[3], b[3]);
        for (let gx = Math.floor(b[0] / CELL); gx <= Math.floor(b[2] / CELL); gx++) for (let gy = Math.floor(b[1] / CELL); gy <= Math.floor(b[3] / CELL); gy++) {
          const key = gx + ',' + gy; let list = cells.get(key); if (!list) cells.set(key, list = []); list.push(op);
        }
      });
      this.ops = out; this.cells = cells; this.bounds = Number.isFinite(bounds[0]) ? bounds : [0, 0, 1, 1]; this.dirty = false;
      for (const layer of this.layers) layer.stale = true;
      this.overviewStale = true;
    }
    resize(w, h, dpr) {
      if (this.dpr !== dpr) { for (const layer of this.layers) layer.stale = true; this.overviewStale = true; }
      this.w = w; this.h = h; this.dpr = dpr;
    }
    opsIn(x0, y0, x1, y1) {
      const seen = new Set(), list = [];
      for (let gx = Math.floor(x0 / CELL); gx <= Math.floor(x1 / CELL); gx++) for (let gy = Math.floor(y0 / CELL); gy <= Math.floor(y1 / CELL); gy++) {
        for (const op of this.cells.get(gx + ',' + gy) || []) {
          if (seen.has(op)) continue; seen.add(op);
          const b = op.box; if (b[0] > x1 || b[2] < x0 || b[1] > y1 || b[3] < y0) continue;
          list.push(op);
        }
      }
      return list.sort((a, b) => a.i - b.i);
    }
    drawOverview() {
      const [x0, y0, x1, y1] = this.bounds, bw = x1 - x0, bh = y1 - y0, level = Math.min(1, OVERVIEW / Math.max(bw, bh));
      if (!this.overview) { this.overview = layerEl(this.host, level); this.host.insertBefore(this.overview.el, this.host.firstChild); this.overview.canvas = document.createElement('canvas'); this.overview.el.appendChild(this.overview.canvas); }
      if (this.overview.img) { URL.revokeObjectURL(this.overview.img.src); this.overview.img.replaceWith(this.overview.canvas = document.createElement('canvas')); this.overview.img = null; }
      const o = this.overview, c = o.canvas, W = Math.ceil(bw * level), H = Math.ceil(bh * level), dpr = Math.min(this.dpr, 2, Math.sqrt(12e6 / (W * H)));
      o.level = level;
      c.width = Math.ceil(W * dpr); c.height = Math.ceil(H * dpr);
      Object.assign(c.style, { position: 'absolute', left: x0 * level + 'px', top: y0 * level + 'px', width: W + 'px', height: H + 'px' });
      const ctx = c.getContext('2d');
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, c.width, c.height);
      draw(ctx, this.ops.filter(op => op.box), level * dpr, -x0 * level * dpr, -y0 * level * dpr, this.bounds);
      this.overviewStale = false;
    }
    renderTile(layer, ix, iy) {
      const key = ix + ',' + iy;
      if (layer.tiles.has(key)) return;
      const dpr = this.dpr, L = layer.level, c = document.createElement('canvas');
      c.width = c.height = Math.round(TILE * dpr);
      Object.assign(c.style, { position: 'absolute', left: ix * TILE + 'px', top: iy * TILE + 'px', width: TILE + 'px', height: TILE + 'px' });
      const ctx = c.getContext('2d'), x0 = ix * TILE / L, y0 = iy * TILE / L, x1 = (ix + 1) * TILE / L, y1 = (iy + 1) * TILE / L;
      if (this.before) this.before(ctx, { k: L, x: -ix * TILE, y: -iy * TILE }, TILE, TILE, dpr);
      draw(ctx, this.opsIn(x0, y0, x1, y1), L * dpr, -ix * TILE * dpr, -iy * TILE * dpr, [x0, y0, x1, y1]);
      layer.el.appendChild(c); layer.tiles.set(key, c); this.renders++;
    }
    freeze(layer, key) {
      const c = layer.tiles.get(key);
      if (!c || c.tagName !== 'CANVAS' || c.freezing) return false;
      c.freezing = true;
      c.toBlob(blob => {
        if (!blob || layer.tiles.get(key) !== c) return;
        const img = new Image(); img.src = URL.createObjectURL(blob);
        Object.assign(img.style, { position: 'absolute', left: c.style.left, top: c.style.top, width: c.style.width, height: c.style.height });
        img.decode().then(() => { if (layer.tiles.get(key) !== c) { URL.revokeObjectURL(img.src); return; } c.replaceWith(img); c.width = c.height = 0; layer.tiles.set(key, img); }, () => URL.revokeObjectURL(img.src));
      });
      return true;
    }
    freezeOverview() {
      const o = this.overview, c = o?.canvas;
      if (!c || o.img || c.freezing) return false;
      c.freezing = true;
      c.toBlob(blob => {
        if (!blob || o.canvas !== c) return;
        const img = new Image(); img.src = URL.createObjectURL(blob); img.style.cssText = c.style.cssText;
        img.decode().then(() => { if (o.canvas !== c) { URL.revokeObjectURL(img.src); return; } c.replaceWith(img); o.img = img; }, () => URL.revokeObjectURL(img.src));
      });
      return true;
    }
    range(layer, pad) {
      const t = this.t, s = t.k / layer.level;
      const x0 = -t.x / s, y0 = -t.y / s, x1 = (this.w - t.x) / s, y1 = (this.h - t.y) / s;
      return [Math.floor(x0 / TILE) - pad, Math.floor(y0 / TILE) - pad, Math.floor(x1 / TILE) + pad, Math.floor(y1 / TILE) + pad];
    }
    missing(layer, pad) {
      const [a, b, c, d] = this.range(layer, pad), out = [], cx = (a + c) / 2, cy = (b + d) / 2;
      for (let ix = a; ix <= c; ix++) for (let iy = b; iy <= d; iy++) if (!layer.tiles.has(ix + ',' + iy)) out.push([ix, iy, Math.hypot(ix - cx, iy - cy)]);
      return out.sort((p, q) => p[2] - q[2]);
    }
    trim(layer) {
      if (layer.tiles.size <= KEEP) return;
      const [a, b, c, d] = this.range(layer, 0), cx = (a + c) / 2, cy = (b + d) / 2;
      const far = [...layer.tiles.keys()].map(k => { const [x, y] = k.split(',').map(Number); return [k, Math.hypot(x - cx, y - cy)]; }).sort((p, q) => q[1] - p[1]);
      for (const [k] of far.slice(0, layer.tiles.size - KEEP)) { const c = layer.tiles.get(k); free(c); c.remove(); layer.tiles.delete(k); }
    }
    drop(layer) { for (const c of layer.tiles.values()) free(c); layer.el.remove(); this.layers = this.layers.filter(l => l !== layer); }
    place() {
      const t = this.t, d = this.dpr;
      const set = (layer) => {
        const s = t.k / layer.level, x = s === 1 ? Math.round(t.x * d) / d : t.x, y = s === 1 ? Math.round(t.y * d) / d : t.y;
        layer.el.style.transform = s === 1 ? `translate3d(${x}px,${y}px,0)` : `translate3d(${x}px,${y}px,0) scale(${s})`;
      };
      if (this.overview) set(this.overview);
      for (const layer of this.layers) set(layer);
    }
    settleLayers() {
      const front = this.layers[this.layers.length - 1];
      if (front && this.layers.length > 1 && !this.missing(front, 0).length) for (const old of this.layers.slice(0, -1)) this.drop(old);
    }
    pump() {
      this.pumping = 0;
      const front = this.layers[this.layers.length - 1];
      if (!front) return;
      const start = performance.now();
      let todo = this.live ? [] : this.missing(front, 0);
      if (!todo.length && !this.live) todo = this.missing(front, 2);
      while (todo.length && performance.now() - start < 7) { const [ix, iy] = todo.shift(); this.renderTile(front, ix, iy); }
      this.settleLayers(); this.trim(front);
      let busy = todo.length > 0;
      if (!busy && !this.live) {
        if (this.overviewStale) { this.drawOverview(); busy = true; }
        else if (this.freezeOverview()) busy = true;
        else for (const key of front.tiles.keys()) if (this.freeze(front, key)) { busy = true; break; }
      }
      if (busy) this.pumping = requestAnimationFrame(() => this.pump());
    }
    paint(t, before, live) {
      this.t = { k: t.k, x: t.x, y: t.y }; this.before = before; this.live = live;
      if (this.dirty) this.rebuild();
      if (!this.overview) this.drawOverview();
      let front = this.layers[this.layers.length - 1];
      const ratio = front ? t.k / front.level : 1;
      if (!front || front.stale || (!live && Math.abs(ratio - 1) > 1e-3) || ratio > 2 || ratio < 0.5) {
        const next = layerEl(this.host, t.k);
        this.layers.push(next);
        while (this.layers.length > 2) this.drop(this.layers[0]);
        if (front && front.stale && !live) for (const [ix, iy] of this.missing(next, 0)) this.renderTile(next, ix, iy);
        front = next;
      }
      this.place();
      this.settleLayers();
      if (!this.pumping) this.pumping = requestAnimationFrame(() => this.pump());
    }
  }
  window.SvgRaster = SvgRaster;
})();
