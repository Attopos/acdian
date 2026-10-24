# Offline reader libraries

These assets are bundled locally. The reader does not load scripts, stylesheets,
or fonts from a CDN.

- **Marked 18.1.1** — https://github.com/markedjs/marked — MIT (`marked.LICENSE`).
- **DOMPurify 3.4.16** — https://github.com/cure53/DOMPurify — Apache-2.0 OR MPL-2.0 (`dompurify.LICENSE`, `dompurify.LICENSE-MPL`).
- **KaTeX 0.19.0** — https://github.com/KaTeX/KaTeX — MIT (`katex.LICENSE`). Font files are included under `fonts/`.
- **D3 7.9.0** — https://github.com/d3/d3 — ISC (`d3.LICENSE`). Offered only to `acdian-interactive` blocks as `lib/d3.min.js`.

Markdown HTML is sanitized before insertion. KaTeX receives only extracted math
text, with trusted commands disabled. PDF previews use sandboxed frames and
always include a native-app navigation link.

`acdian-interactive` blocks run in sandboxed frames served from
`acdian-resource://interactive/` (`Resources/interactive/`). They may load the
files in this folder as `lib/<name>`, and nothing from the network.
