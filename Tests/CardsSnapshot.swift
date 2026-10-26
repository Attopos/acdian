import SwiftUI
import AppKit
import WebKit

// Opens one page in the real editor and saves a picture of it.
// Usage: cards-snapshot <pages folder> <page path> <output.png> [dark]
@main
struct CardsSnapshot {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "acdian-cards-snapshot-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:URL(fileURLWithPath:args[1]))
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1260,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:args.count > 4 ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        guard let page = model.index?.files.first(where: { $0.relativePath == args[2] }) else { print("missing page"); exit(1) }
        model.open(page,skipConfirmation:true)
        try await Task.sleep(nanoseconds:5_000_000_000)
        func webView(_ view: NSView) -> WKWebView? { if let web = view as? WKWebView { return web }; for sub in view.subviews { if let web = webView(sub) { return web } }; return nil }
        guard let web = webView(window.contentView!) else { print("no web view"); exit(1) }
        let image = try await web.takeSnapshot(configuration:nil)
        let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[3]))
        // A plain click on a card opens its word page.
        _ = try? await web.evaluateJavaScript("[...document.querySelectorAll('.cm-card')].find(c=>c.textContent.startsWith('abate')).click()")
        try await Task.sleep(nanoseconds:3_000_000_000)
        print("after click:",model.currentPagePath ?? "-")
        let word = try await web.takeSnapshot(configuration:nil)
        try NSBitmapImageRep(data:word.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[3].replacingOccurrences(of:".png",with:"-word.png")))
        print("snapshot written")
        exit(0)
    }
}
