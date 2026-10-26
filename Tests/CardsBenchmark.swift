import SwiftUI
import AppKit
import WebKit

// Times the card page and the pages folder with thousands of word pages.
// Usage: cards-benchmark <pages folder> <card page path> <normal page path> <snapshot.png>
@main
struct CardsBenchmark {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath:args[1])
        func ms(_ start: Date) -> String { String(format:"%.0f ms",Date().timeIntervalSince(start) * 1000) }
        var start = Date()
        let index = try VaultIndex(root:root)
        print("scan \(index.files.count) files:",ms(start))
        start = Date()
        let texts = index.files.filter { $0.ext == "md" }.compactMap { try? VaultFileIO.readMarkdown(at:$0.url,allowedRoot:root) }
        print("read \(texts.count) pages for search:",ms(start))

        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "acdian-cards-benchmark-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<1000 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        for _ in 0..<1000 where model.searchedPageCount < texts.count { try await Task.sleep(nanoseconds:10_000_000) }
        for query in ["ab","relinquish","less strong"] {
            start = Date(); model.query = query; let count = model.matches.count
            print("sidebar search \"\(query)\" (\(count) results):",ms(start))
        }
        model.query = ""
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1260,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds:3_000_000_000)
        func webView(_ view: NSView) -> WKWebView? { if let web = view as? WKWebView { return web }; for sub in view.subviews { if let web = webView(sub) { return web } }; return nil }
        if let warm = model.index?.files.first(where: { $0.relativePath == args[3] }) { model.open(warm,skipConfirmation:true) }
        var found: WKWebView?
        for _ in 0..<500 where found == nil { found = webView(window.contentView!); try await Task.sleep(nanoseconds:10_000_000) }
        guard let web = found else { print("no web view"); exit(1) }
        try await Task.sleep(nanoseconds:1_500_000_000)
        model.goHome()
        try await Task.sleep(nanoseconds:500_000_000)
        func js(_ code: String) async -> Any? { try? await web.evaluateJavaScript(code) }
        let measure = """
        (()=>{const v=window.acdianEditor,r={};let t=performance.now();
        v.dispatch({selection:{anchor:v.state.doc.line(Math.min(3,v.state.doc.lines)).from}});r.caret=performance.now()-t;
        t=performance.now();for(let i=0;i<5;i++)v.dispatch({changes:{from:0,insert:'x'},userEvent:'input'});r.typing=(performance.now()-t)/5;
        v.dispatch({changes:{from:0,to:5}});
        r.nodes=document.querySelectorAll('*').length;r.lines=v.state.doc.lines;return JSON.stringify(r);})()
        """
        for (label,path) in [("normal page",args[3]),("card page",args[2])] {
            guard let page = model.index?.files.first(where: { $0.relativePath == path }) else { print("missing",path); continue }
            start = Date()
            model.open(page,skipConfirmation:true)
            for _ in 0..<1000 { if (await js("document.querySelector('.cm-content') && window.acdianEditor && window.acdianEditor.state.doc.length > 0 && (\(label == "card page") ? !!document.querySelector('.cm-card') : true)") as? Bool) == true { break }; try await Task.sleep(nanoseconds:5_000_000) }
            print("\(label) open:",ms(start))
            try await Task.sleep(nanoseconds:500_000_000)
            print("\(label) editor:",await js(measure) as? String ?? "-")
        }
        print("card page letter switch:",await js("(()=>{const t=performance.now();document.querySelector('.ac-index-rail button[data-group=\"S\"]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));window.dispatchEvent(new MouseEvent('mouseup'));return (performance.now()-t).toFixed(1)+' ms, '+document.querySelectorAll('.cm-card').length+' cards';})()") as? String ?? "-")
        print("card page search:",await js("(()=>{const s=document.querySelector('.cm-cards-search');s.value='ab';const t=performance.now();s.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'}));return (performance.now()-t).toFixed(1)+' ms';})()") as? String ?? "-")
        _ = await js("(()=>{const s=document.querySelector('.cm-cards-search');s.value='';document.querySelector('.ac-index-rail button[data-group=\"A\"]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));window.dispatchEvent(new MouseEvent('mouseup'));})()")
        try await Task.sleep(nanoseconds:500_000_000)
        let image = try await web.takeSnapshot(configuration:nil)
        try NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[4]))
        exit(0)
    }
}
