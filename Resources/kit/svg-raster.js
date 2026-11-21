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
    for (const c of runs) if (c.runs.length) out.push({ type: 'text', m, opacity, chunk: c });
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
    if (shape) out.push({ type: 'shape', m, opacity: alpha, shape, style });
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
  const BUDGET = 16e6;

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

  class SvgRaster {
    constructor(root, canvas) {
      this.root = root; this.canvas = canvas; this.ctx = canvas.getContext('2d'); this.ops = []; this.dirty = true; this.cache = null; this.renders = 0;
      canvas.style.transformOrigin = '0 0';
    }
    invalidate() { this.dirty = true; }
    rebuild() {
      const out = [];
      for (const child of this.root.children) walk(child, [1, 0, 0, 1, 0, 0], 1, out);
      this.ops = out; this.dirty = false; this.cache = null;
    }
    resize(w, h, dpr) {
      if (this.w !== w || this.h !== h || this.dpr !== dpr) this.cache = null;
      this.w = w; this.h = h; this.dpr = dpr;
    }
    offset(t) {
      const c = this.cache, s = t.k / c.k;
      return { s, left: t.x - s * (c.x + c.m), top: t.y - s * (c.y + c.m) };
    }
    fits(t, live) {
      if (!this.cache) return false;
      const c = this.cache, { s, left, top } = this.offset(t), d = this.dpr;
      if (live ? s < 0.5 || s > 2 : Math.abs(s - 1) > 1e-9) return false;
      if (!live && (Math.abs(left * d - Math.round(left * d)) > 0.01 || Math.abs(top * d - Math.round(top * d)) > 0.01)) return false;
      return left <= 0.5 && top <= 0.5 && left + s * c.cw >= this.w - 0.5 && top + s * c.ch >= this.h - 0.5;
    }
    render(t, before) {
      const { dpr, w, h, canvas, ctx } = this;
      let m = 320;
      while (m > 0 && (w + 2 * m) * (h + 2 * m) * dpr * dpr > BUDGET) m -= 40;
      const cw = w + 2 * m, ch = h + 2 * m, W = Math.round(cw * dpr), H = Math.round(ch * dpr);
      if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
      Object.assign(canvas.style, { width: cw + 'px', height: ch + 'px', left: -m + 'px', top: -m + 'px' });
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1; ctx.clearRect(0, 0, W, H);
      const ox = t.x + m, oy = t.y + m;
      if (before) before(ctx, { k: t.k, x: ox, y: oy }, cw, ch, dpr);
      draw(ctx, this.ops, t.k * dpr, ox * dpr, oy * dpr, [-ox / t.k, -oy / t.k, (cw - ox) / t.k, (ch - oy) / t.k]);
      this.cache = { k: t.k, x: t.x, y: t.y, m, cw, ch };
      this.renders++;
    }
    paint(t, before, live) {
      if (this.dirty) this.rebuild();
      if (!this.fits(t, live)) this.render(t, before);
      const { s, left, top } = this.offset(t), tx = left + this.cache.m, ty = top + this.cache.m;
      this.canvas.style.transform = s === 1 && Math.abs(tx) < 1e-6 && Math.abs(ty) < 1e-6 ? '' : s === 1 ? `translate3d(${tx}px,${ty}px,0)` : `translate3d(${tx}px,${ty}px,0) scale(${s})`;
    }
  }
  window.SvgRaster = SvgRaster;
})();
