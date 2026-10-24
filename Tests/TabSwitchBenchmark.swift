import AppKit
import SwiftUI
import WebKit

// Times opening and switching pages in the real app views, off screen, on
// synthetic large pages in a temporary folder with isolated preferences. It
// uses only API that 1.2.8 also has, so the same file measures both versions;
// pass -D ACDIAN_HOST when building against 1.2.9 to warm the editor at launch
// as the app does. A page counts as shown once the editor holds it with its
// lines laid out, and as painted after the next animation frame.
@main
struct TabSwitchBenchmark {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = BenchmarkRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class BenchmarkRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-tab-benchmark-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-tab-benchmark-\(UUID().uuidString)"
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if ACDIAN_HOST
        _ = LiveEditorHost.shared
        #endif
        Task { @MainActor in
            do { try await run() } catch { print("Benchmark failed: \(error)") }
            try? FileManager.default.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite)
            exit(0)
        }
    }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
    func webViews(_ view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        return (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    /// The editor that holds `path` with its lines laid out, if any does yet.
    func editorShowing(_ path: String) async -> WKWebView? {
        for web in webViews(window?.contentView) {
            let shown = try? await web.evaluateJavaScript("(()=>{const d=window.acdianGetDocument&&window.acdianGetDocument();return !!(d&&d.currentPath===\(Self.quoted(path))&&document.querySelector('.cm-line')&&window.acdianEditor.contentDOM.offsetHeight>0)})()") as? Bool
            if shown == true { return web }
        }
        return nil
    }
    static func quoted(_ text: String) -> String { String(data:try! JSONSerialization.data(withJSONObject:[text]),encoding:.utf8)!.dropFirst().dropLast().description }
    /// Milliseconds until shown and until painted.
    func time(_ path: String, _ action: () -> Void) async throws -> (shown: Double, painted: Double) {
        let start = Date()
        action()
        var web: WKWebView?
        while web == nil {
            web = await editorShowing(path)
            if Date().timeIntervalSince(start) > 20 { throw NSError(domain:"Benchmark",code:1,userInfo:[NSLocalizedDescriptionKey:"\(path) never showed"]) }
            if web == nil { await pause(0.0005) }
        }
        let shown = Date().timeIntervalSince(start) * 1000
        _ = try await web!.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>r(1)))",contentWorld:.page)
        return (shown,Date().timeIntervalSince(start) * 1000)
    }
    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        // Five notes of mixed Markdown: 1,500 sections (about 200 KB) each, or
        // ACDIAN_BENCH_SECTIONS sections.
        let sections = Int(ProcessInfo.processInfo.environment["ACDIAN_BENCH_SECTIONS"] ?? "") ?? 1500
        var sizes: [Int] = []
        for n in 1...5 {
            var text = "# Large note \(n)\n\n"
            for s in 1...max(1,sections) { text += "## Section \(s)\n\nParagraph \(s) of note \(n), with **bold**, *italic*, `code`, a [[Link \(s)]] and 中文内容🌸.\n\n- [ ] task \(s)\n- item\n\n" }
            try Data(text.utf8).write(to:root.appendingPathComponent("Large \(n).md")); sizes.append(text.utf8.count)
        }
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.5)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:820),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        await pause(1.0) // a reader takes a moment before the first click
        func file(_ n: Int) -> VaultEntry { model.index!.files.first { $0.relativePath == "Large \(n).md" }! }
        func tab(_ n: Int) -> UUID { model.tabs.first { $0.path == "Large \(n).md" }!.id }

        let first = try await time("Large 1.md") { model.open(file(1)) }
        var opens: [(Double,Double)] = []
        for n in 2...5 { await pause(0.3); opens.append(try await time("Large \(n).md") { model.open(file(n)) }) }
        var switches: [(Double,Double)] = []
        for i in 0..<30 { await pause(0.15); let n = [1,3,2,5,4][i % 5]; switches.append(try await time("Large \(n).md") { model.selectTab(tab(n)) }) }
        func summary(_ values: [(Double,Double)]) -> String {
            let shown = values.map(\.0).sorted(), painted = values.map(\.1).sorted()
            return String(format:"shown median %.1f ms (max %.1f), painted median %.1f ms (max %.1f)",shown[shown.count/2],shown.last!,painted[painted.count/2],painted.last!)
        }
        #if ACDIAN_HOST
        let version = "1.2.9"
        #else
        let version = "1.2.8"
        #endif
        print("ACdian \(version) benchmark, 5 notes of \(sizes.min()! / 1024)-\(sizes.max()! / 1024) KB:")
        print(String(format:"  first page after launch: shown %.1f ms, painted %.1f ms",first.shown,first.painted))
        print("  opening a page in a new tab (4): " + summary(opens))
        print("  switching between open tabs (30): " + summary(switches))
        print("  editor web views alive: \(webViews(window.contentView).count)")
    }
}
