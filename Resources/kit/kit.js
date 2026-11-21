(() => {
  'use strict';
  const root = document.documentElement;
  const themeListeners = new Set(), languageListeners = new Set(), vars = new Map();
  const normalize = value => value === 'es' ? 'es' : value === 'zh-Hans' || value === 'zh' ? 'zh-Hans' : 'en';
  let theme = root.dataset.theme === 'light' ? 'light' : 'dark', language = normalize(root.lang);
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const notify = (set, value) => set.forEach(fn => { try { fn(value); } catch (error) { console.error(error); } });

  const kit = {
    post(message) {
      try { window.webkit.messageHandlers.acdian.postMessage(message); } catch { (window.__posted ||= []).push(message); }
    },
    mount(name, handlers = {}, api = {}) {
      const target = 'acdian' + name[0].toUpperCase() + name.slice(1);
      window[target] = Object.assign({
        receive(message) {
          if (!message || typeof message !== 'object') return;
          if (message.language) kit.setLanguage(message.language);
          if (message.theme) kit.setTheme(message.theme);
          handlers[message.type]?.(message);
        },
      }, api);
      return window[target];
    },
    ready(extra) { kit.post({ type: 'ready', ...extra }); },

    get theme() { return theme; },
    setTheme(value) {
      const next = value === 'light' ? 'light' : 'dark';
      if (next === theme && root.dataset.theme === next) return;
      theme = next; root.dataset.theme = next; vars.clear();
      notify(themeListeners, next);
    },
    onTheme(fn) { themeListeners.add(fn); return () => themeListeners.delete(fn); },
    cssVar(name, el = root, fallback = '') {
      const key = name + '\u0000' + (el.id || el.tagName);
      if (!vars.has(key)) vars.set(key, getComputedStyle(el).getPropertyValue(name).trim() || fallback);
      return vars.get(key);
    },

    get language() { return language; },
    setLanguage(value) {
      const next = normalize(value);
      if (next === language) return;
      language = next; root.lang = next;
      notify(languageListeners, next);
    },
    onLanguage(fn) { languageListeners.add(fn); return () => languageListeners.delete(fn); },
    strings(table) {
      return (key, ...args) => {
        let text = table[language]?.[key] ?? key;
        args.forEach((value, i) => { text = text.replace('%' + (i + 1), value); });
        return text;
      };
    },

    $: id => document.getElementById(id),
    esc: s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    fold: s => String(s ?? '').normalize('NFKC').toLowerCase(),
    reduced,
    dur: ms => reduced.matches ? 0 : ms,
  };
  window.AcdianKit = kit;
})();
