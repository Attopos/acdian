# Live editor integration checks

Use only synthetic content and the fixture vault. Never edit the user's Obsidian notes during verification.

## Required checks

- Type at the start, middle and end of a rendered paragraph. The Markdown source must retain every input once, including a final newline, Chinese, combining characters and emoji.
- Enter a heading, bold text, a Wiki link, image embed, code fence, table, callout and math. Styling should update without moving the insertion point or interrupting typing.
- Echo the latest change back through `acdianSetDocument` while the cursor is in the middle of text. The next input must remain at that position; Undo/Redo must still work.
- Change only reading font size or editability. Preserve document, selection, scroll position and undo history.
- Load a second document, then Undo. Content from the first document must never enter the second document or a native save.
- Insert an attachment at the current selection using `acdianInsertText`. The source changes exactly once and a single Undo removes the insertion.
- Change document while an attachment request or JavaScript callback is pending. Reject the stale result using document identity.
- Switch from Markdown to PDF/image and back. The latest edit must be saved automatically before leaving; a failed save retains the current editor. The new editor must not accept delayed changes from the old one.
- While opening a slow/cloud note or a new vault, block editing in the old editor; late callbacks must not overwrite new edits.
- Use a Chinese IME to compose and choose candidates near formatting boundaries and immediately before save/navigation. Composition must not be canceled by widget or decoration updates. Simulated DOM composition events are only a smoke test, not proof of real IME behavior.
- Press Cmd-S immediately after typing and immediately after composition ends. Native saved text must include the latest committed input.
- Test a selection spanning a rendered widget and ordinary text. Copy, paste, Delete and Undo must preserve the expected Markdown range.
- Click local Wiki/Markdown links, outline headings, attachment images and PDF links; navigation must not mutate the source, launch unexpected windows or lose pending changes.
- Attempt a script, active frame or JavaScript URL in Markdown. Source text remains inert, and no native bridge action is emitted.
- Open a long note; scroll to later sections and continue editing. Offscreen decorations should not break scrolling, selection or source positions.

## Native bridge contract

- `change` messages include document identity, full current text and a monotonically increasing revision; native code rejects messages for an inactive document and prevents older snapshots from overwriting newer accepted changes.
- Programmatic same-text echoes are no-ops for editor state. Font/status updates must not rebuild the editor.
- New documents use isolated history; explicit reloads cannot Undo into stale disk versions.
- Attachment insertion clears the native pending request only after a successful, document-matched JavaScript operation.
- Failed JavaScript evaluations are retried rather than recorded as successfully synchronized.
- A native save/navigation must observe all committed editor changes before inspecting `dirty` or writing Markdown.

## Browser test dependencies and results

