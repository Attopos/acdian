import SwiftUI
import AppKit
import WebKit

// Opens one page in the real editor and saves a picture of it.
// Usage: page-snapshot <pages folder> <page path> <output.png> [dark]
@main
struct PageSnapshot {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "acdian-cards-snapshot-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:URL(fileURLWithPath:args[1]))
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1260,height:CGFloat(Double(ProcessInfo.processInfo.environment["ACDIAN_HEIGHT"] ?? "") ?? 840)),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:args.count > 4 ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        guard let page = model.index?.files.first(where: { $0.relativePath == args[2] }) else { print("missing page"); exit(1) }
        model.open(page,skipConfirmation:true)
        try await Task.sleep(nanoseconds:5_000_000_000)
        func webView(_ view: NSView) -> WKWebView? { if let web = view as? WKWebView { return web }; for sub in view.subviews { if let web = webView(sub) { return web } }; return nil }
        guard let web = webView(window.contentView!) else { print("no web view"); exit(1) }
        // ACDIAN_SELECT_LINES=<a>-<b> selects from the middle of line a to the middle of line b.
        if let spec = ProcessInfo.processInfo.environment["ACDIAN_SELECT_LINES"]?.split(separator:"-").compactMap({ Int($0) }), spec.count == 2 {
            _ = try? await web.evaluateJavaScript("(()=>{const v=window.acdianEditor,a=v.state.doc.line(\(spec[0])),b=v.state.doc.line(\(spec[1]));v.dispatch({selection:{anchor:a.from+Math.floor(a.length/3),head:b.from+Math.floor(b.length*2/3)}});v.focus();})()")
            try await Task.sleep(nanoseconds:800_000_000)
        }
        // ACDIAN_SCROLL_LINE=<n> scrolls the page so that line n sits near the top.
        if let line = ProcessInfo.processInfo.environment["ACDIAN_SCROLL_LINE"].flatMap(Int.init) {
            _ = try? await web.evaluateJavaScript("(()=>{const v=window.acdianEditor;v.scrollDOM.scrollTop=v.lineBlockAt(v.state.doc.line(\(line)).from).top-500;v.requestMeasure();})()")
            try await Task.sleep(nanoseconds:2_000_000_000)
        }
        let image = try await web.takeSnapshot(configuration:nil)
        let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[3]))
        // ACDIAN_CLICK_LINK=1 clicks the first link once, then reports where it went.
        if ProcessInfo.processInfo.environment["ACDIAN_CLICK_LINK"] != nil {
            let tabs = model.tabs.count
            _ = try? await web.evaluateJavaScript("document.querySelector('.cm-content [data-live-target]').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}))")
            try await Task.sleep(nanoseconds:2_000_000_000)
            print("after link click:",model.currentPagePath ?? "-","tabs",tabs,"->",model.tabs.count)
        }
        print("snapshot written")
        exit(0)
    }
}
