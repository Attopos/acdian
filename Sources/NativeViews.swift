import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers

/// Shows the one editor web view. Switching pages swaps the document inside it
/// instead of loading a new web page, so a page appears without a blank frame.
struct LiveMarkdownEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        LiveEditorHost.shared.attach(to:container)
        return container
    }
    func updateNSView(_ container: NSView,context: Context) {
        let host = LiveEditorHost.shared
        host.model = model; host.appearance = colorScheme == .light ? "light" : "dark"
        host.attach(to:container); host.render()
    }
    static func dismantleNSView(_ container: NSView,coordinator: ()) { LiveEditorHost.shared.detach(from:container) }
}

/// The editor web view lives for the whole session. It is created and loaded at
/// launch, and each tab's editor state is kept inside it while the tab is in the
/// back. Every document sent to it carries the model's editorDocumentID, which
/// the page echoes in its messages, so nothing from a page that has since been
/// swapped out can reach the model.
@MainActor final class LiveEditorHost: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
    static let shared = LiveEditorHost()
    let view: EditorWebView
    weak var model: AppModel? { didSet { if model !== oldValue { attachBridge() } } }
    var appearance = "dark"
    private var ready = false
    // The document the page was last sent, and the per-document bridge state.
    private var documentID: UUID?
    private var documentPath = ""
    private var renamedFrom: String?
    private var documentInstalled = false
    private var focusPending = false
    private var initialSelection: (anchor:Int,head:Int)?
    private var lastJSText: String?
    private var latestJSRevision = -1
    private var syncFailures = 0
    private var syncBlocked = false
    private var lastConfig = ""
    private var lastAnchorRequest = 0
    private var pendingInsertion: UUID?
    private var activeTasks = Set<ObjectIdentifier>()
    private override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let schemes = ResourceSchemeRelay()
        config.setURLSchemeHandler(schemes,forURLScheme:"acdian-resource")
        view = EditorWebView(frame:NSRect(x:0,y:0,width:900,height:700),configuration:config)
        super.init()
        schemes.host = self; view.host = self
        config.userContentController.add(MessageRelay(self),name:"acdian")
        view.setValue(false,forKey:"drawsBackground")
        view.navigationDelegate = self
        view.isInspectable = false
        view.autoresizingMask = [.width,.height]
        load()
    }
    private func load() {
        ready = false; documentID = nil; documentInstalled = false
        if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
    }
    func attach(to container: NSView) {
        guard view.superview !== container else { return }
        view.frame = container.bounds; container.addSubview(view)
    }
    func detach(from container: NSView) { if view.superview === container { view.removeFromSuperview() } }
    /// True while the page holds the document the model has open.
    var isCurrent: Bool { guard let model, let documentID else { return false }; return model.editorDocumentID == documentID && model.selected?.relativePath == documentPath }
    private func attachBridge() {
        guard let model else { return }
        model.editorFocus = { [weak self] in
            guard let self, self.isCurrent else { return }
            self.focusPending = true
            self.focusEditorIfReady()
        }
        model.editorSnapshot = { [weak self, weak model] completion in
            guard let self, let model, model.selected?.ext == "md" else { completion(.failure(URLError(.cancelled))); return }
            // Until the page has the open document, the model's text is the latest.
            guard self.ready, self.documentInstalled, self.isCurrent, let expected = self.documentID else {
                completion(.success(EditorSnapshot(text:model.text,currentPath:model.selected?.relativePath ?? ""))); return
            }
            self.view.evaluateJavaScript("window.acdianGetDocument()") { result,error in
                guard self.isCurrent, self.documentID == expected else { completion(.failure(URLError(.cancelled))); return }
                if let error { completion(.failure(error)); return }
                guard let result = result as? [String:Any], var text = result["text"] as? String, let path = result["currentPath"] as? String, path == self.documentPath || path == self.renamedFrom,
                      result["documentID"] as? String == expected.uuidString else { completion(.failure(URLError(.cannotParseResponse))); return }
                text.makeContiguousUTF8()
                let revision = result["revision"] as? Int ?? self.latestJSRevision
                // Getter completion and change messages cross independent IPC
                // paths; never replace a newer accepted change with an old read.
                let newest = revision < self.latestJSRevision ? (self.lastJSText ?? text) : text
                self.latestJSRevision = max(self.latestJSRevision,revision)
                self.lastJSText = newest
                let selection = revision < self.latestJSRevision ? model.editorSelection : nil
                completion(.success(EditorSnapshot(text:newest,currentPath:self.documentPath,selectionAnchor:selection?.anchor ?? result["selectionAnchor"] as? Int,selectionHead:selection?.head ?? result["selectionHead"] as? Int,
                                                   scrollPosition:result["scrollPosition"] as? Int,scrollOffset:(result["scrollOffset"] as? NSNumber)?.doubleValue)))
            }
        }
    }
    /// Starts bridging the document the model now has open.
    private func beginDocument(_ model: AppModel) {
        documentID = model.editorDocumentID; documentPath = model.selected?.relativePath ?? ""; renamedFrom = nil
        documentInstalled = false; lastJSText = nil; latestJSRevision = -1
        syncFailures = 0; syncBlocked = false; lastConfig = ""
        initialSelection = model.pendingEditorSelection; focusPending = initialSelection != nil
        model.pendingEditorSelection = nil
    }
    func focusEditorIfReady() {
        guard focusPending, ready, documentInstalled, isCurrent else { return }
        focusPending = false
        view.window?.makeFirstResponder(view)
        var script = "window.acdianEditor.focus();"
        if let selection = initialSelection {
            script = "window.acdianEditor.dispatch({selection:{anchor:Math.min(\(selection.anchor),window.acdianEditor.state.doc.length),head:Math.min(\(selection.head),window.acdianEditor.state.doc.length)},scrollIntoView:true});" + script
            initialSelection = nil
        }
        view.evaluateJavaScript(script,completionHandler:nil)
    }
    func render() {
        guard ready, let model, model.selected?.ext == "md" else { return }
        if model.editorDocumentID != documentID { beginDocument(model) }
        // A page renamed after its title changed stays in the editor at its new path.
        else if let path = model.selected?.relativePath, path != documentPath { renamedFrom = documentPath; documentPath = path }
        guard !syncBlocked, let documentID else { return }
        // Every Markdown page shows its title natively above the editor, so the
        // editor always uses the compact spacing below a title.
        var payload: [String:Any] = ["currentPath":documentPath,"documentID":documentID.uuidString,"tabID":model.activeTabID?.uuidString ?? "","openTabs":model.tabs.map(\.id.uuidString),
                                     "title":model.isDraft ? model.draftTitle : model.selected?.name ?? "","draft":true,"fontSize":model.fontSize,"editable":!model.loading,"language":model.language.rawValue,"appearance":appearance,"pageTitle":model.isDraft ? "" : (model.selected?.url.deletingPathExtension().lastPathComponent ?? "")]
        let sendText = !documentInstalled || lastJSText.map { !model.text.sameBytes($0) } ?? true
        if sendText {
            payload["text"] = model.text
            if let place = model.frontTabView { payload["view"] = ["anchor":place.anchor,"head":place.head,"scroll":["pos":place.scrollPosition,"offset":place.scrollOffset]] }
        }
        if let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8), sendText || json != lastConfig {
            let textSent = payload["text"] as? String
            // Record the scheduled source, so unrelated SwiftUI changes never
            // enqueue an old document over a keystroke still crossing IPC.
            if let textSent { lastJSText = textSent }
            documentInstalled = true; lastConfig = json
            view.evaluateJavaScript("window.acdianSetDocument(\(json));") { [weak self] _,error in
                guard let self, self.isCurrent, self.documentID == documentID else { return }
                if let error {
                    self.lastConfig = ""
                    if textSent != nil { self.documentInstalled = false; self.lastJSText = nil }
                    self.syncFailures += 1
                    if self.syncFailures < 3 { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { if self.isCurrent { self.render() } } }
                    else { self.syncBlocked = true; self.model?.error = self.model?.localized("编辑器加载失败，请重新载入文件。\n%@",error.localizedDescription) }
                    return
                }
                self.syncFailures = 0
                self.scroll(); self.insertPendingAttachment(); self.focusEditorIfReady()
            }
        } else { scroll(); insertPendingAttachment(); focusEditorIfReady() }
    }
    func scroll() {
        guard let model, !model.anchor.isEmpty, model.anchorRequest != lastAnchorRequest, let data = try? JSONSerialization.data(withJSONObject:[model.anchor]), let json = String(data:data,encoding:.utf8) else { return }
        let request = model.anchorRequest
        view.evaluateJavaScript("window.acdianScrollTo(\(json)[0]);") { [weak self] _,error in if error == nil { self?.lastAnchorRequest = request } }
    }
    func insertPendingAttachment() {
        guard isCurrent, ready, let model, !model.loading, let insertion = model.insertion, pendingInsertion != insertion.id,
              let data = try? JSONSerialization.data(withJSONObject:[insertion.text,insertion.id.uuidString,insertion.block]), let json = String(data:data,encoding:.utf8) else { return }
        pendingInsertion = insertion.id
        view.evaluateJavaScript("window.acdianInsertText(\(json)[0], \(json)[1], \(json)[2]);") { [weak self] result,error in
            guard let self, self.isCurrent, let model = self.model else { return }
            if let error { self.pendingInsertion = nil; model.error = model.localized("附件链接插入失败：%@",error.localizedDescription); return }
            if let accepted = result as? Bool, !accepted { self.pendingInsertion = nil; return }
            if model.insertion?.id == insertion.id { model.insertion = nil }
        }
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; render(); return }
        guard isCurrent, let model, let documentID, value["documentID"] as? String == documentID.uuidString else { return }
        let path = value["currentPath"] as? String ?? value["from"] as? String
        // Messages sent before the page heard of a rename still name the old path.
        guard path == documentPath || (path != nil && path == renamedFrom) else { return }
        if type == "change", var text = value["text"] as? String {
            text.makeContiguousUTF8() // compared and kept natively from here on
            let revision = value["revision"] as? Int ?? latestJSRevision
            guard revision >= latestJSRevision else { return }
            latestJSRevision = revision; lastJSText = text
            if let anchor = value["selectionAnchor"] as? Int, let head = value["selectionHead"] as? Int { model.editorSelection = (anchor,head) }
            if !model.text.sameBytes(text) { model.text = text }
        }
        if type == "save", let text = value["text"] as? String {
            lastJSText = text; model.text = text
            if let anchor = value["selectionAnchor"] as? Int, let head = value["selectionHead"] as? Int { model.editorSelection = (anchor,head) }
            model.save()
        }
        if type == "heading", let index = value["index"] as? Int, model.activeHeading != index { model.activeHeading = index }
        if type == "navigate", let target = value["target"] as? String { model.navigate(target) }
        if type == "external", let target = value["target"] as? String { model.external(target) }
        if type == "renameTitle", let title = value["title"] as? String, !model.renameFromTitle(documentPath,to:title) { view.evaluateJavaScript("window.acdianRefreshTitle()",completionHandler:nil) }
        if type == "paste" { pasteAttachments() }
        if type == "pickImage" { model.importAttachment(imagesOnly:true) }
    }
    /// The page saw a paste that carries files: files copied in Finder become
    /// attachments, and so does a picture copied on its own. Anything else is
    /// pasted as its plain text, as the editor would have pasted it.
    private func pasteAttachments() {
        guard let model else { return }
        let pasteboard = NSPasteboard.general
        let files = AttachmentPasteboard.fileURLs(pasteboard)
        if !files.isEmpty { model.insertAttachments(files) }
        else if let image = AttachmentPasteboard.image(pasteboard) { model.insertImage(image.data,ext:image.ext) }
        else if let text = pasteboard.string(forType:.string) { model.insertText(text) }
    }
    /// Shows where a drop will land by moving the caret under the pointer.
    func placeDropCaret(at point: NSPoint) {
        guard isCurrent, ready else { return }
        view.evaluateJavaScript("window.acdianDropCaret(\(Double(point.x)),\(Double(point.y)));",completionHandler:nil)
    }
    /// Links what was dropped from another app at the caret: files as they are,
    /// files promised by apps such as Photos once they are written, or a picture.
    func dropAttachments(_ info: NSDraggingInfo) -> Bool {
        guard isCurrent, let model, model.acceptsAttachments else { return false }
        let pasteboard = info.draggingPasteboard
        let files = AttachmentPasteboard.fileURLs(pasteboard)
        if !files.isEmpty { return model.insertAttachments(files) }
        if let receivers = pasteboard.readObjects(forClasses:[NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acdian-drop-\(UUID().uuidString)",isDirectory:true)
            guard (try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)) != nil else { return false }
            let documentID = documentID, expected = receivers.reduce(0) { $0 + max(1,$1.fileNames.count) }
            var received: [URL] = [], answered = 0
            let queue = OperationQueue(); queue.qualityOfService = .userInitiated
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination:folder,options:[:],operationQueue:queue) { url,error in
                    DispatchQueue.main.async {
                        if error == nil { received.append(url) }
                        answered += 1
                        guard answered == expected else { return }
                        if self.isCurrent, self.documentID == documentID, !received.isEmpty { model.insertAttachments(received) }
                        try? FileManager.default.removeItem(at:folder)
                    }
                }
            }
            return true
        }
        if let image = AttachmentPasteboard.image(pasteboard) { return model.insertImage(image.data,ext:image.ext) }
        return false
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); return }
        if url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }
    /// A crashed web content process comes back with the open page from the model.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }
    func webView(_ webView: WKWebView,start urlSchemeTask: WKURLSchemeTask) {
        guard let request = urlSchemeTask.request.url,
              let components = URLComponents(url:request,resolvingAgainstBaseURL:false) else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
        let path = String(components.percentEncodedPath.dropFirst())
        if components.host == "interactive" { serveInteractive(urlSchemeTask,request:request,path:path); return }
        guard let index = model?.index else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
        let from = components.queryItems?.first(where: {$0.name == "from"})?.value ?? ""
        guard let url = index.resolve(path,from:from) else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject); activeTasks.insert(taskID)
        // The task is only used back on the main thread, after the file is read.
        let pending = PendingTask(task:urlSchemeTask)
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try Data(contentsOf:url) }
            DispatchQueue.main.async {
                let urlSchemeTask = pending.task
                guard self.activeTasks.remove(taskID) != nil else { return }
                switch result {
                case .success(let data):
                    let mime = UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    let response = URLResponse(url:request,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil)
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                case .failure(let error): urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }
    func webView(_ webView: WKWebView,stop urlSchemeTask: WKURLSchemeTask) { activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject)) }
    /// The policy of every interactive frame: inline scripts and the bundled
    /// libraries run, nothing reaches the network, and no other frame opens.
    static let interactivePolicy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' acdian-resource://interactive; style-src 'unsafe-inline' acdian-resource://interactive; img-src data: blob: acdian-resource://interactive; font-src data: acdian-resource://interactive; media-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'"
    /// Serves the interactive frame from Resources/interactive and its libraries,
    /// under lib/, from Resources/vendor. Nothing outside those folders is served.
    private func serveInteractive(_ task: WKURLSchemeTask,request: URL,path: String) {
        let parts = (path.removingPercentEncoding ?? "").split(separator:"/").map(String.init)
        guard let resources = Bundle.main.resourceURL, !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { task.didFailWithError(URLError(.badURL)); return }
        let library = parts[0] == "lib"
        let rest = library ? Array(parts.dropFirst()) : parts
        let url = rest.reduce(resources.appendingPathComponent(library ? "vendor" : "interactive",isDirectory:true)) { $0.appendingPathComponent($1) }
        guard !rest.isEmpty, let data = try? Data(contentsOf:url) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        var mime = UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if ["html","js","css"].contains(url.pathExtension) { mime += "; charset=utf-8" }
        // Fonts are fetched with CORS from the frame's opaque origin.
        let headers = ["Content-Type":mime,"Content-Security-Policy":Self.interactivePolicy,"Access-Control-Allow-Origin":"*","Cache-Control":"no-store"]
        guard let response = HTTPURLResponse(url:request,statusCode:200,httpVersion:"HTTP/1.1",headerFields:headers) else { task.didFailWithError(URLError(.badServerResponse)); return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    private struct PendingTask: @unchecked Sendable { let task: WKURLSchemeTask }
    // WebKit keeps its message and scheme handlers strongly; these relays keep
    // only a weak reference back, so the configuration never owns the host.
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var host: LiveEditorHost?
        init(_ host: LiveEditorHost) { self.host = host }
        func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) { host?.userContentController(controller,didReceive:message) }
    }
    private final class ResourceSchemeRelay: NSObject, WKURLSchemeHandler {
        weak var host: LiveEditorHost?
        func webView(_ webView: WKWebView,start task: WKURLSchemeTask) { if let host { host.webView(webView,start:task) } else { task.didFailWithError(URLError(.cancelled)) } }
        func webView(_ webView: WKWebView,stop task: WKURLSchemeTask) { host?.webView(webView,stop:task) }
    }
}

