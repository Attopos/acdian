import SwiftUI
import AppKit
import WebKit

// Lays pages out in the real window at many sizes, with the sidebar, outline and
// split view on and off, and checks that the title, cover and text share a centred
// column, that nothing runs past the page, and that the outline stays clear of the text.
// Usage: layout-audit [folder for pictures of the non-page screens]
@main
struct LayoutAudit {
    static let measure = """
    JSON.stringify((()=>{const v=window.acdianEditor,d=v.scrollDOM,s=d.getBoundingClientRect(),t=document.querySelector('.cm-page-title'),range=document.createRange();range.selectNodeContents(t);
    const title=range.getBoundingClientRect(),content=v.contentDOM.getBoundingClientRect(),walk=document.createTreeWalker(v.contentDOM,NodeFilter.SHOW_TEXT);let first=null;for(let n;(n=walk.nextNode());)if(n.data.trim()&&parseFloat(getComputedStyle(n.parentElement).fontSize)>0&&!n.parentElement.closest('.cm-fold-toggle')){const r=document.createRange();r.selectNodeContents(n);first=r.getClientRects()[0];break;}
    const image=document.querySelector('.cm-block-image img')?.getBoundingClientRect();
    return {w:s.width,titleLeft:title.left-s.left,titleTop:t.getBoundingClientRect().top-s.top,titleBottom:t.getBoundingClientRect().bottom-s.top,textLeft:first?first.left-s.left:-1,contentTop:content.top-s.top,contentMiddle:(content.left+content.right)/2-s.left,scrollX:d.scrollWidth-d.clientWidth,titleRight:t.scrollWidth-t.clientWidth,pageX:document.scrollingElement.scrollWidth-document.scrollingElement.clientWidth,image:image?(image.left+image.right)/2-s.left:null};})())
    """
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-layout-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Notes"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let long = String(repeating:"正文文字用来观察版心的位置和换行。Some English words too. ",count:12)
        for name in ["Main","Side","Other"] { try "## Heading of \(name)\n\n\(long)\n\n> [!note] Callout\n> \(long)\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```js\nconst a = 1;\n```\n\n$$a^2+b^2=c^2$$\n\n## Second\n\nText\n".write(to:root.appendingPathComponent("Notes/\(name).md"),atomically:true,encoding:.utf8) }
        let suite = "acdian-layout-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await wait(0.01) }
        let window = NSWindow(contentRect:NSRect(x:-9000,y:-9000,width:1260,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        func file(_ name: String) -> VaultEntry { model.index!.files.first { $0.relativePath == "Notes/\(name).md" }! }
        model.open(file("Main"),skipConfirmation:true)
        try await wait(2)
        var problems: [String] = [], checks = 0
        func read(_ web: WKWebView, _ label: String) async throws {
            guard let json = try await web.evaluateJavaScript(measure) as? String, let m = try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any] else { problems.append("\(label): no measure"); return }
            func n(_ key: String) -> Double { (m[key] as? NSNumber)?.doubleValue ?? .nan }
            checks += 1
            if abs(n("titleLeft") - n("textLeft")) > 1.5 { problems.append("\(label): title at \(n("titleLeft")), text at \(n("textLeft"))") }
            if abs(n("contentMiddle") - n("w") / 2) > 8 { problems.append("\(label): column centre \(n("contentMiddle")) of \(n("w"))") }
            if n("titleBottom") > n("contentTop") + 1 { problems.append("\(label): title overlaps text") }
            if n("titleTop") != 0 { problems.append("\(label): blank above the title \(n("titleTop"))") }
            if n("scrollX") > 0 || n("pageX") > 0 || n("titleRight") > 0 { problems.append("\(label): runs past the page \(n("scrollX")) \(n("pageX")) \(n("titleRight"))") }
        }
        // AppKit views of the window, to find what overlaps what.
        func outlineClear(_ label: String) async throws {
            guard model.splitEntry == nil, model.showOutline else { return }
            let width = LiveEditorHost.shared.view.bounds.width
            let textLeft = max(0,(width - 860) / 2) + 58
            if width >= ContentView.outlineFitWidth, textLeft < 232 - 0.5 { problems.append("\(label): outline over the text, text at \(textLeft)") }
        }
        let sizes: [(CGFloat,CGFloat)] = [(920,620),(1000,700),(1100,720),(1260,840),(1440,900),(1512,982),(1728,1117),(1920,1080),(2560,1440),(3440,1440),(5120,1440)]
        let states: [(String,(AppModel) -> Void)] = [
            ("plain",{ $0.showSidebar = true; $0.showOutline = true }),
            ("no sidebar",{ $0.showSidebar = false; $0.showOutline = true }),
            ("no outline",{ $0.showSidebar = true; $0.showOutline = false })
        ]
        for (width,height) in sizes {
            window.setContentSize(NSSize(width:width,height:height))
            for (name,apply) in states {
                apply(model); try await wait(0.25)
                window.contentView?.layoutSubtreeIfNeeded()
                try await read(LiveEditorHost.shared.view,"\(Int(width))x\(Int(height)) \(name)")
                try await outlineClear("\(Int(width))x\(Int(height)) \(name)")
            }
            model.showSidebar = true; model.showOutline = true
            model.openInSplit(file("Side")); try await wait(1)
            for side in [false,true] {
                if model.splitOnLeft != side { model.swapSplitSides() }
                try await wait(0.3)
                try await read(LiveEditorHost.shared.view,"\(Int(width))x\(Int(height)) split main left:\(!side)")
                try await read(SplitEditorHost.shared.view,"\(Int(width))x\(Int(height)) split side left:\(side)")
                let main = LiveEditorHost.shared.view.bounds.width, other = SplitEditorHost.shared.view.bounds.width
                if abs(main - other) > 2 { problems.append("\(Int(width)): columns \(main) and \(other)") }
            }
            model.showSidebar = false; try await wait(0.3)
            try await read(LiveEditorHost.shared.view,"\(Int(width))x\(Int(height)) split no sidebar")
            model.showSidebar = true
            if model.splitOnLeft { model.swapSplitSides() }
            model.closeSplit(); try await wait(0.3)
        }
        print("checks",checks)
        if CommandLine.arguments.count > 1 {
            let folder = URL(fileURLWithPath:CommandLine.arguments[1])
            func shot(_ name: String) throws {
                let view = window.contentView!
                if let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:rep); try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name + ".png")) }
            }
            for (width,height) in [(CGFloat(920),CGFloat(620)),(2560,1440)] {
                window.setContentSize(NSSize(width:width,height:height))
                model.goHome(); try await wait(0.6); try shot("home-\(Int(width))")
                model.enterModule(model.modules.first?.id); try await wait(0.6); try shot("module-\(Int(width))")
                model.showTrash(); try await wait(0.6); try shot("trash-\(Int(width))")
                model.showMarket(); try await wait(0.6); try shot("market-\(Int(width))")
                model.newPageFromEditor(); try await wait(0.8); try shot("new-\(Int(width))")
                model.open(file("Main"),skipConfirmation:true); try await wait(0.8); try shot("page-\(Int(width))")
            }
        }
        if problems.isEmpty { print("Layout: all sizes and states line up") } else { print("problems",problems.count); for problem in problems.prefix(40) { print(" ",problem) } }
        exit(problems.isEmpty ? 0 : 1)
    }
}
