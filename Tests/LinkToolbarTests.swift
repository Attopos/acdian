import AppKit
import SwiftUI
import WebKit

@main
struct LinkToolbarTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = LinkToolbarRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class LinkToolbarRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-link-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-link-tests-\(UUID().uuidString)"
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
    func select(_ text: String) async {
        _ = await js("(()=>{const v=window.acdianEditor,d=v.state.doc.toString(),i=d.indexOf(\(String(reflecting:text)));v.focus();v.dispatch({selection:{anchor:i,head:i+\(text.utf16.count)}});})()")
        await pause(0.2)
    }
    func button() async -> [String:String] {
        let script = "JSON.stringify((()=>{const b=document.querySelector('.cm-format-link'),bold=document.querySelector('.cm-format-bold');if(!b)return {};return {pressed:b.getAttribute('aria-pressed'),title:b.title,bg:getComputedStyle(b).backgroundColor,boldBg:getComputedStyle(bold).backgroundColor};})())"
        return (await js(script) as? String).flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:String] } ?? [:]
    }

    func run() async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let page = "Visit [ACdian](https://example.com) and plain words.\n"
        let file = root.appendingPathComponent("Links.md")
        try page.write(to:file,atomically:true,encoding:.utf8)
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.3)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        model.open(model.index!.files.first { $0.relativePath == "Links.md" }!)
        var ok = false
        for _ in 0..<200 { if (await js("!!document.querySelector('.cm-live-link')") as? Bool) == true { ok = true; break }; await pause(0.05) }
        check(ok,"the link renders")
        let blocked = await js("(()=>{const e=new MouseEvent('contextmenu',{bubbles:true,cancelable:true,button:2});document.querySelector('.cm-content').dispatchEvent(e);return e.defaultPrevented;})()") as? Bool
        check(blocked == true,"a right-click in the editor does not open the system menu")
        NSApp.activate(ignoringOtherApps:true); window.makeKey(); window.makeFirstResponder(LiveEditorHost.shared.view)
        await pause(0.3)
        if (await js("window.acdianEditor.hasFocus") as? Bool) != true {
            _ = await js("(()=>{const v=window.acdianEditor;Object.defineProperty(v,'hasFocus',{get:()=>true});v.contentDOM.dispatchEvent(new FocusEvent('focus'));})()")
            await pause(0.3)
            print("  focus faked: offscreen windows get no keyboard focus in remote sessions")
        }
        await select("plain")
        let plain = await button()
        print("  plain: \(plain)")
        check(plain["pressed"] == "false","plain text leaves the link button unlit")
        await select("ACdian")
        let lit = await button()
        print("  link: \(lit)")
        check(lit["pressed"] == "true" && lit["bg"] != plain["bg"],"selected link text lights the link button")
        check(lit["title"]?.hasPrefix("Remove link") == true || lit["title"]?.hasPrefix("取消链接") == true,"its tooltip offers to remove the link")
        _ = await js("document.querySelector('.cm-format-link').click()")
        await pause(0.2)
        let text = await js("window.acdianEditor.state.doc.toString()") as? String
        check(text == "Visit ACdian and plain words.\n","a second click removes the link and keeps the text")
        let after = await button()
        check(after["pressed"] == "false","the button goes dark again")
        await pause(1)
        check((try? String(contentsOf:file,encoding:.utf8)) == "Visit ACdian and plain words.\n","the page is saved without the link")
    }
}
