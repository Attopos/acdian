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
        func shown(_ selector: String) async throws -> [String] { try await js("JSON.stringify([...document.querySelectorAll('\(selector)')].map(e=>{const c=e.cloneNode(true);c.querySelectorAll('.cm-format-delimiter').forEach(x=>x.remove());return c.textContent;}))",as:String.self).flatMap { try? JSONDecoder().decode([String].self,from:Data($0.utf8)) } ?? [] }
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
        let span = try await js("(()=>{const e=document.querySelector('.cm-html-span'),c=e.cloneNode(true);c.querySelectorAll('.cm-format-delimiter').forEach(x=>x.remove());return e.getAttribute('style')+'|'+c.textContent;})()",as:String.self)
        try await check(span == "color: red;|red", "A span keeps its colour, drops anything else and hides its tags (\(span ?? "nil"))")
        try await check(try await js("getComputedStyle(document.querySelector('.cm-html-font')).color",as:String.self) == "rgb(0, 0, 255)", "font color applies")
        try await check(try await shown(".cm-html-u") == ["under"], "Underline, subscript and mark render, and tags in code stay text")
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
        // Pictures, from a Retina screenshot pasted in to resizing it.
        let picture = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:400,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        picture.size = NSSize(width:400,height:200)
        let pictureData = picture.representation(using:.png,properties:[:])!
        try write("Pictures.md","Top\n\nBelow\n")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Attachments"),withIntermediateDirectories:true)
        try pictureData.write(to:root.appendingPathComponent("Attachments/plain.png"))
        try write("Inline.md","Intro\n\nIn a line ![[Attachments/plain.png|30]] here\n\n- list ![[Attachments/plain.png|20]]\n\n![[Attachments/nothing.png]]\n\n![[Attachments/plain.png|caption words|100]]\n")
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Inline.md" }) != true { try await wait(0.01) }
        try await open("Pictures.md")
        _ = try await js("(()=>{const v=window.acdianEditor;v.dispatch({selection:{anchor:v.state.doc.toString().indexOf('Below')}});})()",as:Bool.self)
        model.insertImage(pictureData,ext:"png")
        try await wait(1.5)
        try await check(model.text.contains("|400]]\nBelow"), "A Retina screenshot goes in at its width on screen, on its own line (\(model.text))")
        let caret = try await js("(()=>{const v=window.acdianEditor;return v.state.doc.lineAt(v.state.selection.main.head).text;})()",as:String.self)
        try await check(caret == "Below", "The caret goes on below the picture (\(caret ?? "nil"))")
        let shownWidth = try await js("document.querySelector('.cm-block-image img').getBoundingClientRect().width",as:Double.self)
        try await check(shownWidth == 400, "The picture shows at that width (\(shownWidth ?? -1))")
        let centred = try await js("(()=>{const f=document.querySelector('.cm-image-frame').getBoundingClientRect(),b=document.querySelector('.cm-block-image').getBoundingClientRect();return Math.abs((f.left+f.right)/2-(b.left+b.right)/2)<2;})()",as:Bool.self)
        try await check(centred == true, "The picture is centred")
        try await check(try await js("getComputedStyle(document.querySelector('.cm-image-handle')).display",as:String.self) == "none", "Handles show only on a selected picture")
        _ = try await js("window.__image=document.querySelector('.cm-block-image img');document.querySelector('.cm-block-image').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))",as:Bool.self)
        try await wait(0.3)
        try await check(try await js("document.querySelector('.cm-block-image img')===window.__image",as:Bool.self) == true, "Selecting a picture does not redraw it")
        try await check(try await js("getComputedStyle(document.querySelector('.cm-block-selected .cm-image-handle')).display",as:String.self) == "block", "A selected picture shows its handles")
        try await check(try await count(".cm-cursor") == 0, "A selected picture has no text caret beside it")
        _ = try await js("(()=>{const h=document.querySelector('.cm-image-handle-right');h.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:100}));window.dispatchEvent(new MouseEvent('mousemove',{clientX:150}));window.dispatchEvent(new MouseEvent('mouseup',{clientX:150}));})()",as:Bool.self)
        try await wait(0.3)
        let resized = try await js("window.acdianEditor.state.doc.line(3).text",as:String.self) ?? ""
        try await check(resized.hasSuffix("|500]]"), "Dragging a handle keeps the new width in the Markdown (\(resized))")
        try await check(try await js("document.querySelector('.cm-block-image img')===window.__image&&window.__image.getBoundingClientRect().width===500",as:Bool.self) == true, "The picture takes the new width without loading again")
        try await check(try await js("!!document.querySelector('.cm-block-selected')",as:Bool.self) == true, "The picture stays selected after a resize")
        _ = try await js("window.__image.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}))",as:Bool.self)
        try await check(try await count(".cm-image-large img") == 1, "Double-clicking a picture shows it large")
        _ = try await js("window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))",as:Bool.self)
        try await check(try await count(".cm-image-large") == 0, "Escape closes the large view")

        try await open("Inline.md")
        try await wait(1)
        try await check(try await count(".cm-inline-image") == 2, "A picture inside a line or list item shows in place")
        try await check(try await text(".cm-image-missing").first?.contains("nothing.png") == true, "A missing picture says which file is missing")
        try await check(try await text(".cm-image-caption") == ["caption words"], "Text with a picture is its caption")
        try await check(try await js("[...document.querySelectorAll('.cm-block-image img')].at(-1).getBoundingClientRect().width",as:Double.self) == 100, "A caption and a width can go together")

        // Callouts: an icon on the first line of text, chosen in the page.
        try write("Callouts.md","Intro\n\n> [!note]\n> Body under an empty header\n> more\n\n> [!idea|🚀] One line\n\n> [!note] A title\n> Its body\n\nEnd\n")
        try write("Move.md","First\n\nSecond\n\n![[Attachments/plain.png|100]]\n\nThird\n\n| A |\n| --- |\n| 1 |\n\nLast\n")
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Move.md" }) != true { try await wait(0.01) }
        try await open("Callouts.md")
        let hiddenHeader = try await js("(()=>{const walk=document.createTreeWalker(document.querySelector('.cm-content'),NodeFilter.SHOW_TEXT);for(let n;(n=walk.nextNode());)if(n.textContent.includes('[!')&&parseFloat(getComputedStyle(n.parentElement).fontSize)>0)return n.textContent;return '';})()",as:String.self)
        try await check(hiddenHeader == "", "A callout shows nothing of its [!kind] source (\(hiddenHeader ?? "nil"))")
        try await check(try await text(".cm-callout-icon") == ["📝","🚀","📝"], "Each callout shows its icon")
        let sameLine = try await js("(()=>{const i=document.querySelector('.cm-callout-icon'),l=i.closest('.cm-line');return l.textContent.includes('Body under')&&Math.abs(i.getBoundingClientRect().top-l.getBoundingClientRect().top)<14;})()",as:Bool.self)
        try await check(sameLine == true, "The icon shares a line with the first text")
        try await check(try await js("document.querySelector('.cm-callout-empty').getBoundingClientRect().height",as:Double.self) == 0, "An empty header line takes no room")
        try await check(try await count(".cm-callout-titled") == 1, "A title line written the old way stays bold; others do not")
        _ = try await js("document.querySelectorAll('.cm-callout-icon')[1].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))",as:Bool.self)
        try await check(try await count(".cm-callout-picker-grid button") > 20, "Clicking the icon opens the choice of icons")
        _ = try await js("document.querySelector('.cm-callout-picker-colors [data-kind=tip]').click()",as:Bool.self)
        try await wait(0.2)
        try await check(model.text.contains("> [!tip|🚀] One line"), "A colour changes the kind and keeps the icon (\(model.text))")
        _ = try await js("[...document.querySelectorAll('.cm-callout-picker-grid button')].find(b=>b.textContent==='🎯').click()",as:Bool.self)
        try await wait(0.2)
        try await check(model.text.contains("> [!tip|🎯] One line"), "An icon is kept in the Markdown (\(model.text))")
        try await check(try await count(".cm-callout-picker") == 0, "Choosing an icon closes the panel")
        try await check(try await count(".cm-callout-tip") == 1, "The callout takes the new colour")

        // Dragging a picture moves its line.
        try await open("Move.md")
        try await wait(0.5)
        func dragPicture(toLine number: Int, below: Bool) async throws {
            _ = try await js("(()=>{const v=window.acdianEditor,i=document.querySelector('.cm-block-image img'),r=i.getBoundingClientRect(),b=v.lineBlockAt(v.state.doc.line(\(number)).from),y=v.documentTop+(\(below ? "b.bottom-1" : "b.top+1")),go=(t,e)=>t.dispatchEvent(new MouseEvent(e,{bubbles:true,cancelable:true,button:0,clientX:r.left+5,clientY:y}));i.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,button:0,clientX:r.left+5,clientY:r.top+5}));go(window,'mousemove');go(window,'mouseup');})()",as:Bool.self)
            try await wait(0.3)
        }
        try await dragPicture(toLine:1,below:false)
        try await check(model.text == "![[Attachments/plain.png|100]]\nFirst\n\nSecond\n\nThird\n\n| A |\n| --- |\n| 1 |\n\nLast\n", "A picture moves to the top, and the blank line it left goes too (\(model.text.debugDescription))")
        try await check(try await js("!!document.querySelector('.cm-block-selected .cm-image-frame')",as:Bool.self) == true, "The moved picture stays selected")
        try await check(try await count(".cm-image-ghost,.cm-image-drop") == 0, "Nothing of the drag is left on the page")
        try await dragPicture(toLine:9,below:false)
        try await check(model.text == "First\n\nSecond\n\nThird\n\n| A |\n| --- |\n| 1 |\n![[Attachments/plain.png|100]]\n\nLast\n" || model.text == "First\n\nSecond\n\nThird\n\n![[Attachments/plain.png|100]]\n| A |\n| --- |\n| 1 |\n\nLast\n", "A drop on a table lands beside it, never inside (\(model.text.debugDescription))")
        _ = try await js("window.acdianUndo()",as:Bool.self)
        try await wait(0.2)
        try await check(model.text.hasPrefix("![[Attachments/plain.png|100]]\nFirst"), "Undo puts the picture back in one step")

        try await check(try await js("[document.documentElement,document.body,window.acdianEditor.scrollDOM].every(e=>getComputedStyle(e).overscrollBehaviorY==='none')",as:Bool.self) == true, "The page cannot be pulled past its top or bottom")

        // Hidden link addresses must not give the line places to break, or closing
        // punctuation lands alone on the next line. Tried at every position along the line.
        try write("Wrap.md","Intro\n\n> [!note] Title\n> x\n\n> y\n\nz\n")
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Wrap.md" }) != true { try await wait(0.01) }
        try await open("Wrap.md")
        let orphans = try await js("""
        (()=>{const v=window.acdianEditor,bad=[];v.dispatch({selection:{anchor:0}});
        for(const row of ['x','y','z'])for(let k=0;k<60;k++){
          const at=v.state.doc.toString().indexOf(row==='z'?'\\nz':'> '+row)+(row==='z'?1:2),line=v.state.doc.lineAt(at),text=row+'字'.repeat(k)+'（[Word Limitations](https://www.example.com/known-limitations/)）。';
          v.dispatch({changes:{from:at,to:line.to,insert:text}});
          const l=[...document.querySelectorAll('.cm-line')].find(e=>e.textContent.includes('（')),link=l.querySelector('.cm-live-link'),walk=document.createTreeWalker(l,NodeFilter.SHOW_TEXT);
          let tail=null;for(let t;(t=walk.nextNode());)if(t.data.includes('）')&&parseFloat(getComputedStyle(t.parentElement).fontSize)>0)tail=t;
          const r=document.createRange();r.setStart(tail,tail.data.indexOf('）'));r.setEnd(tail,tail.data.indexOf('）')+1);
          const a=r.getBoundingClientRect(),b=[...link.getClientRects()].at(-1);
          if(Math.abs(a.top-b.top)>4)bad.push(row+k);
          const again=v.state.doc.lineAt(at);v.dispatch({changes:{from:at,to:again.to,insert:row}});
        }return bad.join(' ');})()
        """,as:String.self)
        try await check(orphans == "", "Closing punctuation stays with the link before it (\(orphans ?? "nil"))")

        // The caret still shows around a link, whose address takes no part in the line.
        try write("Caret.md","Intro\n\nBefore [Label](https://example.com/a) after\n\n[Last](https://example.com/b)\n")
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Caret.md" }) != true { try await wait(0.01) }
        try await open("Caret.md")
        let carets = try await js("""
        (()=>{document.hasFocus=()=>true;const v=window.acdianEditor,text=v.state.doc.toString(),spots=[text.indexOf('Label'),text.indexOf('Label')+5,text.indexOf(' after'),text.indexOf('Last'),text.indexOf('Last')+4,text.trimEnd().length],bad=[];v.contentDOM.focus();
        for(const pos of spots){v.dispatch({selection:{anchor:pos}});const at=v.state.selection.main.head,a=v.coordsAtPos(at,-1),b=v.coordsAtPos(at,1);if(!a&&!b)bad.push(pos);}return bad.join(' ');})()
        """,as:String.self)
        try await check(carets == "", "The caret has a place at every spot around a link (\(carets ?? "nil"))")

        // Typing right after hidden syntax lands after it, not inside the bold or link.
        for (source,caret,expected) in [("Intro\n\n**Bold** tail\n",15,"Intro\n\n**Bold**字 tail\n"),("Intro\n\na [L](u) tail\n",15,"Intro\n\na [L](u)字 tail\n"),("Intro\n\n**Bold**\n",15,"Intro\n\n**Bold**字\n")] {
            try write("Type.md",source)
            model.refresh()
            for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Type.md" }) != true { try await wait(0.01) }
            model.open(model.index!.files.first { $0.relativePath == "Type.md" }!,skipConfirmation:true,fromDisk:true)
            try await wait(1)
            window.makeKey(); window.makeFirstResponder(web)
            _ = try await js("(()=>{const v=window.acdianEditor;v.focus();v.dispatch({selection:{anchor:\(caret)}});})()",as:Bool.self)
            try await wait(0.3)
            web.insertText("字")
            try await wait(0.3)
            try await check(model.text == expected, "Typing after hidden syntax lands after it (\(model.text.debugDescription))")
            model.closeTab(model.activeTabID!)
            try await wait(0.5)
            try FileManager.default.removeItem(at:root.appendingPathComponent("Type.md"))
        }

        // The toolbar's colours.
        try write("Colors.md","Intro\n\nPaint this word here\n\nSecond line\n")
        try write("Toc.md","Intro\n\n[TOC]\n\n# One\n\n## **Two** deep\n\nText\n\n# Three\n")
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "Toc.md" }) != true { try await wait(0.01) }
        try await open("Colors.md")
        func select(_ word: String) async throws { _ = try await js("(()=>{document.hasFocus=()=>true;const v=window.acdianEditor,at=v.state.doc.toString().indexOf(\(String(reflecting:word)));v.contentDOM.focus();v.dispatch({selection:{anchor:at,head:at+\(word.count)}});})()",as:Bool.self); try await wait(0.3) }
        func choose(_ property: String, _ value: String) async throws {
            _ = try await js("document.querySelector('.cm-format-color').click()",as:Bool.self)
            try await wait(0.1)
            _ = try await js("document.querySelector('.cm-format-swatch[data-property=\"\(property)\"][data-value=\"\(value)\"]').click()",as:Bool.self)
            try await wait(0.3)
        }
        try await select("this word")
        try await check(try await count(".cm-format-color") == 1, "The toolbar offers colours")
        try await choose("color","#e0524d")
        try await check(model.text.contains(#"Paint <span style="color:#e0524d">this word</span> here"#), "A colour wraps the selection in a span (\(model.text))")
        try await check(try await shown(".cm-html-span") == ["this word"], "The tags stay hidden while the text is selected")
        try await check(try await js("window.acdianEditor.state.sliceDoc(window.acdianEditor.state.selection.main.from,window.acdianEditor.state.selection.main.to)",as:String.self) == "this word", "The same words stay selected")
        try await choose("background-color","#3fae6b40")
        try await check(model.text.contains(#"<span style="color:#e0524d;background-color:#3fae6b40">this word</span>"#), "A background joins the same span (\(model.text))")
        try await choose("color","")
        try await check(model.text.contains(#"<span style="background-color:#3fae6b40">this word</span>"#), "No colour takes off just the text colour (\(model.text))")
        _ = try await js("document.querySelector('.cm-format-color').click();document.querySelector('.cm-format-colors-clear').click()",as:Bool.self)
        try await wait(0.3)
        try await check(model.text.contains("Paint this word here"), "Clear puts back the plain text (\(model.text))")

        // [TOC]
        try await open("Toc.md")
        try await wait(0.3)
        try await check(try await text(".cm-toc button") == ["One","Two deep","Three"], "[TOC] lists the headings as plain text")
        _ = try await js("(()=>{const v=window.acdianEditor,l=v.state.doc.line(7);v.dispatch({changes:{from:l.from,to:l.to,insert:'## Renamed'}});})()",as:Bool.self)
        try await wait(0.3)
        try await check(try await text(".cm-toc button") == ["One","Renamed","Three"], "[TOC] follows edits")
        _ = try await js("document.querySelector('.cm-toc').dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}))",as:Bool.self)
        try await wait(0.3)
        try await check(try await count(".cm-toc") == 0, "Double-clicking [TOC] shows its source")

        // The picture's own menu.
        try await open("Inline.md")
        try await wait(0.5)
        _ = try await js("document.querySelector('.cm-block-image img:not([hidden])').closest('.cm-block-image');[...document.querySelectorAll('.cm-block-image img')].at(-1).dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:50,clientY:50}))",as:Bool.self)
        let actions = try await js("JSON.stringify([...document.querySelectorAll('.cm-image-menu button')].map(b=>b.dataset.action))",as:String.self)
        try await check(actions == #"["viewImage","copyImage","revealImage","deleteImage"]"#, "A picture has its own menu (\(actions ?? "nil"))")
        let clip = NSPasteboard(name:NSPasteboard.Name("acdian-rich-\(UUID().uuidString)"))
        model.copyImage("Attachments/plain.png",from:"Inline.md",to:clip)
        try await check(clip.canReadObject(forClasses:[NSImage.self],options:nil) && clip.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]), "Copying gives the image and the file")
        clip.releaseGlobally()
        _ = try await js("document.querySelector('.cm-image-menu [data-action=deleteImage]').click()",as:Bool.self)
        try await wait(0.3)
        try await check(!model.text.contains("caption words"), "Delete removes the picture from the page (\(model.text))")
        try await check(try await count(".cm-image-menu") == 0, "The menu closes after a choice")

        print("Rich text: formulas across lines, stray marks, inline HTML, code, Mermaid, HTML blocks, callouts, folding, footnotes, pictures, callouts, colours and [TOC] passed")
        exit(0)
    }
}
