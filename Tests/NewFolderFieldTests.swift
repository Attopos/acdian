import AppKit
import SwiftUI

// The sidebar's new-folder row in an off-screen window, with a temporary
// pages folder and isolated preferences. Build with every source except
// AcdianApp.swift; see README.
@main
struct NewFolderFieldTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = NewFolderFieldRunner()
        app.delegate = runner
        app.run()
    }
}

private struct TestSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing:0) { SidebarTree(entries:model.index?.entries ?? []); Spacer() }.frame(width:260,height:320)
    }
}

@MainActor final class NewFolderFieldRunner: NSObject, NSApplicationDelegate {
    var checks = 0
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-new-folder-tests-\(UUID().uuidString)",isDirectory:true)
    let suite = "acdian-new-folder-tests-\(UUID().uuidString)"
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failed: Error?
            do { try await run() } catch { failed = error }
            try? fm.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite)
            if let failed { print("NewFolderField FAILED after \(checks) checks: \(failed.localizedDescription)"); exit(1) }
            print("NewFolderField: \(checks) checks passed for the in-place name field: shown at once, name selected, Return renames, Escape keeps the old name, leaving the field or clicking elsewhere keeps the typed one; double-click renames a file with its extension unselected")
            exit(0)
        }
    }
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain:"NewFolderFieldTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        checks += 1
    }
    func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { checks += 1; return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"NewFolderFieldTest",code:2,userInfo:[NSLocalizedDescriptionKey:message])
    }
    func run() async throws {
        try fm.createDirectory(at:root.appendingPathComponent("Box"),withIntermediateDirectories:true)
        try Data("# Page".utf8).write(to:root.appendingPathComponent("Box/Page.md"))
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("No isolated preferences") }
        let model = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:root,trashNow:{ Date() })
        model.language = .simplifiedChinese
        model.index = try VaultIndex(root:root)
        let window = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:260,height:320),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:TestSidebar().environmentObject(model))
        window.orderFrontRegardless(); window.makeKey()
        func box() -> VaultEntry { AppModel.entry("Box",in:model.index!.entries)! }
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }

        // Made on a folder: the row shows inside it with the whole name selected.
        model.newFolder(near:box())
        try await eventually("The name field takes the keyboard") { editor()?.string == "新建文件夹" }
        try check(editor()!.selectedRange() == NSRange(location:0,length:("新建文件夹" as NSString).length),"The whole default name is selected, ready to type over")
        if let path = ProcessInfo.processInfo.environment["ACDIAN_SNAPSHOT"], let view = window.contentView,
           let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:image)
            try image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
        }
        editor()!.insertText("第一章",replacementRange:editor()!.selectedRange())
        editor()!.doCommand(by:#selector(NSResponder.insertNewline(_:)))
        try await eventually("Return renames the folder") { model.renamingPath == nil && self.fm.fileExists(atPath:self.root.appendingPathComponent("Box/第一章").path) }
        try check(!fm.fileExists(atPath:root.appendingPathComponent("Box/新建文件夹").path) && AppModel.entry("Box/第一章",in:model.index!.entries) != nil,"Only the typed name remains, on disk and in the sidebar")

        // Made on a file: Escape keeps the default name.
        model.newFolder(near:AppModel.entry("Box/Page.md",in:model.index!.entries)!)
        try await eventually("A second name field takes the keyboard") { editor()?.string == "新建文件夹" }
        editor()!.insertText("不要",replacementRange:editor()!.selectedRange())
        editor()!.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
        try await eventually("Escape ends editing") { model.renamingPath == nil }
        try check(fm.fileExists(atPath:root.appendingPathComponent("Box/新建文件夹").path) && !fm.fileExists(atPath:root.appendingPathComponent("Box/不要").path),"Escape keeps the name the folder was made with")

        // Clicking elsewhere keeps what was typed.
        model.newFolder(near:box())
        try await eventually("A third name field takes the keyboard") { editor()?.string == "新建文件夹 2" }
        editor()!.insertText("资料",replacementRange:editor()!.selectedRange())
        window.makeFirstResponder(nil)
        try await eventually("Leaving the field renames the folder") { model.renamingPath == nil && self.fm.fileExists(atPath:self.root.appendingPathComponent("Box/资料").path) }
        try await eventually("No name field is left in the sidebar") { editor() == nil }

        // A mouse click elsewhere in the sidebar ends editing, as in Finder.
        model.newFolder(near:box())
        try await eventually("A fourth name field takes the keyboard") { editor()?.string == "新建文件夹 2" }
        editor()!.insertText("练习",replacementRange:editor()!.selectedRange())
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = NSEvent.mouseEvent(with:type,location:NSPoint(x:200,y:20),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            NSApp.sendEvent(event)
        }
        try await eventually("Clicking elsewhere renames the folder") { model.renamingPath == nil && self.fm.fileExists(atPath:self.root.appendingPathComponent("Box/练习").path) }
        window.close()

        // Double-clicking a file starts renaming it, with its extension unselected.
        let solo = root.appendingPathComponent("solo",isDirectory:true)
        try fm.createDirectory(at:solo,withIntermediateDirectories:true)
        try Data("pdf".utf8).write(to:solo.appendingPathComponent("Solo.pdf"))
        let soloModel = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:solo,trashNow:{ Date() })
        soloModel.index = try VaultIndex(root:solo)
        let soloWindow = NSWindow(contentRect:NSRect(x:-6000,y:-6000,width:260,height:320),styleMask:[.titled],backing:.buffered,defer:false)
        soloWindow.isReleasedWhenClosed = false
        soloWindow.contentView = NSHostingView(rootView:TestSidebar().environmentObject(soloModel))
        soloWindow.orderFrontRegardless(); soloWindow.makeKey()
        try await Task.sleep(nanoseconds:300_000_000)
        let height = soloWindow.contentView!.bounds.height
        for clicks in [1,2] {
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:NSPoint(x:100,y:height-15),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:soloWindow.windowNumber,context:nil,eventNumber:0,clickCount:clicks,pressure:1)!
                NSApp.sendEvent(event)
            }
        }
        func soloEditor() -> NSTextView? { soloWindow.firstResponder as? NSTextView }
        try await eventually("Double-clicking a file opens its name for editing") { soloModel.renamingPath == "Solo.pdf" && soloEditor()?.string == "Solo.pdf" }
        try check(soloEditor()!.selectedRange() == NSRange(location:0,length:4),"Only the name before the extension is selected")
        soloEditor()!.insertText("Duo",replacementRange:soloEditor()!.selectedRange())
        soloEditor()!.doCommand(by:#selector(NSResponder.insertNewline(_:)))
        try await eventually("Return renames the file") { soloModel.renamingPath == nil && self.fm.fileExists(atPath:solo.appendingPathComponent("Duo.pdf").path) }
        try await eventually("The first click opened the file, and it stays open under its new name") { soloModel.selected?.relativePath == "Duo.pdf" }
        soloWindow.close()
    }
}
