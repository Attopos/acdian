import SwiftUI
import AppKit
import WebKit

// Renders pages in the real editor in an offscreen window and checks what the
// page drew: formulas that span lines, inline HTML, HTML blocks, code, Mermaid,
// callouts, folding and footnotes.
// Usage: rich-text-tests [page.md to report on]
@main
struct RichTextTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        func check(_ condition: @autoclosure () async throws -> Bool, _ message: String) async throws { if !(try await condition()) { print("FAIL:",message); exit(1) } }
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-rich-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func write(_ name: String, _ text: String) throws { try text.write(to:root.appendingPathComponent(name),atomically:true,encoding:.utf8) }
        let report = CommandLine.arguments.count > 1 ? URL(fileURLWithPath:CommandLine.arguments[1]) : nil
        if let report { try FileManager.default.copyItem(at:report,to:root.appendingPathComponent("Report.md")) }
        // The forms that once turned the rest of a note into one red formula.
        try write("Math.md","""
        Before **bold**

        $$8000+500+500=9000
        $$
        After **one**

        $$S_n=a_1+a_2
        $$
        Then **two**

        $$
        x+y$$

        After **three**

        3
        { 4^n \\rightarrow 4^3 } $$
        After **stray**

        $$
        never closed

        After **open**

        $$a$$$$b$$

        | A | B |
        | --- | --- |
        | 1 | 2 |

        text $$c^2$$ and $d^2$ inline
        """)
        try write("Rich.md","""
        Intro

        <span style="color:red;position:fixed">red</span> <font color="blue">blue</font> <u>under</u> H<sub>2</sub>O <mark>mark</mark> `<u>code</u>`

        ```python
        def f(x):
            return "s" # note
        ```

        ```mermaid
        graph TD
        A-->B
        ```

        ```mermaid
        not a diagram (((
        ```

        <details>
        <summary>Open me</summary>

        **inside** and $E=mc^2$

        </details>

        <table><tr><td colspan="2">merged</td></tr><tr><td>a</td><td>b</td></tr></table>

        <div style="display:flex;position:fixed"><div>left</div><div>right</div></div>

        > [!warning] Careful
        > body

        > [!tip]- Closed
        > hidden body

        ## Section

        Under the section

        ## Next

        Note[^1] here.

        [^1]: The note.
        """)
        let suite = "acdian-rich-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await wait(0.01) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1260,height:report == nil ? 3000 : 16000),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        let web = LiveEditorHost.shared.view
        func open(_ name: String) async throws { model.open(model.index!.files.first { $0.relativePath == name }!,skipConfirmation:true); try await wait(2) }
        func js<T>(_ script: String, as _: T.Type = T.self) async throws -> T? { try await web.evaluateJavaScript(script) as? T }
        func text(_ selector: String) async throws -> [String] { try await js("JSON.stringify([...document.querySelectorAll('\(selector)')].map(e=>e.textContent))",as:String.self).flatMap { try? JSONDecoder().decode([String].self,from:Data($0.utf8)) } ?? [] }
        func count(_ selector: String) async throws -> Int { try await js("document.querySelectorAll('\(selector)').length",as:Int.self) ?? -1 }

        if report != nil {
            try await open("Report.md")
            let visible = try await js("document.querySelector('.cm-content').innerText",as:String.self) ?? ""
            let lines = visible.split(separator:"\n").filter { $0.contains("**") || $0.contains("$$") }
            print("formulas",try await count(".cm-block-math"),"errors",try await text(".katex-error"),"tables",try await count(".cm-table-row"),"strong",try await count(".cm-live-strong"))
            print("raw lines left:",lines.count); for line in lines.prefix(10) { print("  ",line.prefix(90)) }
            exit(0)
        }

        try await open("Math.md")
        let displays = try await count(".cm-block-math")
        try await check(displays == 4, "Formulas with a closing mark on another line render, each on its own (\(displays))")
        let errors = try await text(".katex-error")
        try await check(errors.isEmpty, "No formula shows as an error (\(errors))")
        let strong = try await text(".cm-live-strong")
        try await check(strong.filter { ["bold","**bold**","**one**","**two**","**three**","**stray**","**open**"].contains($0) }.count == 6, "Text after every kind of $$ stays rendered (\(strong))")
        try await check(try await count(".cm-table-row") >= 3, "A table after the formulas stays a table")
        try await check(try await count(".cm-inline-math") == 2, "$$…$$ and $…$ inside a line are formulas")
        _ = try await js("(()=>{const v=window.acdianEditor;const at=v.state.doc.toString().indexOf('$$8000');v.dispatch({selection:{anchor:at+3}});})()",as:Bool.self)
        try await wait(0.3)
        try await check(try await count(".cm-block-math") == 3, "A formula shows its source while the caret is in it")

        try await open("Rich.md")
        let span = try await js("(()=>{const e=document.querySelector('.cm-html-span');return e.getAttribute('style')+'|'+e.textContent;})()",as:String.self)
        try await check(span == "color: red;|red", "A span keeps its colour, drops anything else and hides its tags (\(span ?? "nil"))")
        try await check(try await js("getComputedStyle(document.querySelector('.cm-html-font')).color",as:String.self) == "rgb(0, 0, 255)", "font color applies")
        try await check(try await text(".cm-html-u") == ["under"], "Underline, subscript and mark render, and tags in code stay text")
        try await check((try await count(".cm-html-sub")) == 1, "Underline, subscript and mark render, and tags in code stay text")
        try await check((try await count(".cm-html-mark")) == 1, "Underline, subscript and mark render, and tags in code stay text")
        try await check(try await count(".cm-code-line .cm-tok-keyword") >= 1, "Python is highlighted")
        try await check((try await count(".cm-code-line .cm-tok-string")) >= 1, "Python is highlighted")
        try await check((try await count(".cm-code-line .cm-tok-comment")) >= 1, "Python is highlighted")
        try await check(try await text(".cm-code-tools span") == ["python"], "A code block shows its language and a copy button")
        try await check((try await count(".cm-code-tools button")) == 1, "A code block shows its language and a copy button")
        try await wait(3)
        try await check(try await count(".cm-mermaid svg") == 1, "A Mermaid diagram draws")
        try await check(try await count(".cm-mermaid-error") == 1, "A broken diagram shows its error and source")
        try await check(try await js("document.querySelector('.cm-block-html details strong').textContent",as:String.self) == "inside", "A folding block holds Markdown and formulas")
        try await check((try await count(".cm-block-html details .katex")) == 1, "A folding block holds Markdown and formulas")
        try await check(try await js("document.querySelector('.cm-block-html details').open",as:Bool.self) == false, "A folding block starts closed")
        try await check(try await js("document.querySelector('.cm-block-html td[colspan]').textContent",as:String.self) == "merged", "An HTML table keeps merged cells")
        let columns = try await js("(()=>{const e=[...document.querySelectorAll('.cm-block-html div[style]')].find(d=>d.style.display==='flex');return e?e.style.display+'|'+e.style.position:'';})()",as:String.self)
        try await check(columns == "flex|", "A column layout keeps flex and drops fixed positioning (\(columns ?? "nil"))")
        try await check(try await count(".cm-callout-warning") == 2, "A warning callout takes its colour")
        let closed = try await text(".cm-content .cm-line").contains { $0.contains("hidden body") }
        try await check(!closed, "A [!kind]- callout starts folded")
        try await check(try await count(".cm-fold-closed") == 1, "The folded callout shows a closed arrow")
        try await check(try await text(".cm-footnote-mark") == ["1"], "A footnote shows as a small mark with its note")
        try await check((try await count(".cm-footnote-note")) == 1, "A footnote shows as a small mark with its note")
        _ = try await js("(()=>{const toggle=[...document.querySelectorAll('.cm-heading-2 .cm-fold-toggle')][0];toggle.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));})()",as:Bool.self)
        try await wait(0.3)
        let under = try await text(".cm-content .cm-line").contains { $0.contains("Under the section") }
        let next = try await text(".cm-content .cm-line").contains { $0.contains("Next") }
        try await check(!under && next, "A heading's arrow folds its section (under \(under), next \(next))")
        print("Rich text: formulas across lines, stray marks, inline HTML, code, Mermaid, HTML blocks, callouts, folding and footnotes passed")
        exit(0)
    }
}
