import AppKit
import SwiftUI
import WebKit

@main
struct TableColumnTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = TableColumnRunner()
        app.delegate = runner
        app.run()
    }
}

@MainActor final class TableColumnRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-table-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-table-tests-\(UUID().uuidString)"
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
    func widths() async -> [Int] { (await js("JSON.stringify([...document.querySelector('.cm-table-header').querySelectorAll('.cm-table-cell')].map(c=>Math.round(c.getBoundingClientRect().width)))") as? String).flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [Int] } ?? [] }
    func rowWidth() async -> Int { (await js("Math.round(document.querySelector('.cm-table-header').getBoundingClientRect().width)") as? NSNumber)?.intValue ?? 0 }
    func drag(_ dx: Int) async -> String {
        let script = """
        const v=window.acdianEditor,cell=document.querySelector('.cm-table-header .cm-table-cell'),r=cell.getBoundingClientRect(),p={x:r.right-2,y:(r.top+r.bottom)/2};
        const next=()=>new Promise(res=>requestAnimationFrame(()=>requestAnimationFrame(res)));
        const fire=(type,q,target)=>target.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,clientX:q.x,clientY:q.y,button:0,buttons:type==='mouseup'?0:1,detail:1,view:window}));
        fire('mousemove',p,cell);const cursor=document.body.classList.contains('cm-table-col-resize');
        fire('mousedown',p,document.elementFromPoint(p.x,p.y));await next();
        for(let i=1;i<=10;i++){fire('mousemove',{x:p.x+\(dx)*i/10,y:p.y},document);await next();}
        const mid=v.state.doc.toString();
        fire('mouseup',{x:p.x+\(dx),y:p.y},document);await next();
        return JSON.stringify({cursor,unchangedMidDrag:mid===v.state.doc.toString()?false:true,sel:v.state.selection.main.head});
        """
        return (try? await LiveEditorHost.shared.view.callAsyncJavaScript(script,contentWorld:.page) as? String) ?? "nil"
    }

    func run() async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let page = "Before.\n\n| Name | Note | Size |\n| --- | :---: | ---: |\n| a | b | c |\n| longer text here | x | 1 |\n\nAfter.\n"
        let file = root.appendingPathComponent("Table.md")
        try page.write(to:file,atomically:true,encoding:.utf8)
        guard let preferences = UserDefaults(suiteName:suite) else { return }
        let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:0.3)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1180,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        model.open(model.index!.files.first { $0.relativePath == "Table.md" }!)
        var ok = false
        for _ in 0..<200 { if (await js("!!document.querySelector('.cm-table-header .cm-table-cell')") as? Bool) == true { ok = true; break }; await pause(0.05) }
        check(ok,"the table renders")
        let total = await rowWidth(), start = await widths()
        print("  row \(total), cells \(start)")
        check(start.count == 3 && start.max()! - start.min()! <= 1,"a plain separator keeps equal columns")
        let result = await drag(120)
        print("  drag: \(result)")
        check(result.contains("\"cursor\":true"),"the column edge shows a resize cursor")
        let after = await widths()
        print("  cells after \(after)")
        check(after.count == 3 && after[0] > start[0] + 90 && after[1] < start[1] - 90 && abs(after[2] - start[2]) <= 2,"dragging the edge moves width between the two columns")
        check(after.reduce(0,+) <= total && after.reduce(0,+) >= total - 4,"the columns still fill one line")
        let rows = (await js("[...document.querySelectorAll('.cm-table-row:not(.cm-table-separator)')].every(l=>{const c=l.querySelectorAll('.cm-table-cell');const t=c[0].getBoundingClientRect().top;return [...c].every(x=>Math.abs(x.getBoundingClientRect().top-t)<2)})") as? Bool) ?? false
        check(rows,"every row keeps its cells on one line")
        await pause(1)
        let saved = try String(contentsOf:file,encoding:.utf8)
        print("  saved: \(saved.debugDescription)")
        check(saved.contains("|:") && saved.contains(":|") && !saved.contains("| --- |"),"the widths and alignment are saved in the separator")
        check(saved.contains("| longer text here | x | 1 |"),"cell text is untouched")
        _ = await js("window.acdianEditor.dispatch({changes:{from:0,insert:'x'}})")
        await pause(0.2)
        check(await widths() == after,"widths stay after other edits")
        _ = await js("(()=>{const v=window.acdianEditor;v.dispatch({changes:{from:0,to:1}});})()")
        try saved.write(to:file,atomically:true,encoding:.utf8)
        let config = WKSnapshotConfiguration()
        if let image = try? await LiveEditorHost.shared.view.takeSnapshot(configuration:config), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) {
            let out = ProcessInfo.processInfo.environment["ACDIAN_SNAPSHOT"] ?? root.deletingLastPathComponent().appendingPathComponent("acdian-table.png").path
            try? png.write(to:URL(fileURLWithPath:out)); print("  snapshot: \(out)")
        }
    }
}
