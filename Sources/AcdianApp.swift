import SwiftUI
import AppKit

@main struct AcdianApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("acdian") {
            ContentView().environmentObject(model).onAppear { delegate.model = model; DispatchQueue.main.async { delegate.configureWindow() } }
        }.defaultSize(width:1260,height:840).windowStyle(.hiddenTitleBar).commands {
            CommandGroup(replacing:.newItem) {
                Button(model.localized("新建页面")) { model.newPageFromEditor() }.keyboardShortcut("n")
            }
            CommandGroup(replacing:.saveItem) { Button(model.localized("保存页面")) { model.saveFromEditor() }.keyboardShortcut("s").disabled(model.selected?.ext != "md"); Button(model.localized("重新载入文件")) { model.reload() }.disabled(model.persistedPage == nil) }
            CommandGroup(after:.textEditing) { Button(model.localized("搜索页面")) { NotificationCenter.default.post(name:Notification.Name("acdianSearch"),object:nil) }.keyboardShortcut("f"); Button(model.localized("插入附件…")) { model.importAttachment() }.keyboardShortcut("i",modifiers:[.command,.shift]).disabled(model.selected?.ext != "md") }
            CommandMenu(model.localized("视图")) {
                Button(model.localized("显示或隐藏侧栏")) { withAnimation(.easeInOut(duration:0.18)) { model.showSidebar.toggle() } }.keyboardShortcut("s",modifiers:[.control,.command])
                Picker(model.localized("外观"),selection:$model.appearance) { ForEach(AppAppearance.allCases) { Text(model.localized($0.title)).tag($0) } }
                Divider()
                Button(model.localized("显示或隐藏目录")) { model.showOutline.toggle() }.keyboardShortcut("l",modifiers:[.command,.shift])
                Button(model.localized("刷新页面")) { model.refresh() }.keyboardShortcut("r")
                Button(model.localized("所有页面")) { model.goHome() }.keyboardShortcut("h",modifiers:[.command,.shift])
            }
            CommandGroup(replacing:.appInfo) { Button(model.localized("关于 acdian")) { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"acdian",.applicationVersion:(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.2.7"),.credits:NSAttributedString(string:model.localized("本地 Markdown 阅读器"))]) } }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var closePending = false
    private var closeApproved = false
    private var terminationPending = false
    private var lastWindowCloseApproved = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A drag released outside any drop target, or cancelled with Esc, gets
        // no drop callback; the next mouse-up or key press clears its highlight.
        NSEvent.addLocalMonitorForEvents(matching:[.leftMouseUp,.leftMouseDown,.keyDown]) { [weak self] event in
            if let model = self?.model, model.sidebarDrop != nil || model.draggingPath != nil { DispatchQueue.main.async { model.setSidebarDrop(nil); model.draggingPath = nil } }
            return event
        }
        NSApp.appearance = model?.appearance.nsAppearance ?? AppAppearance(rawValue:UserDefaults.standard.string(forKey:"appAppearance") ?? "")?.nsAppearance; AppDelegate.syncSystemLanguage(AppLanguage.stored()); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true) }
    // AppKit reads its menus and bundle strings once at launch, so a language
    // change saves the choice and relaunches to load every resource in it.
    static func syncSystemLanguage(_ language: AppLanguage) { UserDefaults.standard.set([language.rawValue],forKey:"AppleLanguages") }
    static func switchLanguage(to language: AppLanguage, model: AppModel) {
        guard language != model.language else { return }
        model.language = language
        syncSystemLanguage(language)
        UserDefaults.standard.synchronize()
        // A helper waits for this process to exit, then reopens the app. If the
        // quit is cancelled (unsaved edits), it gives up instead of relaunching later.
        let script = "for i in $(seq 1 150); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || { /usr/bin/open \"$0\"; exit 0; }; sleep 0.2; done"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath:"/bin/sh")
        helper.arguments = ["-c",script,Bundle.main.bundlePath]
        guard (try? helper.run()) != nil else { return }
        NSApp.terminate(nil)
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshTrash() }
    func configureWindow() { for window in NSApp.windows where window.canBecomeMain { window.delegate = self; window.title = "acdian"; window.backgroundColor = NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .aqua ? .white : NSColor(red:0.065,green:0.065,blue:0.078,alpha:1) }; window.isMovableByWindowBackground = true; window.tabbingMode = .disallowed } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        guard let model else { return true }
        guard !closePending, !terminationPending else { return false }
        closePending = true
        DispatchQueue.main.async { [weak self, weak sender] in
            guard let self else { return }
            model.withEditorSnapshot({
                self.closePending = false
                guard let sender, model.saveBeforeLeaving() else { return }
                self.lastWindowCloseApproved = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count <= 1
                self.closeApproved = true; sender.performClose(nil); self.closeApproved = false
            },onFailure:{ self.closePending = false })
        }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if lastWindowCloseApproved { lastWindowCloseApproved = false; return .terminateNow }
        guard let model else { return .terminateNow }
        guard !terminationPending, !closePending else { return .terminateCancel }
        terminationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { NSApp.reply(toApplicationShouldTerminate:false); return }
            model.withEditorSnapshot({
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate:model.saveBeforeLeaving())
            },onFailure:{
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate:false)
            })
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
