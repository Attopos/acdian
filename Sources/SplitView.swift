import SwiftUI
import WebKit
import PDFKit

/// The tab row above the split page: the page as a single tab that closes
/// the split, and a button that swaps the two columns.
struct SplitTabBar: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    var atWindowEdge = false
    @State private var hovering = false
    var body: some View {
        GeometryReader { geometry in
            let leading: CGFloat = model.showSidebar || !atWindowEdge ? 10 : 78
            HStack(spacing:2) {
                HStack(spacing:2) {
                    Text(AppModel.editableName(entry)).font(.system(size:12)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    Button { model.closeSplit() } label: { Image(systemName:"xmark").font(.system(size:8,weight:.bold)).frame(width:16,height:16).contentShape(Rectangle()) }
                        .buttonStyle(.plain).opacity(model.splitFocused || hovering ? 1 : 0)
                        .help(model.localized("关闭分屏")).accessibilityLabel(model.localized("关闭分屏"))
                }
                .foregroundStyle(Color.primary)
                .padding(.leading,10).padding(.trailing,4).frame(width:min(200,max(36,geometry.size.width - leading - 44)),height:24)
                .background(model.splitFocused ? Color.wash : .clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
                .onTapGesture { model.splitFocused = true }
                .onHover { hovering = $0 }
                .help(entry.relativePath)
                Spacer(minLength:0)
                Button { model.swapSplitSides() } label: { Image(systemName:"arrow.left.arrow.right").font(.system(size:11)).frame(width:24,height:22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(model.localized("左右互换")).accessibilityLabel(model.localized("左右互换"))
            }.padding(.leading,leading).padding(.trailing,8).padding(.top,4).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }.contentShape(Rectangle()).clipped()
    }
}

/// The page shown beside the open one: a Markdown page in its own editor,
/// anything else shown straight from its file.
struct SplitPane: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    var body: some View { content.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas) }
    @ViewBuilder private var content: some View {
        if model.splitLoading { ProgressView().controlSize(.small) }
        else if entry.ext == "md" { SplitMarkdownEditor(model:model) }
        else if entry.ext == ComponentStore.fileExtension { ComponentPage(file:entry).id(entry.id) }
        else if entry.ext == "pdf" { SplitPDFView(url:entry.url).id(entry.id) }
        else if AppModel.images.contains(entry.ext) { ImagePane(url:entry.url).id(entry.id) }
        else if AppModel.videos.contains(entry.ext) { VideoPane(url:entry.url).id(entry.id) }
        else if AppModel.textExtensions.contains(entry.ext) { ScrollView { Text(model.splitText).font(.system(size:13,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(28) } }
        else {
            VStack(spacing:14) {
                Image(systemName:"doc").font(.system(size:40,weight:.ultraLight)).foregroundStyle(Color.acPink)
                Text(model.localized("此类文件可在系统默认应用中打开。")).foregroundStyle(.secondary)
                Button(model.localized("打开文件")) { NSWorkspace.shared.open(entry.url) }.buttonStyle(.bordered)
            }
        }
    }
}

/// The line between the two columns. Dragging it moves the split; a double
/// click puts it back in the middle.
struct SplitDivider: View {
    @EnvironmentObject var model: AppModel
    let width: CGFloat
    let leftWidth: CGFloat
    @State private var start: CGFloat?
    var body: some View {
        Rectangle().fill(Color.faint).frame(width:1).frame(maxHeight:.infinity)
            .frame(width:9).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global)
                .onChanged { drag in
                    let origin = start ?? leftWidth; start = origin
                    if width > 0 { model.splitFraction = min(max((origin + drag.translation.width) / width,0.2),0.8) }
                }
                .onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count:2).onEnded { model.splitFraction = 0.5 })
    }
}

/// Reports a click anywhere in the view it sits behind, without taking the
/// click from what is in front, so a column knows it is the one in use.
struct PaneClickWatcher: NSViewRepresentable {
    let onClick: () -> Void
    func makeNSView(context: Context) -> WatcherView { let view = WatcherView(); view.onClick = onClick; return view }
    func updateNSView(_ view: WatcherView, context: Context) { view.onClick = onClick }
    static func dismantleNSView(_ view: WatcherView, coordinator: ()) { view.stop() }
    final class WatcherView: NSView {
        var onClick: () -> Void = {}
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
                if let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow,from:nil)) { self.onClick() }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

struct SplitPDFView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = NSColor(calibratedWhite:0.09,alpha:1)
        view.document = PDFDocument(url:url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}

