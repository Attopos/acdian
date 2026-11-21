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

  const TILE = 512, CELL = 400, KEEP = 64, OVERVIEW = 1400;

  function boxOf(op) {
    let b;
    try { b = op.el.getBBox(); } catch { b = null; }
    if (!b || (!b.width && !b.height && op.type === 'text')) return null;
    const m = op.m, pad = (op.style?.width || 0) / 2 + 2;
    const xs = [b.x, b.x + b.width].flatMap(x => [b.y, b.y + b.height].map(y => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]));
    const X = xs.map(p => p[0]), Y = xs.map(p => p[1]);
    return [Math.min(...X) - pad, Math.min(...Y) - pad, Math.max(...X) + pad, Math.max(...Y) + pad];
  }

  const PENDING = { pending: true };
  const free = el => { if (el?.tagName === 'IMG') URL.revokeObjectURL(el.src); else if (el?.tagName === 'CANVAS') el.width = el.height = 0; };
  const place = (el, x, y, w, h) => Object.assign(el.style, { position: 'absolute', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' });

  function layerEl(host, level) {
    const el = document.createElement('div');
    el.className = 'raster-layer';
    Object.assign(el.style, { position: 'absolute', left: '0', top: '0', transformOrigin: '0 0', willChange: 'transform' });
    host.appendChild(el);
    return { el, level, tiles: new Map(), stale: false, bridge: null };
  }

  function toImage(canvas, done) {
    canvas.toBlob(blob => {
      if (!blob) return;
      const img = new Image(); img.src = URL.createObjectURL(blob);
      img.decode().then(() => done(img), () => URL.revokeObjectURL(img.src));
    });
  }

  class SvgRaster {
    constructor(root, host) {
      this.root = root; this.host = host; this.ops = []; this.cells = new Map(); this.dirty = true;
      this.layers = []; this.overview = null; this.pumping = 0; this.renders = 0; this.scratch = document.createElement('canvas');
      this.t = { k: 1, x: 0, y: 0 }; this.w = 0; this.h = 0; this.dpr = 1; this.live = false;
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
    paintArea(ctx, level, lx, ly, w, h, dpr) {
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1;
      if (this.before) this.before(ctx, { k: level, x: -lx, y: -ly }, w, h, dpr); else ctx.clearRect(0, 0, w * dpr, h * dpr);
      const x0 = lx / level, y0 = ly / level, x1 = (lx + w) / level, y1 = (ly + h) / level;
      draw(ctx, this.opsIn(x0, y0, x1, y1), level * dpr, -lx * dpr, -ly * dpr, [x0, y0, x1, y1]);
    }
    drawOverview() {
      const [x0, y0, x1, y1] = this.bounds, bw = x1 - x0, bh = y1 - y0, level = Math.min(1, OVERVIEW / Math.max(bw, bh));
      if (!this.overview) { this.overview = layerEl(this.host, level); this.host.insertBefore(this.overview.el, this.host.firstChild); }
      const o = this.overview, W = Math.ceil(bw * level), H = Math.ceil(bh * level), dpr = Math.min(1, Math.sqrt(4e6 / (W * H)));
      const c = document.createElement('canvas');
      c.width = Math.ceil(W * dpr); c.height = Math.ceil(H * dpr); place(c, x0 * level, y0 * level, W, H);
      const ctx = c.getContext('2d');
      draw(ctx, this.ops.filter(op => op.box), level * dpr, -x0 * level * dpr, -y0 * level * dpr, this.bounds);
      o.level = level; free(o.view); o.view?.remove(); o.el.appendChild(c); o.view = c;
      this.overviewStale = false;
    }
    renderTile(layer, ix, iy) {
      const key = ix + ',' + iy, dpr = this.dpr, c = this.scratch, size = Math.round(TILE * dpr);
      if (c.width !== size) { c.width = c.height = size; }
      this.paintArea(c.getContext('2d'), layer.level, ix * TILE, iy * TILE, TILE, TILE, dpr);
      layer.tiles.set(key, PENDING); this.renders++;
      toImage(c, img => {
        if (!this.layers.includes(layer) || layer.tiles.get(key) !== PENDING) { URL.revokeObjectURL(img.src); return; }
        place(img, ix * TILE, iy * TILE, TILE, TILE); layer.el.appendChild(img); layer.tiles.set(key, img);
        this.settleLayers();
      });
    }
    bridge(layer) {
      const t = this.t, dpr = this.dpr, c = document.createElement('canvas');
      c.width = Math.round(this.w * dpr); c.height = Math.round(this.h * dpr);
      place(c, -t.x, -t.y, this.w, this.h);
      this.paintArea(c.getContext('2d'), layer.level, -t.x, -t.y, this.w, this.h, dpr);
      layer.el.appendChild(c); layer.bridge = c;
    }
    range(layer, pad) {
      const t = this.t, s = t.k / layer.level;
      const x0 = -t.x / s, y0 = -t.y / s, x1 = (this.w - t.x) / s, y1 = (this.h - t.y) / s;
      return [Math.floor(x0 / TILE) - pad, Math.floor(y0 / TILE) - pad, Math.floor(x1 / TILE) + pad, Math.floor(y1 / TILE) + pad];
    }
    missing(layer, pad, ready) {
      const [a, b, c, d] = this.range(layer, pad), out = [], cx = (a + c) / 2, cy = (b + d) / 2;
      for (let ix = a; ix <= c; ix++) for (let iy = b; iy <= d; iy++) { const v = layer.tiles.get(ix + ',' + iy); if (!v || (ready && v === PENDING)) out.push([ix, iy, Math.hypot(ix - cx, iy - cy)]); }
      return out.sort((p, q) => p[2] - q[2]);
    }
    trim(layer) {
      if (layer.tiles.size <= KEEP) return;
      const [a, b, c, d] = this.range(layer, 0), cx = (a + c) / 2, cy = (b + d) / 2;
      const far = [...layer.tiles.keys()].map(k => { const [x, y] = k.split(',').map(Number); return [k, Math.hypot(x - cx, y - cy)]; }).sort((p, q) => q[1] - p[1]);
      for (const [k] of far.slice(0, layer.tiles.size - KEEP)) { const el = layer.tiles.get(k); free(el); el.remove?.(); layer.tiles.delete(k); }
    }
    drop(layer) { for (const el of layer.tiles.values()) free(el); free(layer.bridge); layer.el.remove(); this.layers = this.layers.filter(l => l !== layer); }
    settleLayers() {
      const front = this.layers[this.layers.length - 1];
      if (!front || this.missing(front, 0, true).length) return;
      for (const old of this.layers.slice(0, -1)) this.drop(old);
      if (front.bridge) { free(front.bridge); front.bridge.remove(); front.bridge = null; }
    }
    position() {
      const t = this.t, d = this.dpr;
      const set = layer => {
        const s = t.k / layer.level, x = s === 1 ? Math.round(t.x * d) / d : t.x, y = s === 1 ? Math.round(t.y * d) / d : t.y;
        layer.el.style.transform = s === 1 ? `translate3d(${x}px,${y}px,0)` : `translate3d(${x}px,${y}px,0) scale(${s})`;
      };
      if (this.overview) set(this.overview);
      for (const layer of this.layers) set(layer);
    }
    pump() {
      this.pumping = 0;
      const front = this.layers[this.layers.length - 1];
      if (!front || this.live) return;
      const start = performance.now();
      let todo = this.missing(front, 0);
      if (!todo.length) todo = this.missing(front, 2);
      while (todo.length && performance.now() - start < 6) { const [ix, iy] = todo.shift(); this.renderTile(front, ix, iy); }
      this.trim(front);
      if (todo.length) this.pumping = requestAnimationFrame(() => this.pump());
      else if (this.overviewStale) { clearTimeout(this.later); this.later = setTimeout(() => { if (!this.live && this.overviewStale) this.drawOverview(); }, 800); }
    }
    paint(t, before, live) {
      this.t = { k: t.k, x: t.x, y: t.y }; this.before = before; this.live = live;
      if (this.dirty) this.rebuild();
      if (!this.overview) this.drawOverview();
      let front = this.layers[this.layers.length - 1];
      if (!front || (!live && (front.stale || Math.abs(t.k / front.level - 1) > 1e-3))) {
        const next = layerEl(this.host, t.k);
        this.layers.push(next);
        while (this.layers.length > 2) this.drop(this.layers[0]);
        if (!live) this.bridge(next);
        front = next;
      }
      this.position();
      if (!live && !this.pumping) this.pumping = requestAnimationFrame(() => this.pump());
    }
  }
  window.SvgRaster = SvgRaster;
})();
