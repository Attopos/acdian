# Offline reader libraries

These assets are bundled locally. The reader does not load scripts, stylesheets,
or fonts from a CDN.

- **Marked 18.1.1** — https://github.com/markedjs/marked — MIT (`marked.LICENSE`).
- **DOMPurify 3.4.16** — https://github.com/cure53/DOMPurify — Apache-2.0 OR MPL-2.0 (`dompurify.LICENSE`, `dompurify.LICENSE-MPL`).
- **KaTeX 0.19.0** — https://github.com/KaTeX/KaTeX — MIT (`katex.LICENSE`). Font files are included under `fonts/`.

Markdown HTML is sanitized before insertion. KaTeX receives only extracted math
text, with trusted commands disabled. PDF previews use sandboxed frames and
always include a native-app navigation link.