struct SplitMarkdownEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        SplitEditorHost.shared.attach(to:container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        let host = SplitEditorHost.shared
        host.model = model; host.appearance = colorScheme == .light ? "light" : "dark"
        // Only a container on screen takes the editor, so one being torn down never takes it back.
        if container.window != nil, host.view.superview?.window == nil { host.attach(to:container) }
        host.render()
    }
    static func dismantleNSView(_ container: NSView, coordinator: ()) { SplitEditorHost.shared.detach(from:container) }
}

/// A second copy of the live editor for the split page. It keeps no tabs: the
/// model holds the page's text, and each page sent to it carries the model's
/// splitDocumentID, which its messages echo back.
@MainActor final class SplitEditorHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = SplitEditorHost()
    let view: WKWebView
    weak var model: AppModel?
    var appearance = "dark"
    private var ready = false
    private var installed: UUID?
    private var lastConfig = ""
    private var latestRevision = -1
    private var pendingAnchor: String?
    private override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SchemeRelay(),forURLScheme:"acdian-resource")
        view = WKWebView(frame:NSRect(x:0,y:0,width:600,height:700),configuration:config)
        super.init()
        config.userContentController.add(MessageRelay(self),name:"acdian")
        view.setValue(false,forKey:"drawsBackground")
        view.navigationDelegate = self
        view.isInspectable = false
        view.autoresizingMask = [.width,.height]
        load()
    }
    private func load() {
        ready = false; installed = nil; lastConfig = ""
        if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
    }
    func attach(to container: NSView) {
        guard view.superview !== container else { return }
        view.frame = container.bounds; container.addSubview(view)
    }
    func detach(from container: NSView) { if view.superview === container { view.removeFromSuperview() } }
    func render() {
        guard ready, let model, let entry = model.splitEntry, entry.ext == "md", !model.splitLoading else { return }
        let id = model.splitDocumentID
        var payload: [String:Any] = ["currentPath":entry.relativePath,"documentID":id.uuidString,"tabID":"split","openTabs":["split"],"title":entry.name,"draft":true,"fontSize":model.fontSize,
                                     "editable":true,"language":model.language.rawValue,"appearance":appearance,"pageTitle":entry.url.deletingPathExtension().lastPathComponent]
        let newDocument = installed != id
        if newDocument { payload["text"] = model.splitText }
        guard let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8), newDocument || json != lastConfig else { return }
        if newDocument { latestRevision = -1 }
        installed = id; lastConfig = json
        view.evaluateJavaScript("window.acdianSetDocument(\(json));") { [weak self] _,error in
            guard let self else { return }
            if error != nil { if self.installed == id { self.installed = nil; self.lastConfig = "" }; return }
            if let anchor = self.pendingAnchor { self.pendingAnchor = nil; self.scroll(to:anchor) }
        }
    }
    private func scroll(to anchor: String) {
        guard let data = try? JSONSerialization.data(withJSONObject:[anchor]), let json = String(data:data,encoding:.utf8) else { return }
        view.evaluateJavaScript("window.acdianScrollTo(\(json)[0]);",completionHandler:nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; installed = nil; render(); return }
        // The document ID alone names the page: it survives the page being renamed.
        guard let model, let id = installed, id == model.splitDocumentID, value["documentID"] as? String == id.uuidString else { return }
        if type == "change", var text = value["text"] as? String {
            let revision = value["revision"] as? Int ?? latestRevision
            guard revision >= latestRevision else { return }
            latestRevision = revision
            text.makeContiguousUTF8()
            model.splitEdited(text,documentID:id)
        }
        if type == "external", let target = value["target"] as? String { model.external(target) }
        // Links followed in the split page open there too.
        if type == "navigate", let target = value["target"] as? String {
            if target.hasPrefix("#") { scroll(to:String(target.dropFirst())); return }
            guard let index = model.index, let url = index.resolve(target,from:model.splitPath ?? ""),
                  let entry = index.files.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else {
                model.error = model.localized("找不到链接的文件：%@\n请检查文件路径；同名文件请使用完整路径。",target); return
            }
            let fragment = target.components(separatedBy:"#").dropFirst().joined(separator:"#")
            if entry.relativePath == model.currentPagePath { if !fragment.isEmpty { model.anchor = fragment.removingPercentEncoding ?? fragment }; return }
            pendingAnchor = fragment.isEmpty ? nil : fragment.removingPercentEncoding ?? fragment
            if entry.relativePath == model.splitPath { if let anchor = pendingAnchor { pendingAnchor = nil; scroll(to:anchor) } }
            else { model.openInSplit(entry) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); return }
        if url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }
    // Attachments and interactive frames are served by the main editor's host,
    // which resolves them against the same vault.
    private final class SchemeRelay: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,start:task) } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,stop:task) } }
    }
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var host: SplitEditorHost?
        init(_ host: SplitEditorHost) { self.host = host }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { host?.userContentController(controller,didReceive:message) }
    }
}
