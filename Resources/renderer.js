/* acdian offline reader. The native app owns file access and navigation. */
(() => {
  'use strict';

  const content = document.getElementById('content');
  const state = { currentPath: '', assets: {}, notes: {}, footnotes: new Map(), references: [] };
  const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const plainLabel = target => String(target).split('#')[0].split('/').pop().replace(/\.md$/i, '') || String(target);
  const safeDecode = value => { try { return decodeURIComponent(value); } catch { return value; } };
  const isExternal = target => /^(?:https?:|mailto:)/i.test(String(target).trim());
  const isPDF = target => /\.pdf(?:[?#]|$)/i.test(target);
  const isImage = target => /\.(?:png|jpe?g|gif|webp|avif|svg|bmp|tiff?|heic)(?:[?#]|$)/i.test(target);
  const post = message => {
    if (window.webkit?.messageHandlers?.acdian) window.webkit.messageHandlers.acdian.postMessage(message);
  };

  function resourceURL(rawTarget) {
    const raw = String(rawTarget || '').trim();
    if (!raw || /^(?:javascript|vbscript|file|blob):/i.test(raw)) return '';
    if (/^data:/i.test(raw)) return /^data:image\/(?:png|jpe?g|gif|webp|avif|bmp);/i.test(raw) ? raw : '';
    if (/^https?:\/\//i.test(raw)) return raw;
    if (/^[a-z][a-z\d+.-]*:/i.test(raw) && !raw.startsWith('acdian-resource:')) return '';
    if (raw.startsWith('acdian-resource:')) return raw;
    if (state.assets[raw]) return String(state.assets[raw]);
    const split = raw.indexOf('#');
    const path = split < 0 ? raw : raw.slice(0, split);
    const fragment = split < 0 ? '' : raw.slice(split + 1);
    return `acdian-resource://vault/${encodeURIComponent(safeDecode(path))}?from=${encodeURIComponent(state.currentPath)}${fragment ? '#' + fragment.replace(/[\s<>"']/g, encodeURIComponent) : ''}`;
  }

  function linkHTML(target, label, extraClass = '') {
    return `<a href="#" class="note-link ${extraClass}" data-acdian-target="${escapeHTML(target)}">${label}</a>`;
  }

  function embedHTML(target, alias = '') {
    const caption = plainLabel(target);
    if (isPDF(target)) return `<div class="pdf-embed" data-acdian-pdf="${escapeHTML(target)}"></div>`;
    if (isImage(target) || /^(?:https?:|data:image\/)/i.test(target)) {
      const dimensions = /^(\d+)(?:x(\d+))?$/.exec(alias);
      return `<img class="note-image" data-acdian-resource="${escapeHTML(target)}" alt="${escapeHTML(dimensions ? caption : alias || caption)}"${dimensions ? ` width="${Math.min(3000, Number(dimensions[1]))}"${dimensions[2] ? ` height="${Math.min(3000, Number(dimensions[2]))}"` : ''}` : ''}>`;
    }
    return linkHTML(target, `<span class="embed-symbol">↗</span><span>${escapeHTML(alias || caption)}</span><span class="embed-caption">打开文件</span>`, 'file-embed');
  }

  const extensions = [
    {
      name: 'wiki', level: 'inline',
      start: src => /!?\[\[/.exec(src)?.index,
      tokenizer(src) {
        const match = /^(!?)\[\[([^\]\n]+)\]\]/.exec(src);
        if (match) {
          const [target, ...alias] = match[2].split('|');
          return { type: 'wiki', raw: match[0], embed: !!match[1], target: target.trim(), alias: alias.join('|').trim() };
        }
      },
      renderer(token) {
        return token.embed ? embedHTML(token.target, token.alias) : linkHTML(token.target, escapeHTML(token.alias || plainLabel(token.target)));
      }
    },
    {
      name: 'highlight', level: 'inline', start: src => src.indexOf('=='),
      tokenizer(src) {
        const match = /^==(?=\S)([^\n]+?\S|\S)==/.exec(src);
        if (match) return { type: 'highlight', raw: match[0], tokens: this.lexer.inlineTokens(match[1]) };
      },
      renderer(token) { return `<mark>${this.parser.parseInline(token.tokens)}</mark>`; }
    },
    {
      name: 'comment', level: 'inline', start: src => src.indexOf('%%'),
      tokenizer(src) {
        const match = /^%%[\s\S]*?%%/.exec(src);
        if (match) return { type: 'comment', raw: match[0] };
      }, renderer() { return ''; }
    },
    {
      name: 'mathBlock', level: 'block', start: src => src.indexOf('$$'),
      tokenizer(src) {
        const match = /^\$\$[ \t]*\n?([\s\S]+?)\n?\$\$(?:[ \t]*\n|$)/.exec(src);
        if (match) return { type: 'mathBlock', raw: match[0], text: match[1] };
      }, renderer(token) { return renderMath(token.text, true); }
    },
    {
      name: 'mathInline', level: 'inline', start: src => src.indexOf('$'),
      tokenizer(src) {
        const match = /^\$(?![\s$])((?:\\.|[^$\n])+?)(?<!\s)\$(?!\d)/.exec(src);
        if (match) return { type: 'mathInline', raw: match[0], text: match[1] };
      }, renderer(token) { return renderMath(token.text, false); }
    },
    {
      name: 'footnoteDefinition', level: 'block', start: src => src.indexOf('[^'),
      tokenizer(src) {
        const match = /^\[\^([^\]\n]+)\]:[ \t]*([^\n]*)(?:\n|$)/.exec(src);
        if (!match) return;
        let raw = match[0], text = match[2];
        const rest = src.slice(raw.length);
        const continuation = /^(?:(?: {4}|\t)[^\n]*(?:\n|$)|\n(?=(?: {4}|\t)))*/.exec(rest)?.[0] || '';
        raw += continuation;
        text += continuation ? '\n' + continuation.replace(/^(?: {4}|\t)/gm, '') : '';
        state.footnotes.set(match[1], text);
        return { type: 'footnoteDefinition', raw };
      }, renderer() { return ''; }
    },
    {
      name: 'footnoteReference', level: 'inline', start: src => src.indexOf('[^'),
      tokenizer(src) {
        const match = /^\[\^([^\]\n]+)\]/.exec(src);
        if (match) return { type: 'footnoteReference', raw: match[0], label: match[1] };
      },
      renderer(token) {
        let index = state.references.indexOf(token.label);
        if (index < 0) index = state.references.push(token.label) - 1;
        return `<sup class="footnote-ref"><a href="#fn-${index + 1}" id="fnref-${index + 1}">${index + 1}</a></sup>`;
      }
    }
  ];

  // KaTeX produces its own vetted HTML/CSS. Insert it only after note HTML is sanitized.
  const mathItems = [];
  function renderMath(text, display) {
    const index = mathItems.push({ text, display }) - 1;
    return `<${display ? 'div' : 'span'} class="math-placeholder" data-acdian-math="${index}"></${display ? 'div' : 'span'}>`;
  }

  const engine = new marked.Marked({
    gfm: true, breaks: false, extensions,
    renderer: {
      link({ href, title, tokens }) {
        const label = this.parser.parseInline(tokens);
        return `<a href="${escapeHTML(href)}"${title ? ` title="${escapeHTML(title)}"` : ''}>${label}</a>`;
      },
      image({ href, text, title }) {
        if (isPDF(href)) return embedHTML(href);
        return `<img data-acdian-resource="${escapeHTML(href)}" alt="${escapeHTML(text)}"${title ? ` title="${escapeHTML(title)}"` : ''}>`;
      }
    }
  });

  function sanitize(html) {
    return DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form', 'textarea', 'select', 'button', 'base', 'link', 'meta', 'audio', 'video', 'source'],
      FORBID_ATTR: ['style', 'srcset', 'formaction', 'autofocus', 'contenteditable'],
      ALLOW_DATA_ATTR: true, SANITIZE_NAMED_PROPS: true
    });
  }

  function extractFrontmatter(text) {
    const match = /^\uFEFF?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
    if (!match) return { text, properties: [] };
    const properties = match[1].split(/\r?\n/).flatMap(line => {
      const property = /^([^\s:#][^:]*):[ \t]*(.*)$/.exec(line);
      return property ? [[property[1].trim(), property[2].replace(/^['"]|['"]$/g, '').trim()]] : [];
    });
    return { text: text.slice(match[0].length), properties };
  }

  function addProperties(properties) {
    if (!properties.length) return;
    const wrapper = document.createElement('details');
    wrapper.className = 'properties';
    const summary = document.createElement('summary');
    summary.textContent = `属性 · ${properties.length}`;
    wrapper.append(summary);
    const list = document.createElement('dl');
    properties.forEach(([key, value]) => {
      const term = document.createElement('dt'), description = document.createElement('dd');
      term.textContent = key; description.textContent = value || '—'; list.append(term, description);
    });
    wrapper.append(list); content.prepend(wrapper);
  }

  function decorateCallouts() {
    const labels = { note: '笔记', abstract: '摘要', summary: '摘要', info: '信息', todo: '待办', tip: '提示', hint: '提示', success: '完成', check: '完成', question: '问题', help: '帮助', warning: '注意', caution: '注意', danger: '警告', failure: '失败', bug: '问题', example: '示例', quote: '引用' };
    content.querySelectorAll('blockquote').forEach(quote => {
      const first = quote.firstElementChild;
      if (first?.tagName !== 'P') return;
      const match = /^\[!([\w-]+)\]([+-])?(?:[ \t]+([^\n]*))?(?:\n|$)/.exec(first.textContent);
      if (!match) return;
      const type = match[1].toLowerCase();
      // Remove the directive by text position while preserving inline markup in the body.
      const walker = document.createTreeWalker(first, NodeFilter.SHOW_TEXT);
      let remaining = match[0].length, node;
      while (remaining && (node = walker.nextNode())) {
        const remove = Math.min(remaining, node.textContent.length);
        node.textContent = node.textContent.slice(remove); remaining -= remove;
      }
      if (!first.textContent.trim() && !first.querySelector('img')) first.remove();
      const container = match[2] ? document.createElement('details') : document.createElement('aside');
      container.className = 'callout'; container.dataset.callout = type;
      if (match[2] === '+') container.open = true;
      const title = document.createElement(match[2] ? 'summary' : 'div');
      title.className = 'callout-title'; title.textContent = match[3]?.trim() || labels[type] || type;
      const symbol = document.createElement('span'); symbol.className = 'callout-icon'; symbol.textContent = ['warning', 'danger', 'caution', 'failure', 'bug'].includes(type) ? '!' : '✦'; title.prepend(symbol);
      container.append(title);
      const body = document.createElement('div'); body.className = 'callout-body';
      while (quote.firstChild) body.append(quote.firstChild);
      container.append(body); quote.replaceWith(container);
    });
  }

  function decorateResources() {
    content.querySelectorAll('img').forEach(img => {
      const target = img.dataset.acdianResource || img.getAttribute('src') || '';
      const url = resourceURL(target);
      img.removeAttribute('src');
      if (!url) { img.replaceWith(document.createTextNode(img.alt || '无法显示图片')); return; }
      img.src = url; img.loading = 'lazy'; img.decoding = 'async';
      img.dataset.acdianTarget = target;
      img.addEventListener('error', () => {
        const placeholder = document.createElement('a');
        placeholder.className = 'missing-image'; placeholder.href = '#'; placeholder.dataset.acdianTarget = target;
        placeholder.textContent = `▧ ${img.alt || plainLabel(target)} · 图片未找到`;
        img.replaceWith(placeholder);
      }, { once: true });
    });
    content.querySelectorAll('[data-acdian-pdf]').forEach(container => {
      const target = container.dataset.acdianPdf, url = resourceURL(target);
      const header = document.createElement('a');
      header.className = 'pdf-header'; header.href = '#'; header.dataset.acdianTarget = target;
      const badge = document.createElement('span'); badge.className = 'pdf-badge'; badge.textContent = 'PDF';
      const label = document.createElement('span'); label.className = 'pdf-name'; label.textContent = plainLabel(target);
      const action = document.createElement('span'); action.className = 'pdf-action'; action.textContent = '打开 ↗';
      header.append(badge, label, action); container.append(header);

    });
  }

  function decorateHeadings() {
    const seen = new Map();
    content.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(heading => {
      const text = heading.textContent.trim();
      const base = text.toLocaleLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-').replace(/^-+|-+$/g, '') || 'heading';
      const count = seen.get(base) || 0; seen.set(base, count + 1);
      heading.id = count ? `${base}-${count}` : base;
      heading.dataset.heading = text;
    });
    content.querySelectorAll('p,li').forEach(block => {
      const last = block.lastChild;
      if (last?.nodeType !== Node.TEXT_NODE) return;
      const match = /(?:^|\s)\^([\w-]+)\s*$/.exec(last.textContent);
      if (match) { block.id = match[1]; last.textContent = last.textContent.slice(0, match.index); }
    });
  }

  function decorateCode() {
    content.querySelectorAll('pre').forEach(pre => {
      const code = pre.querySelector('code');
      if (!code) return;
      const bar = document.createElement('div'); bar.className = 'code-bar';
      const label = document.createElement('span'); label.textContent = code.className.replace(/^language-/, '') || '文本';
      const copy = document.createElement('button'); copy.type = 'button'; copy.className = 'copy-button'; copy.textContent = '复制'; copy.setAttribute('aria-label', '复制代码');
      copy.addEventListener('click', async () => {
        try {
          if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(code.textContent);
          else {
            const input = document.createElement('textarea'); input.value = code.textContent; document.body.append(input); input.select();
            const copied = document.execCommand('copy'); input.remove(); if (!copied) throw new Error('copy');
          }
          copy.textContent = '已复制';
        } catch { copy.textContent = '请选中复制'; }
        window.setTimeout(() => { copy.textContent = '复制'; }, 1800);
      });
      bar.append(label, copy); pre.prepend(bar);
    });
  }

  function decorateMath() {
    content.querySelectorAll('[data-acdian-math]').forEach(node => {
      const item = mathItems[Number(node.dataset.acdianMath)];
      if (!item) return;
      try { katex.render(item.text, node, { displayMode: item.display, throwOnError: false, trust: false, strict: 'ignore', output: 'htmlAndMathml' }); }
      catch { node.textContent = item.text; }
    });
  }

  window.acdianScrollTo = rawAnchor => {
    const anchor = safeDecode(String(rawAnchor || '').replace(/^#/, '')).replace(/^\^/, '');
    if (!anchor) { window.scrollTo({ top: 0 }); return true; }
    const target = document.getElementById(anchor) || document.getElementById('user-content-' + anchor) || Array.from(content.querySelectorAll('[data-heading]')).find(node => node.dataset.heading.toLocaleLowerCase() === anchor.toLocaleLowerCase()) || document.getElementById(anchor.toLocaleLowerCase().replace(/\s+/g, '-'));
    if (!target) return false;
    target.scrollIntoView({ behavior: 'smooth', block: 'start' }); return true;
  };

  window.acdianRender = payload => {
    const previousPath = state.currentPath;
    const savedScroll = window.scrollY;
    state.currentPath = String(payload?.currentPath || '');
    state.assets = payload?.assets || {}; state.notes = payload?.notes || {};
    state.footnotes = new Map(); state.references = []; mathItems.length = 0;
    const extracted = extractFrontmatter(String(payload?.text ?? ''));
    let html;
    try {
      html = engine.parse(extracted.text);
      if (state.references.length) {
        const items = state.references.map((label, index) => {
          const body = state.footnotes.get(label);
          return `<li id="fn-${index + 1}">${body === undefined ? escapeHTML(label) : engine.parse(body)} <a class="footnote-back" href="#fnref-${index + 1}" aria-label="返回引用">↩</a></li>`;
        }).join('');
        html += `<section class="footnotes" aria-label="脚注"><hr><ol>${items}</ol></section>`;
      }
      content.innerHTML = sanitize(html);
      if (!content.textContent.trim() && !content.querySelector('img,[data-acdian-pdf]')) {
        const empty = document.createElement('div'); empty.className = 'empty-note';
        const title = document.createElement('h1'); title.textContent = payload?.title || '空白笔记';
        const subtitle = document.createElement('p'); subtitle.textContent = '切换到编辑模式开始。'; empty.append(title, subtitle); content.append(empty);
      }
      addProperties(extracted.properties); decorateCallouts(); decorateResources(); decorateHeadings(); decorateCode(); decorateMath();
      content.querySelectorAll('input').forEach(input => { if (input.type === 'checkbox') input.disabled = true; else input.remove(); });
      content.querySelectorAll('a[href]').forEach(link => {
        const href = link.getAttribute('href') || '';
        if (isExternal(href)) { link.classList.add('external-link'); link.rel = 'noreferrer noopener'; }
      });
      document.title = payload?.title || 'acdian';
      if (payload?.anchor) window.acdianScrollTo(payload.anchor);
      else if (previousPath !== state.currentPath) window.scrollTo({ top: 0 });
      else window.scrollTo({ top: savedScroll });
      post({ type: 'rendered', from: state.currentPath });
    } catch (error) {
      content.replaceChildren(); const message = document.createElement('p'); message.className = 'render-error';
      message.textContent = `笔记暂时无法渲染：${error.message}`; content.append(message);
      const fallback = document.createElement('pre'); fallback.textContent = String(payload?.text ?? ''); content.append(fallback);
    }
  };

  content.addEventListener('click', event => {
    const element = event.target.closest('a,[data-acdian-target]');
    if (!element) return;
    const target = element.dataset.acdianTarget || element.getAttribute('href') || '';
    if (!target) return;
    event.preventDefault();
    if (target.startsWith('#')) { window.acdianScrollTo(target); return; }
    if (/^(?:javascript|vbscript|data|file):/i.test(target.trim())) return;
    if (isExternal(target)) post({ type: 'external', target });
    else if (!/^[a-z][a-z\d+.-]*:/i.test(target)) post({ type: 'navigate', target: state.notes[target] || target, from: state.currentPath });
  });

  // Pure helpers are available to local regression tests, without privileged native access.
  window.acdianReader = Object.freeze({ resourceURL, extractFrontmatter });
  post({ type: 'ready' });
})();
