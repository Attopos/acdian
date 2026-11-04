import SwiftUI
import AppKit
import WebKit

// Lays out real text in the real editor at many widths and reports bad line
// breaks: closing punctuation starting a line, opening punctuation ending one,
// words split in the middle, and text running past its column. Reads only.
// Usage: wrap-audit <folder of .md files> [lines per page]
@main
struct WrapAudit {
    static let script = """
    (()=>{const closing=/^[）」』】》〉〕。，、；：！？”’％]|^[,;:)\\]}](?![A-Za-z0-9])/,opening=/[（「『【《〈“‘(\\[{]$/,word=/[A-Za-z0-9]/;const found=[];
    for(const line of document.querySelectorAll('.cm-content > .cm-line')){
      if(/cm-code-|cm-table-|cm-callout-empty/.test(line.className))continue;
      const style=getComputedStyle(line),box=line.getBoundingClientRect(),right=box.right-parseFloat(style.paddingRight);
      const kind=/cm-callout/.test(line.className)?'callout':/cm-quote/.test(line.className)?'quote':/cm-heading/.test(line.className)?'heading':/cm-list/.test(line.className)?'list':'text';
      const rows=[];const walk=document.createTreeWalker(line,NodeFilter.SHOW_TEXT);
      for(let t;(t=walk.nextNode());){
        if(t.parentElement.closest('.cm-callout-icon,.cm-fold-toggle,.cm-inline-math,.cm-list-bullet,.cm-task-widget'))continue;
        if(parseFloat(getComputedStyle(t.parentElement).fontSize)===0)continue;
        for(let i=0;i<t.length;i++){
          const code=t.data.charCodeAt(i);if(code>=0xDC00&&code<=0xDFFF)continue;
          const r=document.createRange();r.setStart(t,i);r.setEnd(t,i+(code>=0xD800&&code<=0xDBFF?2:1));
          const q=r.getBoundingClientRect();if(!q.width&&!q.height)continue;
          const mid=(q.top+q.bottom)/2;let row=rows.find(x=>mid>x.top&&mid<x.bottom);
          if(!row){row={top:q.top,bottom:q.bottom,cells:[]};rows.push(row);}
          row.top=Math.min(row.top,q.top);row.bottom=Math.max(row.bottom,q.bottom);row.cells.push({c:r.toString(),l:q.left,r:q.right});
        }
      }
      rows.sort((a,b)=>a.top-b.top);
      rows.forEach((row,index)=>{
        row.cells.sort((a,b)=>a.l-b.l);
        const text=row.cells.map(x=>x.c).join(''),clean=text.trim(),last=row.cells.filter(x=>x.c.trim()).at(-1);
        if(last&&last.r>right+1.5)found.push(['overflow',kind,clean.slice(-24)]);
        if(index&&closing.test(clean)&&!/\\s$/.test(rows[index-1].cells.map(x=>x.c).join('')))found.push(['closing-starts-line',kind,rows[index-1].cells.map(x=>x.c).join('').trim().slice(-14)+' ⏎ '+clean.slice(0,10)]);
        if(index+1<rows.length&&opening.test(clean))found.push(['opening-ends-line',kind,clean.slice(-14)]);
        if(index+1<rows.length){const end=row.cells.at(-1)?.c||'',next=rows[index+1].cells[0]?.c||'';if(word.test(end)&&word.test(next))found.push(['word-split',kind,clean.slice(-14)+' ⏎ '+rows[index+1].cells.map(x=>x.c).join('').slice(0,10)]);}
      });
    }
    return JSON.stringify({lines:document.querySelectorAll('.cm-content > .cm-line').length,found});})()
    """
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let source = URL(fileURLWithPath:CommandLine.arguments[1]), chunk = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 60 : 60
        var lines: [String] = []
        let files = FileManager.default.enumerator(at:source,includingPropertiesForKeys:nil)!
        for case let url as URL in files where url.pathExtension == "md" && !url.path.contains("GRE words") {
            guard let text = try? String(contentsOf:url,encoding:.utf8) else { continue }
            var fence = false
            for raw in text.components(separatedBy:.newlines) {
                if raw.hasPrefix("```") { fence.toggle(); continue }
                // Text only: pictures, tables and formulas have no lines to break.
                if fence || raw.count < 30 || raw.hasPrefix("|") || raw.hasPrefix("$$") || raw.hasPrefix("!") || raw.hasPrefix("<") { continue }
                lines.append(raw); lines.append("")
            }
        }
        print("lines to lay out:",lines.count / 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-wrap-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let suite = "acdian-wrap-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        var pages = 0
        for start in stride(from:0,to:lines.count,by:chunk * 2) {
            pages += 1
            try lines[start..<min(start + chunk * 2,lines.count)].joined(separator:"\n").write(to:root.appendingPathComponent("p\(pages).md"),atomically:true,encoding:.utf8)
        }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<500 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        let window = NSWindow(contentRect:NSRect(x:-9000,y:-9000,width:1260,height:12000),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        let web = LiveEditorHost.shared.view
        var totals: [String:Int] = [:], samples: [String:[String]] = [:], laidOut = 0
        for page in 1...pages {
            model.open(model.index!.files.first { $0.relativePath == "p\(page).md" }!,skipConfirmation:true)
            try await Task.sleep(nanoseconds:600_000_000)
            for width in stride(from:930.0,through:1260.0,by:37.0) {
                window.setContentSize(NSSize(width:width,height:12000))
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:120_000_000)
                _ = try? await web.evaluateJavaScript("window.acdianEditor.requestMeasure();1")
                guard let json = try await web.evaluateJavaScript(script) as? String, let result = try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any], let found = result["found"] as? [[String]] else { continue }
                laidOut += result["lines"] as? Int ?? 0
                for item in found {
                    let key = item[0] + " / " + item[1]
                    totals[key,default:0] += 1
                    if samples[key,default:[]].count < 6, !samples[key,default:[]].contains(item[2]) { samples[key,default:[]].append(item[2]) }
                }
            }
        }
        print("lines laid out:",laidOut)
        for key in totals.keys.sorted() { print(key,totals[key]!); for sample in samples[key] ?? [] { print("   ",sample) } }
        print(totals.isEmpty ? "no bad breaks" : "bad breaks found")
        exit(0)
    }
}
