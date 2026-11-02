import SwiftUI
import AppKit
import WebKit

// Opens a page with a second page beside it in an offscreen window, edits the
// split page through its own editor, and checks saving, swapping sides,
// links, and moving the split page into the main editor.
// Usage: split-view-tests [output folder for pictures]
@main
struct SplitViewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { print("FAIL:",message); exit(1) } }
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-split-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try "# Main page\n\nThe page open in the main editor.\n".write(to:root.appendingPathComponent("A.md"),atomically:true,encoding:.utf8)
        try "# Side page\n\nShown beside it. See [C](C.md).\n".write(to:root.appendingPathComponent("B.md"),atomically:true,encoding:.utf8)
        try "# Linked page\n\nReached from the side page.\n".write(to:root.appendingPathComponent("C.md"),atomically:true,encoding:.utf8)
        let suite = "acdian-split-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await wait(0.01) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1400,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:.darkAqua)
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        func file(_ path: String) -> VaultEntry { model.index!.files.first { $0.relativePath == path }! }
        func disk(_ path: String) -> String { (try? String(contentsOf:root.appendingPathComponent(path),encoding:.utf8)) ?? "" }
        func webViews(_ view: NSView) -> [WKWebView] { if let web = view as? WKWebView { return [web] }; return view.subviews.flatMap(webViews) }
        func x(_ web: WKWebView) -> CGFloat { web.convert(web.bounds,to:nil).minX }
        let pictures = CommandLine.arguments.count > 1 ? URL(fileURLWithPath:CommandLine.arguments[1]) : nil
        func picture(_ name: String) async throws {
            guard let pictures else { return }
            for (i,web) in webViews(window.contentView!).sorted(by: { x($0) < x($1) }).enumerated() {
                let image = try await web.takeSnapshot(configuration:nil)
                try NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:pictures.appendingPathComponent("\(name)-\(i).png"))
            }
            let content = window.contentView!
            if let rep = content.bitmapImageRepForCachingDisplay(in:content.bounds) { content.cacheDisplay(in:content.bounds,to:rep); try rep.representation(using:.png,properties:[:])!.write(to:pictures.appendingPathComponent("\(name)-window.png")) }
        }

        model.openInSplit(file("A.md"))
        try await wait(0.5)
        check(model.splitPath == nil && model.currentPagePath == "A.md", "With no page open, opening in split view opens the page normally")
        try await wait(3)
        model.openInSplit(file("A.md"))
        check(model.splitPath == nil, "The open page cannot also be the split page")
        model.openInSplit(file("B.md"))
        try await wait(3)
        check(model.splitPath == "B.md" && !model.splitLoading && model.splitText.contains("Side page"), "The split page loads its text")
        var webs = webViews(window.contentView!)
        check(webs.count == 2, "The split page has an editor of its own (found \(webs.count))")
        let split = SplitEditorHost.shared.view
        check(webs.contains(split) && x(split) > webs.map(x).min()!, "The split page starts on the right")
        let shown = try await split.evaluateJavaScript("window.acdianEditor.state.doc.toString()") as? String ?? ""
        check(shown.contains("Shown beside it"), "The split editor shows the split page")
        let main = try await LiveEditorHost.shared.view.evaluateJavaScript("window.acdianEditor.state.doc.toString()") as? String ?? ""
        check(main.contains("main editor"), "The main editor still shows the open page")
        try await picture("split")

        _ = try await split.evaluateJavaScript("(()=>{const v=window.acdianEditor;v.dispatch({changes:{from:v.state.doc.length,insert:'Typed in the split.\\n'},userEvent:'input'});})()")
        try await wait(1.5)
        check(disk("B.md").contains("Typed in the split."), "Edits in the split page save to its file")
        check(disk("A.md").contains("main editor") && !disk("A.md").contains("Typed"), "The open page is untouched")

        let widths = webs.map { $0.convert($0.bounds,to:nil) }
        check(abs(widths[0].width - widths[1].width) < 2 && abs(widths[0].minY - widths[1].minY) < 1, "The two columns start equal and level (\(widths))")
        model.swapSplitSides()
        try await wait(1)
        webs = webViews(window.contentView!)
        check(webs.count == 2 && x(split) < webs.map(x).max()!, "Swapping sides puts the split page on the left")
        let swapped = webs.map { $0.convert($0.bounds,to:nil) }
        check(abs(swapped[0].width - swapped[1].width) < 2 && abs(swapped[0].minY - swapped[1].minY) < 1, "The columns stay equal and level after a swap (\(swapped))")
        let still = try await split.evaluateJavaScript("window.acdianEditor.state.doc.toString()") as? String ?? ""
        check(still.contains("Typed in the split."), "The split page keeps its text when the sides swap")
        try await picture("swapped")
        model.swapSplitSides()
        check(model.splitFocused, "The split column is the one in use after it opens")
        model.openInFocusedColumn(file("A.md"))
        check(!model.splitFocused, "Choosing the open page in the sidebar returns to its column")
        model.splitFocused = true

        _ = try await split.evaluateJavaScript("document.querySelector('.cm-content [data-live-target]').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}))")
        try await wait(2)
        check(model.splitPath == "C.md" && model.currentPagePath == "A.md", "A link in the split page opens in the split page")
        let linked = try await split.evaluateJavaScript("window.acdianEditor.state.doc.toString()") as? String ?? ""
        check(linked.contains("Reached from the side page"), "The split editor shows the linked page")

        _ = try await split.evaluateJavaScript("(()=>{const v=window.acdianEditor;v.dispatch({changes:{from:v.state.doc.length,insert:'Not saved yet.\\n'},userEvent:'input'});})()")
        try await wait(0.1)
        model.open(file("C.md"))
        try await wait(3)
        check(model.splitPath == nil && model.currentPagePath == "C.md", "Opening the split page in the main editor closes the split")
        check(disk("C.md").contains("Not saved yet."), "Pending split edits are saved before the page moves to the main editor")
        check(model.text.contains("Not saved yet."), "The main editor shows the split page's latest text")
        let left = webViews(window.contentView!)
        check(!left.contains(split) && left.contains(LiveEditorHost.shared.view), "Only the main editor is left")

        model.openInSplit(file("B.md"))
        try await wait(2)
        model.finishRenaming("B.md",to:nil)
        model.renamingPath = "B.md"; model.finishRenaming("B.md",to:"Renamed")
        try await wait(1)
        check(model.splitPath == "Renamed.md" && model.splitEntry?.relativePath == "Renamed.md", "The split page follows a rename")
        model.closeSplit()
        try await wait(1)
        check(model.splitPath == nil && !webViews(window.contentView!).contains(split), "Closing the split leaves the open page alone")
        // A page's title is its file name, in a block of its own above the text.
        check(AppModel.withoutNameHeading("# N\n\nBody",name:"N") == "Body" && AppModel.withoutNameHeading("# N\r\n\r\nBody",name:"N") == "Body" && AppModel.withoutNameHeading("# N\n",name:"N") == "" && AppModel.withoutNameHeading("# Other\n\nBody",name:"N") == "# Other\n\nBody" && AppModel.withoutNameHeading("Plain",name:"N") == "Plain", "Only a first-line heading repeating the file name is dropped")
        try "# Title one\n\nBody one.\n".write(to:root.appendingPathComponent("T1.md"),atomically:true,encoding:.utf8)
        try "Just text, no heading.\n".write(to:root.appendingPathComponent("N.md"),atomically:true,encoding:.utf8)
        try "# Same\n\nBody after the same heading.\n".write(to:root.appendingPathComponent("Same.md"),atomically:true,encoding:.utf8)
        try "# Title two\n\nBody two.\n".write(to:root.appendingPathComponent("T2.md"),atomically:true,encoding:.utf8)
        model.refresh()
        for _ in 0..<500 where model.loading || model.index?.files.contains(where: { $0.relativePath == "T2.md" }) != true { try await wait(0.01) }
        let mainView = LiveEditorHost.shared.view
        func shownTitle(_ web: WKWebView) async throws -> String { try await web.evaluateJavaScript("document.querySelector('.cm-page-title')?.textContent ?? ''") as? String ?? "" }
        func document(_ web: WKWebView) async throws -> String { try await web.evaluateJavaScript("window.acdianEditor.state.doc.toString()") as? String ?? "" }
        func typeTitle(_ web: WKWebView, _ title: String) async throws { _ = try await web.evaluateJavaScript("(()=>{const h=document.querySelector('.cm-page-title');h.textContent=\(String(reflecting:title));h.dispatchEvent(new InputEvent('input',{bubbles:true}));})()") ; try await wait(0.2) }
        func endTitle(_ web: WKWebView) async throws { _ = try await web.evaluateJavaScript("document.querySelector('.cm-page-title').dispatchEvent(new FocusEvent('blur'))"); try await wait(1) }

        model.open(file("T1.md"))
        try await wait(2)
        model.openInSplit(file("N.md"))
        try await wait(2)
        var title = try await shownTitle(split)
        check(title == "N", "The title block shows the file name (\(title))")
        let scrolls = try await split.evaluateJavaScript("(()=>{const d=window.acdianEditor.scrollDOM;return d.scrollHeight>d.clientHeight+1;})()") as? Bool ?? true
        check(!scrolls, "A short page does not scroll")
        let lined = try await split.evaluateJavaScript("(()=>{const r=document.createRange();const t=document.querySelector('.cm-page-title');r.selectNodeContents(t);return Math.abs(r.getBoundingClientRect().left-window.acdianEditor.coordsAtPos(0).left)<2;})()") as? Bool ?? false
        check(lined, "The title lines up with the text")
        var text = try await document(split)
        check(text == "Just text, no heading.\n" && disk("N.md") == "Just text, no heading.\n", "Opening a page leaves its file and text alone")
        let placed = try await split.evaluateJavaScript("(()=>{const v=window.acdianEditor,h=document.querySelector('.cm-page-title'),t=h.getBoundingClientRect(),c=v.contentDOM.getBoundingClientRect();const p=v.coordsAtPos(5);return [v.contentDOM.contains(h),t.bottom<=c.top+1,t.height>0,v.posAtCoords({x:p.left,y:(p.top+p.bottom)/2})===5,h.isContentEditable];})()") as? [Bool] ?? []
        check(placed == [false,true,true,true,true], "The block sits above the text, outside the document, editable, and clicks in the text still land right (\(placed))")

        try await typeTitle(split,"Plain page")
        check(model.splitPath == "N.md", "Typing in the title does not rename yet")
        try await endTitle(split)
        check(model.splitPath == "Plain page.md" && disk("Plain page.md") == "Just text, no heading.\n", "Ending the title renames the split page and leaves its text alone (\(model.splitPath ?? "-"))")
        check(model.index?.files.contains(where: { $0.relativePath == "N.md" }) == false, "The sidebar drops the old name")
        title = try await shownTitle(split)
        check(title == "Plain page", "The block shows the new name")

        try await typeTitle(split,"   ")
        try await endTitle(split)
        title = try await shownTitle(split)
        check(title == "Plain page" && model.splitPath == "Plain page.md", "An emptied title goes back to the file name (\(title))")

        model.error = nil
        try await typeTitle(split,"T2")
        try await endTitle(split)
        title = try await shownTitle(split)
        check(model.splitPath == "Plain page.md" && model.error != nil && title == "Plain page", "A name another page has is refused with a message and the old name comes back (\(title))")
        model.error = nil

        model.openInSplit(file("Same.md"))
        try await wait(2)
        text = try await document(split)
        title = try await shownTitle(split)
        check(title == "Same" && text == "Body after the same heading.\n" && disk("Same.md") == "Body after the same heading.\n", "A heading repeating the file name moves out of the text (\(text))")

        text = try await document(mainView)
        title = try await shownTitle(mainView)
        check(title == "T1" && text.hasPrefix("# Title one"), "A heading that says something else stays in the text")
        let mainDocument = model.editorDocumentID
        try await typeTitle(mainView,"Renamed one")
        try await endTitle(mainView)
        check(model.currentPagePath == "Renamed one.md" && model.editorDocumentID == mainDocument, "Ending the title renames the open page without reloading it (\(model.currentPagePath ?? "-"))")
        check(model.tabs.contains(where: { $0.path == "Renamed one.md" }) && !FileManager.default.fileExists(atPath:root.appendingPathComponent("T1.md").path), "The tab follows the new name and no copy stays behind")
        _ = try await mainView.evaluateJavaScript("(()=>{const v=window.acdianEditor;v.dispatch({changes:{from:v.state.doc.length,insert:'After rename.\\n'},userEvent:'input'});})()")
        try await wait(1.5)
        check(disk("Renamed one.md").contains("After rename."), "Typing after a rename saves to the renamed file")

        // Going to another page ends the title edit too, with no blur in between.
        try await typeTitle(mainView,"Left behind")
        model.open(file("T2.md"))
        try await wait(2)
        title = try await shownTitle(mainView)
        check(model.currentPagePath == "T2.md" && disk("Left behind.md").contains("After rename.") && title == "T2", "Leaving a page with its title being edited renames it (\(title))")

        // A new page's title field does the same once its file exists.
        model.newPageFromEditor()
        try await wait(1)
        model.draftTitle = "Draft one"
        try await wait(1.5)
        check(FileManager.default.fileExists(atPath:root.appendingPathComponent("Draft one.md").path), "A new page saves under its title")
        model.draftTitle = "Draft two"
        try await wait(1.5)
        check(FileManager.default.fileExists(atPath:root.appendingPathComponent("Draft one.md").path), "Typing in the title field does not rename yet")
        model.draftTitleEnded()
        check(FileManager.default.fileExists(atPath:root.appendingPathComponent("Draft two.md").path) && !FileManager.default.fileExists(atPath:root.appendingPathComponent("Draft one.md").path), "Ending the title field renames the new page")
        model.draftTitle = "Draft three"
        try await wait(1.5)
        check(disk("Draft two.md").hasPrefix("# Draft three"), "A new page keeps saving to its renamed file")
        try await picture("titles")
        print("Split view: opening, own editor, autosave, swapping sides, links, moving to the main editor, rename, close, and titles that rename pages passed")
        exit(0)
    }
}
