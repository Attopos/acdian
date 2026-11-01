import SwiftUI
import AppKit

// Times dropping a sidebar page into another folder, with the whole window on
// screen offscreen: how soon the sidebar shows the page at its new place, and
// the longest the main thread stalls while the move settles.
// Usage: drag-move-benchmark <copy of a pages folder> <module> <page or folder> <folder> [open]
// (page and folder are relative to the pages folder; the page is moved there
// and back, so use a copy).
@main
struct DragMoveBenchmark {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath:args[1]), module = args[2], page = args[3], folder = args[4]
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
        let suite = "acdian-drag-benchmark-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<2000 where model.index == nil || model.loading { try await wait(0.01) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1400,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        model.enterModule(module)
        model.setFolderExpanded(folder,true)
        // "open" as a fifth argument opens the page first, so it moves while open.
        if args.count > 5, args[5] == "open", let file = model.index!.files.first(where: { $0.relativePath == page }) { model.open(file) }
        let pages = model.index!.files.filter { $0.ext == "md" }.count
        for _ in 0..<3000 where model.searchedPageCount < pages { try await wait(0.01) }
        try await wait(2)

        // A background thread asks the main thread to run a tiny block every
        // few milliseconds and records how long each request waited.
        final class Watchdog: @unchecked Sendable {
            let lock = NSLock(); var worst = 0.0, stalls = 0, running = true
            func start() {
                Thread.detachNewThread {
                    while self.lock.withLock({ self.running }) {
                        let asked = Date(), done = DispatchSemaphore(value:0)
                        DispatchQueue.main.async {
                            let waited = Date().timeIntervalSince(asked)
                            self.lock.withLock { self.worst = max(self.worst,waited); if waited > 0.05 { self.stalls += 1 } }
                            done.signal()
                        }
                        done.wait(); Thread.sleep(forTimeInterval:0.002)
                    }
                }
            }
            func reset() { lock.withLock { worst = 0; stalls = 0 } }
            func report() -> (Double,Int) { lock.withLock { (worst,stalls) } }
        }
        let watchdog = Watchdog(); watchdog.start()
        func ms(_ seconds: Double) -> String { String(format:"%.0f ms",seconds * 1000) }

        var path = page
        for round in 0..<(Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "") ?? 6) {
            let destination = round % 2 == 0 ? folder : (page as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let expected = destination.isEmpty ? name : destination + "/" + name
            try await wait(1)
            watchdog.reset()
            let start = Date()
            model.movePage(path,to:PageDropTarget(folder:destination))
            let call = Date().timeIntervalSince(start)
            var shown: Double?
            for _ in 0..<2000 {
                if let index = model.index, AppModel.entry(expected,in:index.entries) != nil, model.currentPagePath != path { shown = Date().timeIntervalSince(start); break }
                try await wait(0.001)
            }
            try await wait(Double(ProcessInfo.processInfo.environment["SETTLE"] ?? "") ?? 3)
            let (worst,stalls) = watchdog.report()
            print("move \(round + 1): movePage returned in \(ms(call)), sidebar shows it after \(shown.map(ms) ?? "never"), worst main-thread stall \(ms(worst)), stalls over 50 ms: \(stalls)")
            path = expected
        }
        exit(0)
    }
}
