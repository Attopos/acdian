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
        print("Split view: opening, own editor, autosave, swapping sides, links, moving to the main editor, rename and close passed")
        exit(0)
    }
}