- Tests load the portable `playwright` package by default. Set `ACDIAN_PLAYWRIGHT` to an existing Playwright package directory if it is installed elsewhere.
- The default Chromium, WebKit and Firefox downloads were initially absent. Arc could not expose its DevTools pipe in isolated headless mode and was not used for regression results.
- Official Chrome Headless Shell 151.0.7922.34 / Playwright revision 1234 was downloaded from the Playwright CDN into a temporary test cache (94.7 MiB plus the CLI's 1 MiB FFmpeg dependency). No OS package installation was performed.

Actual headless keyboard tests live in `live-editor-integration-tests.cjs`. Real macOS IME and Cmd-S integration still require a native UI check.

Run from the source directory:

```sh
npm install --no-save --no-package-lock playwright
npx playwright install chromium-headless-shell
node --test live-editor-integration-tests.cjs
```

If the browser was installed into a custom cache, use the same `PLAYWRIGHT_BROWSERS_PATH` when running the tests.

Verified on 2026-10-23:

- Full 19-test browser suite passed against the final revision-enabled bundle, covering actual keyboard input, caret position, Unicode, echo/undo, source revisions, document isolation, insertion, editability, CRLF, typed Markdown, task continuation, composition, navigation, widgets, PDF cards, source selection/deletion, inert HTML and long-note outline behavior.
- Initial no-click rendering passed after parsing/layout settled: heading class present, heading computed size 34 px at base 16 px, content left padding 58 px, inactive bold markers hidden, Wiki link widget visible and exact source unchanged.
- Browser CDP IME composition updates from Latin preedit to Chinese, followed by commit at a bold boundary, preserved the text exactly once and kept subsequent typing in place. This is browser composition coverage; it does not validate the macOS candidate window.
- Wiki + Markdown PDF cards emit internal navigation without frames; table-cell click edits the rendered cell directly, keeping source delimiters hidden.
- Document revisions strictly increase with input; the getter and latest change event agree on revision, text and document identity. Same-text metadata echoes preserve the revision counter.
- Disabling a contenteditable editor blurs browser focus; re-enabling preserves the source and selection. Tests explicitly focus it before continuing keyboard input.

All browser contexts and profiles were temporary, all note contents were synthetic, and no original Obsidian files were modified.


## 1.2.5 — persistent rich editing and compact layout

- 92 browser checks and 14 editor unit checks passed against unchanged final bundle/CSS hashes.
- Carets and spanning selections preserve rendered headings, emphasis, quotes, links, callouts, dividers, images, math, code fences and tables. Heading/quote document-start, Home and ArrowLeft input keep text inside the formatted block.
- Native table cells support click/edit, Tab/Shift-Tab, new rows, boundary/cross-cell deletion, Unicode, undo and read-only mode; rich inline content and CDP IME composition retain equal column geometry.
- Geometry checks cover headings, blank lines, dividers, hidden source rows and the internal widget-buffer image margin reset.
- 22 isolated native Mac checks passed for WebKit rendering, marked-text API input, native editor snapshots and exact saved text. The offscreen window does not exercise the real macOS candidate window.

All contents and preferences were isolated temporary fixtures. No personal notes were read or modified.

## 1.2.7 — automatic persistence

- Swift suites passed: 42 autosave, 53 new-page, 52 trash-model, 35 page-storage, 76 trash-storage, 12 snapshot and 16 localization checks, plus the core file tests.
- Body and title changes debounce for 0.5 seconds. Navigation, new pages, trash actions, close and quit flush the latest editor snapshot without Save/Discard/Cancel prompts.
- First draft persistence creates a backing file without changing the live body, title, selection, bridge path, document identity or undo history. Further saves update that file; selecting its sidebar row is a no-op.
- Exact Unicode and CRLF, stale/duplicate snapshots, canceled timers after deletion, external edits and failed writes are covered. Failed saves preserve local text, protect the external file and prevent leaving.
- No editor JavaScript or CSS changed from the verified 1.2.6 bundle; native automatic saves do not reset or echo the document into WebKit.
- 42 isolated native WKWebView/ContentView/AppDelegate checks passed, including actual undo/redo after first autosave, marked-text API commit, latest-request navigation and save-before-window-close behavior. No existing user instance was operated.

All note contents and test preferences were isolated temporary fixtures. The user's existing windows and notes were left untouched.

## 1.2.6 — zero separator gaps and simplified insertion menu

- 101 browser checks and 14 editor unit checks passed against unchanged final bundle/CSS hashes.
- Stored Markdown separator rows have zero height at 13, 16 and 20px; selecting them never expands the gap. Enter creates a writable paragraph, and whitespace-only documents expose a normal input row.
- Caret navigation skips hidden code fences, Setext underlines and table source separators while preserving editable blank code lines. Unicode, LF/CRLF, exact source, revisions and undo/redo remain covered.
- All 11 slash commands retain names, icons, keyboard insertion, search and ARIA semantics. Description and footer elements are absent in English, Spanish and Chinese.
- 36 final native offscreen Mac checks passed, including native Enter, marked-text API input, exact saved text and three-language menu snapshots. Browser CDP covers real composing state; the offscreen native API check does not exercise a human candidate window.

All contents and preferences were isolated temporary fixtures. No personal notes were read or modified.
