/* Runs one acdian-interactive block. The editor loads this page in a sandboxed
   frame (scripts only, no same origin, no network) and posts the block's HTML. */
(() => {
  'use strict';
  let started = false, theme = 'dark', language = 'en', lastHeight = 0;
  const themeListeners = new Set();
  const showError = message => {
    let box = document.getElementById('acdian-error');
    if (!box) { box = document.createElement('pre'); box.id = 'acdian-error'; document.body.append(box); }
    box.textContent += (box.textContent ? '\n' : '') + message;
  };
  window.addEventListener('error', event => {
    // Block errors are reported by the guards below. What still arrives hidden
    // as "Script error." is WebKit's harmless ResizeObserver loop notice.
    if (event.message === 'Script error.' || /ResizeObserver loop/.test(event.message)) return;
    showError(event.message + (event.lineno ? ` (line ${event.lineno})` : ''));
  });
  window.addEventListener('unhandledrejection', event => showError(String(event.reason?.message || event.reason)));
  // The frame's origin is opaque, so WebKit hides the message of any error
  // that reaches the window as "Script error.". Block code and the callbacks it
  // hands to the browser run inside try/catch instead, which keeps the message.
  const report = error => showError(error instanceof Error ? `${error.name}: ${error.message}${error.line ? ` (line ${error.line})` : ''}` : String(error));
  const guarded = new WeakMap();
  const guard = callback => {
    if (typeof callback !== 'function') return callback;
    if (!guarded.has(callback)) guarded.set(callback, function (...args) { try { return callback.apply(this, args); } catch (error) { report(error); } });
    return guarded.get(callback);
  };
  for (const name of ['setTimeout', 'setInterval', 'requestAnimationFrame', 'queueMicrotask']) {
    const original = window[name];
    window[name] = function (callback, ...rest) { return original.call(window, guard(callback), ...rest); };
  }
  const addListener = EventTarget.prototype.addEventListener, removeListener = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function (type, listener, options) { return addListener.call(this, type, guard(listener), options); };
  EventTarget.prototype.removeEventListener = function (type, listener, options) { return removeListener.call(this, type, guarded.get(listener) || listener, options); };
  for (const proto of [HTMLElement.prototype, SVGElement.prototype, Document.prototype, Window.prototype]) {
    for (const name of Object.getOwnPropertyNames(proto).filter(name => name.startsWith('on'))) {
      const descriptor = Object.getOwnPropertyDescriptor(proto, name);
      if (!descriptor?.set || !descriptor.configurable) continue;
      Object.defineProperty(proto, name, { ...descriptor, set(value) { descriptor.set.call(this, guard(value)); } });
    }
  }
  for (const name of ['ResizeObserver', 'MutationObserver', 'IntersectionObserver']) {
    const Original = window[name];
    if (Original) window[name] = class extends Original { constructor(callback, options) { super(guard(callback), options); } };
  }
  function applyTheme(value) {
    theme = value === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = theme;
    themeListeners.forEach(listener => { try { listener(theme); } catch (error) { showError(error.message); } });
    window.dispatchEvent(new CustomEvent('acdian:theme', { detail: { theme } }));
  }
  window.acdian = Object.freeze({
    get theme() { return theme; },
    get language() { return language; },
    color: name => getComputedStyle(document.documentElement).getPropertyValue('--acd-' + name).trim(),
    onTheme(listener) { themeListeners.add(listener); return () => themeListeners.delete(listener); }
  });
  // The frame is as tall as its content; the editor caps the height.
  function reportSize() {
    if (!document.body) return;
    const height = Math.ceil(document.body.scrollHeight);
    if (height !== lastHeight) { lastHeight = height; parent.postMessage({ type: 'acdian-interactive:size', height }, '*'); }
  }
  async function run(source) {
    const parsed = new DOMParser().parseFromString(String(source), 'text/html');
    for (const node of [...parsed.head.childNodes]) document.head.append(document.adoptNode(node));
    for (const node of [...parsed.body.childNodes]) document.body.append(document.adoptNode(node));
    // Not a ResizeObserver: one on the body would trip WebKit's loop error,
    // shown only as "Script error.", whenever a block's own observer changes the layout.
    let pending = 0;
    const schedule = () => { if (!pending) pending = requestAnimationFrame(() => { pending = 0; reportSize(); }); };
    new MutationObserver(schedule).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    window.addEventListener('load', schedule); document.fonts?.ready.then(schedule);
    setInterval(reportSize, 500);
    // Parsed scripts do not run; each is replaced, in order, by one that does.
    for (const old of [...document.querySelectorAll('script')]) {
      if (old.src && /\/frame\.js$/.test(old.src)) continue;
      const script = document.createElement('script');
      for (const { name, value } of old.attributes) script.setAttribute(name, value);
      // Library errors keep their messages: the frame's own origin is opaque.
      if (old.src && !script.hasAttribute('crossorigin')) script.crossOrigin = 'anonymous';
      if (old.src) {
        await new Promise(resolve => {
          script.onload = resolve;
          script.onerror = () => { showError('Could not load ' + old.getAttribute('src')); resolve(); };
          old.replaceWith(script);
        });
      } else if (!old.type || /^(?:text|application)\/(?:javascript|ecmascript)$/i.test(old.type)) {
        // Run as a global script would; top-level var and function declarations stay shared.
        old.remove();
        try { (0, eval)(old.textContent); } catch (error) { report(error); }
      } else { script.textContent = old.textContent; old.replaceWith(script); }
    }
    window.dispatchEvent(new Event('acdian:ready'));
    reportSize();
  }
  window.addEventListener('message', event => {
    if (event.source !== parent || !event.data || typeof event.data !== 'object') return;
    if (event.data.type === 'acdian-interactive:theme') applyTheme(event.data.theme);
    if (event.data.type === 'acdian-interactive:run' && !started) {
      started = true; language = String(event.data.language || 'en');
      document.documentElement.lang = language;
      applyTheme(event.data.theme);
      run(event.data.source).catch(error => showError(error.message));
    }
  });
})();
