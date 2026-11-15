import AppKit
import SwiftUI
import WebKit

@main
struct CaretBoxTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = CaretBoxRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class CaretBoxRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-caret-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-caret-tests-\(UUID().uuidString)"
    var window: NSWindow?
    var failures = 0, passes = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LiveEditorHost.shared
        Task { @MainActor in
            do { try await run() } catch { print("FAIL: \(error)"); failures += 1 }
            try? FileManager.default.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite)
            print("\(passes) passed, \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func check(_ ok: Bool,_ name: String) { if ok { passes += 1; print("ok - \(name)") } else { failures += 1; print("FAIL - \(name)") } }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
    func js(_ script: String) async -> Any? { try? await LiveEditorHost.shared.view.evaluateJavaScript(script) }
    func run() async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let page = "Intro.\n\n# \n\n## \n\n### \n\n## VPN\n\n> \n\nPlain\n"
        try page.write(to:root.appendingPathComponent("P.md"),atomically:true,encoding:.utf8)
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:5)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        model.open(model.index!.files.first!)
        var ready = false
        for _ in 0..<200 { if (await js("!!document.querySelector('.cm-heading')") as? Bool) == true { ready = true; break }; await pause(0.05) }
        check(ready,"the page renders")
        // The input method places its candidates at the caret box WebKit reports
        // for the selection; an empty box sends them to the window's corner.
        for (label,line) in [("empty H1",3),("empty H2",5),("empty H3",7),("start of a heading",9),("empty quote",11)] {
            let script = "(()=>{const v=window.acdianEditor,l=v.state.doc.line(\(line)),p=line===9?l.from+3:l.to;v.focus();v.dispatch({selection:{anchor:p}});const s=getSelection();if(!s.rangeCount)return 'none';const b=s.getRangeAt(0).getBoundingClientRect(),c=v.coordsAtPos(p);return JSON.stringify([Math.round(b.left),Math.round(b.top),Math.round(b.height),Math.round(c.left),Math.round(c.top)]);})()".replacingOccurrences(of:"line===9",with:"\(line)===9")
            let r = (await js(script) as? String).flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [Int] } ?? []
            print("  \(label): \(r)")
            check(r.count == 5 && r[2] > 10 && abs(r[0] - r[3]) <= 8 && abs(r[1] - r[4]) <= 8,"\(label): the caret has a box where it is drawn")
        }
        let hint = await js("getComputedStyle(document.querySelector('.cm-heading-empty'),'::after').content") as? String
        check(hint == "\"H1\"","an empty heading still shows its level hint")
    }
}