/// The editor's web view. Files and pictures dragged in from other apps are
/// taken here, because WebKit would otherwise open a dropped file in place of
/// the editor or insert only its name. Drags that start inside ACdian, such as
/// moving text, still go to the page.
final class EditorWebView: WKWebView {
    weak var host: LiveEditorHost?
    private var takesDrop = false
    private var lastDropPoint: NSPoint?
    override init(frame: NSRect,configuration: WKWebViewConfiguration) {
        super.init(frame:frame,configuration:configuration)
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + AttachmentPasteboard.dragTypes)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func pagePoint(_ info: NSDraggingInfo) -> NSPoint {
        let point = convert(info.draggingLocation,from:nil)
        return isFlipped ? point : NSPoint(x:point.x,y:bounds.height-point.y)
    }
    private func follow(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = pagePoint(info)
        if point != lastDropPoint { lastDropPoint = point; host?.placeDropCaret(at:point) }
        return .copy
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        takesDrop = info.draggingSource == nil && host?.isCurrent == true && host?.model?.acceptsAttachments == true && AttachmentPasteboard.offersAttachments(info.draggingPasteboard)
        guard takesDrop else { return super.draggingEntered(info) }
        lastDropPoint = nil; window?.makeFirstResponder(self)
        return follow(info)
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { takesDrop ? follow(info) : super.draggingUpdated(info) }
    override func draggingExited(_ info: NSDraggingInfo?) { if !takesDrop { super.draggingExited(info) } }
    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { takesDrop || super.prepareForDragOperation(info) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool { takesDrop ? host?.dropAttachments(info) ?? false : super.performDragOperation(info) }
    override func concludeDragOperation(_ info: NSDraggingInfo?) { if !takesDrop { super.concludeDragOperation(info) } }
}

struct PDFPane: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = NSColor(calibratedWhite:0.09,alpha:1)
        context.coordinator.view = view; context.coordinator.model = model
        NotificationCenter.default.addObserver(context.coordinator,selector:#selector(Coordinator.pageChanged),name: .PDFViewPageChanged,object:view)
        return view
    }
    func updateNSView(_ view: PDFView,context: Context) {
        let c = context.coordinator
        if c.url != url {
            c.url = url; view.document = PDFDocument(url:url); view.autoScales = true
            DispatchQueue.main.async { model.pdfPageCount = view.document?.pageCount ?? 0; if view.document == nil { model.error = model.localized("无法读取 PDF，文件可能已损坏或受密码保护。") } }
        }
        if let document = view.document, model.pdfPage > 0, model.pdfPage <= document.pageCount, let page = document.page(at:model.pdfPage-1), page != view.currentPage { view.go(to:page) }
        if c.lastZoom != model.pdfZoomAction {
            let diff = model.pdfZoomAction - c.lastZoom
            if diff > 0 { view.zoomIn(nil) } else { view.zoomOut(nil) }
            c.lastZoom = model.pdfZoomAction
        }
    }
    final class Coordinator: NSObject {
        var url: URL?; weak var view: PDFView?; weak var model: AppModel?; var lastZoom = 0
        @objc func pageChanged() { guard let view, let page = view.currentPage, let doc = view.document else { return }; let n = doc.index(for:page)+1; DispatchQueue.main.async { self.model?.pdfPage = n; self.model?.pdfPageCount = doc.pageCount } }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct ImagePane: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing:0) {
            HStack { Spacer(); Button { zoom = max(0.2,zoom-0.25) } label: { Image(systemName:"minus.magnifyingglass") }; Text("\(Int(zoom*100))%").font(.caption.monospacedDigit()).frame(width:48); Button { zoom = min(4,zoom+0.25) } label:{ Image(systemName:"plus.magnifyingglass") }; Button(model.localized("适应窗口")) { zoom = 1 }; Spacer() }.buttonStyle(.borderless).padding(12)
            if let image = NSImage(contentsOf:url) {
                GeometryReader { geometry in
                    ScrollView([.horizontal,.vertical]) {
                        Image(nsImage:image).resizable().scaledToFit().frame(width:max(200,geometry.size.width-80)*zoom,height:max(180,geometry.size.height-60)*zoom).padding(30).frame(minWidth:geometry.size.width,minHeight:geometry.size.height)
                    }
                }
            } else { ContentUnavailableView(model.localized("无法预览图片"),systemImage:"photo",description:Text(model.localized("文件格式可能不受当前 macOS 支持。"))) }
        }.background(Color.canvas)
    }
}
