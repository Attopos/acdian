import AppKit
import SwiftUI
import WebKit

// Checks acdian-interactive blocks in the real app views, off screen, on a
// synthetic page in a temporary folder with isolated preferences. The block's
// script cannot report back except through its size, so it encodes each
// result as a height step that the editor page then reads from the frame.
@main
struct InteractiveBlockTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = InteractiveRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class InteractiveRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-interactive-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-interactive-tests-\(UUID().uuidString)"
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
    func frameHeight(_ index: Int) async -> Int { (await js("(()=>{const f=document.querySelectorAll('iframe.cm-interactive-frame')[\(index)];return f?Math.round(f.getBoundingClientRect().height):-1})()") as? NSNumber)?.intValue ?? -1 }
    func waitFor(_ timeout: Double,_ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout { if await condition() { return true }; await pause(0.05) }
        return false
    }

    static let probe = """
    <style>body{padding:0}#box{height:50px}</style>
    <div id="box"></div>
    <link rel="stylesheet" href="lib/katex.min.css">
    <script src="lib/d3.min.js"></script>
    <script src="lib/katex.min.js"></script>
    <script>
    (async () => {
      let h = 100;
      if (typeof d3?.select === 'function') h += 1;
      if (typeof katex?.render === 'function') h += 2;
      let parentBlocked = false; try { parent.document.title; } catch { parentBlocked = true; }
      if (parentBlocked) h += 4;
      const blocked = url => fetch(url).then(() => false, () => true);
      if (await blocked('https://example.com/')) h += 8;
      if (await blocked('acdian-resource://vault/Note.md')) h += 16;
      const image = await new Promise(resolve => { const i = new Image(); i.onload = () => resolve(false); i.onerror = () => resolve(true); i.src = 'https://example.com/x.png'; });
      if (image) h += 32;
      let storage = false; try { localStorage.length; } catch { storage = true; }
      if (storage) h += 64;
      const box = document.getElementById('box');
      box.style.height = h + 'px';
      acdian.onTheme(theme => { box.style.height = (theme === 'light' ? h + 300 : h) + 'px'; });
    })();
    </script>
    """

    func run() async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let page = "# Interactive\n\nBefore.\n\n```acdian-interactive\n\(Self.probe)\n```\n\nBetween.\n\n```acdian-interactive height=180\n<p>Fixed</p>\n```\n\nAfter.\n"
        try page.write(to:root.appendingPathComponent("Interactive.md"),atomically:true,encoding:.utf8)
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.5)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        _ = await js("window.__msgs=[];addEventListener('message',e=>__msgs.push(JSON.stringify(e.data)))")
        model.open(model.index!.files.first { $0.relativePath == "Interactive.md" }!)
        if ProcessInfo.processInfo.environment["ACDIAN_DEBUG"] != nil { await pause(3); print(await js("JSON.stringify(window.__msgs)") ?? "nil") }
        check(await waitFor(10) { (await self.js("document.querySelectorAll('iframe.cm-interactive-frame').length") as? NSNumber)?.intValue == 2 },"both blocks show as frames")
        check(await js("[...document.querySelectorAll('iframe.cm-interactive-frame')].every(f=>f.getAttribute('sandbox')==='allow-scripts')") as? Bool == true,"frames are sandboxed to scripts only")
        check(await waitFor(10) { let h = await self.frameHeight(0); return h >= 100 && h != 240 },"the probe ran and sized its frame")
        let height = await frameHeight(0) - 100
        print("  probe result bits: \(height)")
        check(height & 1 != 0,"bundled d3 loads")
        check(height & 2 != 0,"bundled KaTeX loads")
        check(height & 4 != 0,"the frame cannot reach the editor page")
        check(height & 8 != 0,"network requests are blocked")
        check(height & 16 != 0,"page files cannot be fetched")
        check(height & 32 != 0,"remote images are blocked")
        check(height & 64 != 0,"storage is unavailable to the frame")
        check(await frameHeight(1) == 180,"height= keeps a fixed frame height")
        check(await js("document.querySelector('.cm-block-interactive .cm-interactive-bar button')!==null") as? Bool == true,"the block has its toolbar")

        // Theme changes reach the running block without restarting it.
        _ = await js("document.documentElement.classList.add('light')")
        check(await waitFor(5) { await self.frameHeight(0) == height + 100 + 300 },"light appearance reaches the block")
        _ = await js("document.documentElement.classList.remove('light')")
        check(await waitFor(5) { await self.frameHeight(0) == height + 100 },"dark appearance reaches the block")

        // Typing elsewhere keeps the running frame; the frame element is the same one.
        _ = await js("window.__probeFrame=document.querySelector('iframe.cm-interactive-frame')")
        _ = await js("(()=>{const v=window.acdianEditor;const p=v.state.doc.toString().indexOf('Before.')+7;v.dispatch({changes:{from:p,insert:' typed'},selection:{anchor:p+6}});})()")
        await pause(0.3)
        check(await js("window.__probeFrame===document.querySelector('iframe.cm-interactive-frame')&&window.__probeFrame.isConnected") as? Bool == true,"typing above a block does not rebuild it")

        // Edit source: the caret moves inside, the source shows; leaving runs it again.
        _ = await js("document.querySelectorAll('.cm-interactive-bar button')[1].click()")
        await pause(0.3)
        check((await js("document.querySelectorAll('iframe.cm-interactive-frame').length") as? NSNumber)?.intValue == 1,"edit source shows the block's code")
        check(await js("document.querySelector('.cm-content').textContent.includes('lib/d3.min.js')") as? Bool == true,"the code is editable text")
        _ = await js("window.acdianEditor.dispatch({selection:{anchor:0}})")
        check(await waitFor(5) { (await self.js("document.querySelectorAll('iframe.cm-interactive-frame').length") as? NSNumber)?.intValue == 2 },"leaving the code shows the frame again")
        check(await waitFor(10) { await self.frameHeight(0) == height + 100 },"the block runs again after editing")

        // ACDIAN_DEMO names a page to show for the snapshot instead of the probe.
        if let demo = ProcessInfo.processInfo.environment["ACDIAN_DEMO"] {
            try String(contentsOfFile:demo,encoding:.utf8).write(to:root.appendingPathComponent("Demo.md"),atomically:true,encoding:.utf8)
            model.refresh()
            while model.index?.files.contains(where: { $0.relativePath == "Demo.md" }) != true { await pause(0.05) }
            model.open(model.index!.files.first { $0.relativePath == "Demo.md" }!)
            await pause(1); _ = await js("document.documentElement.classList.toggle('light',\(ProcessInfo.processInfo.environment["ACDIAN_LIGHT"] == "1"))")
            print("  demo errors: \(await js("(()=>{const f=document.querySelector('iframe.cm-interactive-frame');return f?Math.round(f.getBoundingClientRect().height):-1})()") ?? "none")")
            await pause(2.5)
        }
        await pause(0.5)
        let config = WKSnapshotConfiguration()
        if let image = try? await LiveEditorHost.shared.view.takeSnapshot(configuration:config), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) {
            let out = ProcessInfo.processInfo.environment["ACDIAN_SNAPSHOT"] ?? root.deletingLastPathComponent().appendingPathComponent("acdian-interactive.png").path
            try? png.write(to:URL(fileURLWithPath:out)); print("  snapshot: \(out)")
        }
        let saved = try String(contentsOf:root.appendingPathComponent("Interactive.md"),encoding:.utf8)
        check(saved.contains("```acdian-interactive height=180\n<p>Fixed</p>\n```"),"the page source is unchanged by rendering")
    }
}
