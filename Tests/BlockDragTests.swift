import AppKit
import SwiftUI
import WebKit

@main
struct BlockDragTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = BlockDragRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class BlockDragRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-block-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-block-tests-\(UUID().uuidString)"
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
    func callJS(_ script: String) async -> String { (try? await LiveEditorHost.shared.view.callAsyncJavaScript(script,contentWorld:.page) as? String) ?? "nil" }
    func run() async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let page = "# 第一节\n\n第一段文字。\n\n## 第二节\n\n- 甲\n- 乙\n\n> 引用\n\n结尾段落。\n"
        let file = root.appendingPathComponent("P.md")
        try page.write(to:file,atomically:true,encoding:.utf8)
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.3)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        model.open(model.index!.files.first!)
        var ready = false
        for _ in 0..<200 { if (await js("!!document.querySelector('.cm-heading')") as? Bool) == true { ready = true; break }; await pause(0.05) }
        check(ready,"the page renders")
        // Hover each block at the middle of its first line: the handle shows left of the text, level with that line.
        let hover = await callJS("""
        const v=window.acdianEditor,out=[];
        for(const text of ['第一节','第一段','第二节','乙','引用','结尾']){
          const pos=v.state.doc.toString().indexOf(text),c=v.coordsAtPos(pos,1);
          v.scrollDOM.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:c.left+10,clientY:(c.top+c.bottom)/2}));
          const h=document.querySelector('.cm-block-handle').getBoundingClientRect();
          out.push([text,!document.querySelector('.cm-block-handle').hidden,Math.round(c.left-h.right),Math.round((h.top+h.bottom)/2-(c.top+c.bottom)/2)]);
        }
        return JSON.stringify(out);
        """)
        print("  hover: \(hover)")
        let rows = (try? JSONSerialization.jsonObject(with:Data(hover.utf8)) as? [[Any]]) ?? []
        check(rows.count == 6 && rows.allSatisfy { ($0[1] as? Bool) == true },"every block shows a handle")
        check(rows.allSatisfy { (($0[2] as? Int) ?? 0) >= 30 && (($0[2] as? Int) ?? 0) <= 60 },"the handle sits clear left of the text (further for list items and quotes, whose text is indented)")
        check(rows.allSatisfy { abs(($0[3] as? Int) ?? 99) <= 2 },"the handle is level with the block's first line")
        // Drag the last paragraph to just above the second heading.
        let drag = await callJS("""
        const v=window.acdianEditor,doc=v.state.doc.toString(),at=t=>v.coordsAtPos(doc.indexOf(t),1);
        const c=at('结尾');v.scrollDOM.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:c.left+10,clientY:(c.top+c.bottom)/2}));
        const h=document.querySelector('.cm-block-handle'),r=h.getBoundingClientRect();
        h.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0,clientX:r.left+5,clientY:r.top+5}));
        const t=at('第二节'),y=t.top+2;
        window.dispatchEvent(new MouseEvent('mousemove',{clientX:r.left+5,clientY:y-20}));
        window.dispatchEvent(new MouseEvent('mousemove',{clientX:r.left+5,clientY:y}));
        const line=document.querySelector('.cm-block-drop'),lr=line.getBoundingClientRect(),shown=!line.hidden;
        window.dispatchEvent(new MouseEvent('mouseup',{clientX:r.left+5,clientY:y}));
        return JSON.stringify({shown,lineY:Math.round(lr.top),headingTop:Math.round(t.top),text:v.state.doc.toString()});
        """)
        print("  drag: \(drag)")
        check(drag.contains("\"shown\":true"),"a pink line shows where the block will land")
        check(drag.contains("第一段文字。\\n\\n结尾段落。\\n\\n## 第二节"),"the dragged block lands above the heading")
        await pause(1)
        let saved = (try? String(contentsOf:file,encoding:.utf8)) ?? ""
        check(saved == "# 第一节\n\n第一段文字。\n\n结尾段落。\n\n## 第二节\n\n- 甲\n- 乙\n\n> 引用\n","the new order is saved")
        print("  saved: \(saved.debugDescription)")
    }
}

