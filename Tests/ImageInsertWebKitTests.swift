import AppKit
import SwiftUI
import WebKit

// Pastes and drops into the real editor web view, off screen, on a page in a
// temporary folder with isolated preferences. The general pasteboard is used,
// as WebKit reads pastes from it, and is put back as it was afterwards.
@main
struct ImageInsertWebKitTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = ImageInsertRunner()
        app.delegate = runner
        app.run()
    }
}

/// A drag from another app, as AppKit would describe it to the editor.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?
    init(_ pasteboard: NSPasteboard,at point: NSPoint,in window: NSWindow) { draggingPasteboard = pasteboard; draggingLocation = point; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],for view: NSView?,classes classArray: [AnyClass],searchOptions: [NSPasteboard.ReadingOptionKey : Any] = [:],using block: (NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor final class ImageInsertRunner: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-image-insert-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-image-insert-tests-\(UUID().uuidString)"
    var window: NSWindow?
    var failures = 0, passes = 0
    var savedPasteboard: [[NSPasteboard.PasteboardType:Data]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LiveEditorHost.shared
        let general = NSPasteboard.general
        savedPasteboard = (general.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues:item.types.compactMap { type in item.data(forType:type).map { (type,$0) } }) }
        Task { @MainActor in
            do { try await run() } catch { print("FAIL: \(error)"); failures += 1 }
            general.clearContents()
            general.writeObjects(savedPasteboard.map { saved in let item = NSPasteboardItem(); for (type,data) in saved { item.setData(data,forType:type) }; return item })
            try? FileManager.default.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite)
            print("\(passes) passed, \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func check(_ ok: Bool,_ name: String) { if ok { passes += 1; print("ok - \(name)") } else { failures += 1; print("FAIL - \(name)") } }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
    func js(_ script: String) async -> Any? { try? await LiveEditorHost.shared.view.evaluateJavaScript(script) }
    func waitFor(_ timeout: Double,_ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout { if await condition() { return true }; await pause(0.05) }
        return false
    }
    func caretAtEnd() async { _ = await js("(()=>{const v=window.acdianEditor;v.focus();v.dispatch({selection:{anchor:v.state.doc.length}});})()") }
    func paste() { let view = LiveEditorHost.shared.view; view.window?.makeFirstResponder(view); NSApp.sendAction(Selector(("paste:")),to:view,from:nil) }

    func run() async throws {
        let fm = FileManager.default, vault = root.appendingPathComponent("vault",isDirectory:true), outside = root.appendingPathComponent("outside",isDirectory:true)
        try fm.createDirectory(at:vault,withIntermediateDirectories:true); try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("# Page\n\nHello\n\nEnd\n".utf8).write(to:vault.appendingPathComponent("Page.md"))
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:40,pixelsHigh:30,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for x in 0..<40 { for y in 0..<30 { rep.setColor(NSColor(srgbRed:0.95,green:0.4,blue:0.6,alpha:1),atX:x,y:y) } }
        let png = rep.representation(using:.png,properties:[:])!
        let photo = outside.appendingPathComponent("holiday photo.png"); try png.write(to:photo)

        guard let preferences = UserDefaults(suiteName:suite) else { throw URLError(.cancelled) }
        let model = AppModel(preferences:preferences,pagesRoot:vault,autosaveDelay:0.3)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:1100,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless(); self.window = window
        while model.index == nil || model.loading { await pause(0.005) }
        model.open(model.index!.files.first { $0.relativePath == "Page.md" }!)
        check(await waitFor(5) { (await js("window.acdianEditor?.state.doc.toString().includes('End')") as? Bool) == true },"the page opens in the editor")
        let attachments = vault.appendingPathComponent("Attachments")
        func stored() -> [String] { ((try? fm.contentsOfDirectory(atPath:attachments.path)) ?? []).sorted() }

        // A screenshot on the clipboard.
        let general = NSPasteboard.general
        general.clearContents(); general.setData(png,forType:.png)
        await caretAtEnd(); paste()
        check(await waitFor(5) { model.text.contains("![[Attachments/Pasted image ") },"pasting a picture embeds it in the page")
        let pasted = stored().first ?? ""
        check(pasted.hasPrefix("Pasted image ") && (try? Data(contentsOf:attachments.appendingPathComponent(pasted))) == png,"the picture is saved in Attachments: \(stored())")
        check(await waitFor(5) { (await js("[...document.querySelectorAll('.cm-content img')].some(i=>i.complete&&i.naturalWidth===40)") as? Bool) == true },"the editor shows the pasted picture")
        check(model.text.hasSuffix("End\n![[Attachments/\(pasted)]]\n"),"the link goes at the caret: \(model.text.debugDescription)")

        // A file copied in Finder.
        general.clearContents(); general.writeObjects([photo as NSURL])
        await caretAtEnd(); paste()
        check(await waitFor(5) { model.text.contains("![[Attachments/holiday photo.png]]") },"pasting a copied file embeds a copy of it")
        check(stored().contains("holiday photo.png") && fm.fileExists(atPath:photo.path),"the file is copied into Attachments and the original stays")

        // Plain text, and text an app copies with a picture of itself.
        general.clearContents(); general.setString(" plain words",forType:.string)
        await caretAtEnd(); paste()
        check(await waitFor(5) { model.text.hasSuffix(" plain words") },"plain text pastes as text")
        general.clearContents(); general.declareTypes([.string,.png],owner:nil); general.setString(" cell text",forType:.string); general.setData(png,forType:.png)
        let before = stored().count
        await caretAtEnd(); paste()
        check(await waitFor(5) { model.text.hasSuffix(" cell text") },"text copied with a picture of itself pastes as text")
        check(stored().count == before,"and stores no picture")

        // A file dropped from another app, between Hello and End.
        let view = LiveEditorHost.shared.view
        let target = await js("(()=>{const v=window.acdianEditor,p=v.state.doc.toString().indexOf('End'),c=v.coordsAtPos(p);return [c.left+1,(c.top+c.bottom)/2,p];})()") as? [NSNumber] ?? []
        if target.count == 3 {
            let pagePoint = NSPoint(x:target[0].doubleValue,y:target[1].doubleValue)
            let local = view.isFlipped ? pagePoint : NSPoint(x:pagePoint.x,y:view.bounds.height-pagePoint.y)
            let drag = NSPasteboard(name:NSPasteboard.Name("acdian-drop-test-\(UUID().uuidString)")); drag.clearContents(); drag.writeObjects([photo as NSURL])
            let info = FakeDrag(drag,at:view.convert(local,to:nil),in:window)
            check(view.draggingEntered(info) == .copy,"a file dragged in from another app is accepted as a copy")
            check(await waitFor(3) { (await js("window.acdianEditor.state.selection.main.head") as? NSNumber)?.intValue == target[2].intValue },"the caret follows the pointer while dragging")
            check(view.performDragOperation(info),"the drop is taken")
            check(await waitFor(5) { model.text.contains("Hello\n\n![[Attachments/holiday photo-2.png]]\nEnd") },"the dropped file is embedded where it was dropped: \(model.text.debugDescription)")
            drag.releaseGlobally()
        } else { check(false,"could not measure the drop point") }

        check(await waitFor(5) { (try? String(contentsOf:vault.appendingPathComponent("Page.md"),encoding:.utf8)) == model.text },"the page saves with its image links")
        if let path = ProcessInfo.processInfo.environment["ACDIAN_SNAPSHOT"], let rep = window.contentView?.bitmapImageRepForCachingDisplay(in:window.contentView!.bounds) {
            window.contentView!.cacheDisplay(in:window.contentView!.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
        }
    }
}
