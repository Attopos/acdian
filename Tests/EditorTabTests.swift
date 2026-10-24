import AppKit
import SwiftUI
import WebKit

// Real WebKit editor in an off-screen window, with synthetic pages in a
// temporary folder and isolated preferences. Build with every source except
// AcdianApp.swift; see README.
@main
struct EditorTabTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = EditorTabRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class EditorTabRunner: NSObject, NSApplicationDelegate {
    var checks = 0
    var window: NSWindow?
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-editor-tab-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-editor-tab-tests-\(UUID().uuidString)"
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failed: Error?
            do { try await run() } catch { failed = error }
            try? fm.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite)
            if let failed { print("EditorTabs FAILED after \(checks) checks: \(failed.localizedDescription)"); exit(1) }
            exit(0)
        }
    }
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain:"EditorTabTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        checks += 1
    }
    func pause(_ seconds: Double = 0.01) async { try? await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
    func eventually(_ message: String, timeout: Double = 8, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if try await condition() { try check(true,message); return }; await pause(0.005) }
        let ok = try await condition(); try check(ok,message)
    }
    var web: WKWebView { LiveEditorHost.shared.view }
    func js(_ script: String) async throws -> Any? { try await web.evaluateJavaScript(script) }
    func editor() async throws -> [String:Any] {
        // topLine is the document line at the top of the view, topOffset how far
        // that line starts above the view top: together, what the reader sees.
        try await js("""
        (()=>{const v=window.acdianEditor,d=window.acdianGetDocument(),box=v.scrollDOM.getBoundingClientRect();
        const pos=v.posAtCoords({x:box.left+box.width/2,y:box.top+2},false),line=v.state.doc.lineAt(pos),block=v.lineBlockAt(line.from);
        return {...d,scrollTop:v.scrollDOM.scrollTop,topLine:line.number,topOffset:Math.round(box.top-(v.documentTop+block.top)),lines:document.querySelectorAll('.cm-line').length};})()
        """) as? [String:Any] ?? [:]
    }
    func frames(_ count: Int = 3) async throws { for _ in 0..<count { _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>r(1)))",contentWorld:.page) } }
    func sameView(_ a: [String:Any], _ b: [String:Any]) -> Bool {
        a["topLine"] as? Int == b["topLine"] as? Int && abs((a["topOffset"] as? Int ?? 0) - (b["topOffset"] as? Int ?? 0)) <= 2
    }
    func shows(_ path: String) async throws -> Bool { let d = try await editor(); return d["currentPath"] as? String == path && (d["lines"] as? Int ?? 0) > 0 }

    func run() async throws {
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        func page(_ title: String, sections: Int) -> String {
            var text = "# \(title)\n\n"
            for n in 1...sections { text += "## Section \(n)\n\nParagraph \(n) with **bold** text, a [[Link]] and 中文🌸 to read.\n\n- item one\n- item two\n\n" }
            return text
        }
        let long = page("Long",sections:400), other = page("Other",sections:120)
        for (name,body) in [("Long.md",long),("Other.md",other),("Third.md","# Third\n\nShort page.\n")] { try Data(body.utf8).write(to:root.appendingPathComponent(name)) }
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("No isolated preferences") }

        _ = LiveEditorHost.shared
        try await eventually("The editor page loads before any window shows it") { (try? await self.js("typeof window.acdianSetDocument")) as? String == "function" }
        var model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.05)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:820),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        LiveEditorHost.shared.model = model
        try await eventually("Pages load") { model.index != nil && !model.loading }
        func file(_ path: String) -> VaultEntry { model.index!.files.first { $0.relativePath == path }! }
        func tab(_ path: String) -> UUID { model.tabs.first { $0.path == path }!.id }

        model.open(file("Long.md"))
        try await eventually("The first page shows in the prewarmed editor") { try await self.shows("Long.md") }
        try await frames()
        let middle = (long as NSString).range(of:"Paragraph 200 ").location
        _ = try await js("window.acdianEditor.dispatch({selection:{anchor:\(middle)},scrollIntoView:true});window.acdianInsertText('新');window.acdianEditor.dispatch({selection:{anchor:\(middle + 4),head:\(middle + 10)}});")
        try await frames()
        let before = try await editor()
        let edited = before["text"] as? String ?? ""
        try check(edited == (long as NSString).replacingCharacters(in:NSRange(location:middle,length:0),with:"新"), "Typing reaches the open page")
        try check((before["scrollTop"] as? Double ?? 0) > 2000, "The page is scrolled to its middle")
        try await eventually("The edit is saved") { (try? String(contentsOf:self.root.appendingPathComponent("Long.md"),encoding:.utf8)) == edited }

        model.open(file("Other.md"))
        try await eventually("Another page opens in a new tab") { try await self.shows("Other.md") }
        try await frames()
        try check(web === LiveEditorHost.shared.view && web.superview != nil && model.tabs.count == 2, "Both tabs share the one editor web view")
        _ = try await js("window.acdianEditor.scrollDOM.scrollTop=1500")
        try await frames()
        let otherView = try await editor()

        model.selectTab(tab("Long.md"))
        try await eventually("Switching back shows the first tab") { try await self.shows("Long.md") }
        try await frames()
        let back = try await editor()
        try check(back["text"] as? String == edited && model.text == edited, "The tab keeps its text")
        try check(back["selectionAnchor"] as? Int == before["selectionAnchor"] as? Int && back["selectionHead"] as? Int == before["selectionHead"] as? Int, "The tab keeps its selection")
        try check(sameView(back,before), "The tab keeps its scroll position")
        _ = try await js("window.acdianUndo()")
        try await eventually("Undo after switching back undoes the edit made before switching") { model.text == long }
        _ = try await js("window.acdianRedo()")
        try await eventually("Redo brings it back") { model.text == edited }
        try await eventually("Undo and redo are saved") { (try? String(contentsOf:self.root.appendingPathComponent("Long.md"),encoding:.utf8)) == edited }

        model.selectTab(tab("Other.md"))
        try await eventually("The other tab shows again") { try await self.shows("Other.md") }
        try await frames()
        let otherBack = try await editor()
        try check(sameView(otherBack,otherView), "Each tab keeps its own scroll position")

        let outside = "# Long\n\nRewritten by another app.\n"
        try Data(outside.utf8).write(to:root.appendingPathComponent("Long.md"))
        model.selectTab(tab("Long.md"))
        try await eventually("A page changed on disk while in the back shows the new text") { (try await self.editor())["text"] as? String == outside && model.text == outside && !model.dirty }
        _ = try await js("window.acdianUndo()")
        await pause(0.1)
        try check(model.text == outside, "History from before the outside change is not applied to the new text")

        model.newPageFromEditor()
        try await eventually("A new page shows in the editor") { (try await self.editor())["currentPath"] as? String == model.selected?.relativePath && model.isDraft }
        let draftDocument = model.editorDocumentID
        _ = try await js("window.acdianEditor.focus();window.acdianInsertText('Draft body 中文')")
        try await eventually("Typing creates the new page's file") { model.currentPagePath != nil && !model.currentPagePath!.hasPrefix(".acdian-draft") }
        try check(model.editorDocumentID == draftDocument, "The first save keeps the editor's document")
        await pause(0.7) // past CodeMirror's history grouping delay
        _ = try await js("window.acdianInsertText('!')")
        try await eventually("Typing continues in the same editor") { model.text == "Draft body 中文!" }
        _ = try await js("window.acdianUndo()")
        try await eventually("Undo still works after the first save") { model.text == "Draft body 中文" }

        // Timings, on the same pages: click to the editor holding the page.
        func timeSwitch(_ path: String) async throws -> Double {
            let start = Date()
            model.selectTab(tab(path))
            while !(try await shows(path)) { await pause(0.0005) }
            return Date().timeIntervalSince(start) * 1000
        }
        model.open(file("Third.md"))
        try await eventually("A third page opens") { try await self.shows("Third.md") }
        var samples: [Double] = []
        for n in 0..<20 { samples.append(try await timeSwitch(n % 2 == 0 ? "Other.md" : "Third.md")) }
        samples.sort()
        print(String(format:"EditorTabs timing: tab switch median %.1f ms, slowest %.1f ms (20 switches, Other.md %d KB)",samples[10],samples[19],other.utf8.count / 1024))

        // The front tab's place survives a relaunch.
        model.selectTab(tab("Other.md"))
        try await eventually("Back on the other tab") { try await self.shows("Other.md") }
        _ = try await js("window.acdianEditor.dispatch({selection:{anchor:500,head:510}});window.acdianEditor.scrollDOM.scrollTop=3000")
        try await frames()
        let atQuit = try await editor()
        var quitSaved = false
        model.withEditorSnapshot { quitSaved = model.saveBeforeLeaving() }
        try await eventually("Quitting takes the latest snapshot") { quitSaved }
        model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.05)
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        LiveEditorHost.shared.model = model
        try await eventually("A relaunch reopens the front tab") { try await self.shows("Other.md") }
        try await frames()
        let relaunched = try await editor()
        try check(relaunched["selectionAnchor"] as? Int == 500 && relaunched["selectionHead"] as? Int == 510, "A relaunch restores the tab's selection")
        try check(sameView(relaunched,atQuit), "A relaunch restores the tab's scroll position")
        // ACDIAN_TEST_SNAPSHOT=<folder> saves what the editor draws, for a look by eye.
        if let folder = ProcessInfo.processInfo.environment["ACDIAN_TEST_SNAPSHOT"] {
            let image = try await web.takeSnapshot(configuration:nil)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) {
                try png.write(to:URL(fileURLWithPath:folder).appendingPathComponent("editor-after-relaunch.png"))
            }
        }
        print("EditorTabs: \(checks) checks passed in the real WebKit editor for shared editor, kept text, selection, scroll, undo/redo, disk changes, first save and relaunch")
    }
}
