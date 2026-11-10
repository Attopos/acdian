import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// The iPad's editor: the same web editor the Mac uses, with `editable` on. It
/// lives for the whole session, and each page swaps the document inside it.
@MainActor final class EditorHost: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate, ObservableObject {
    static let shared = EditorHost()
    let view: WKWebView
    weak var model: AppModel? { didSet { if model !== oldValue { attachBridge() } } }
    var appearance = "dark"
    @Published private(set) var focused = false
    private var ready = false
    private var documentID: UUID?
    private var documentPath = ""
    private var installed = false
    private var lastSent: String?
    private var lastRevision = -1
    private var lastConfig = ""
    private var lastAnchor = 0
    private var pendingInsertion: UUID?
    private var tasks = Set<ObjectIdentifier>()

    private override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let schemes = SchemeRelay()
        config.setURLSchemeHandler(schemes,forURLScheme:"acdian-resource")
        // The flag is set before the editor's own script runs; the Mac never sets it.
        config.userContentController.addUserScript(WKUserScript(source:"window.acdianTouch=true;",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        config.userContentController.addUserScript(WKUserScript(source:ReaderWebView.touchBasics,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        view = WKWebView(frame:.zero,configuration:config)
        super.init()
        schemes.host = self
        config.userContentController.add(MessageRelay(self),name:"acdian")
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsLinkPreview = false
        view.navigationDelegate = self
        load()
    }
    private func load() {
        ready = false; documentID = nil; installed = false; lastSent = nil; lastConfig = ""
        if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
    }
    private var isCurrent: Bool { guard let model, let documentID else { return false }; return model.editorDocumentID == documentID && model.selected?.relativePath == documentPath }
    private func attachBridge() {
        guard let model else { return }
        model.editorFocus = { [weak self] in self?.view.evaluateJavaScript("window.acdianEditor.focus();",completionHandler:nil) }
        model.editorSnapshot = { [weak self, weak model] completion in
            guard let self, let model, model.selected?.ext == "md" else { completion(.failure(URLError(.cancelled))); return }
            guard self.ready, self.installed, self.isCurrent, let expected = self.documentID else {
                completion(.success(EditorSnapshot(text:model.text,currentPath:model.selected?.relativePath ?? ""))); return
            }
            self.view.evaluateJavaScript("window.acdianGetDocument()") { result,error in
                guard self.isCurrent, self.documentID == expected else { completion(.failure(URLError(.cancelled))); return }
                if let error { completion(.failure(error)); return }
                guard let result = result as? [String:Any], let text = result["text"] as? String, result["documentID"] as? String == expected.uuidString else { completion(.failure(URLError(.cannotParseResponse))); return }
                self.lastSent = text
                completion(.success(EditorSnapshot(text:text,currentPath:self.documentPath,selectionAnchor:result["selectionAnchor"] as? Int,selectionHead:result["selectionHead"] as? Int,scrollPosition:result["scrollPosition"] as? Int,scrollOffset:(result["scrollOffset"] as? NSNumber)?.doubleValue)))
            }
        }
    }
    func render() {
        guard ready, let model, model.selected?.ext == "md" else { return }
        if model.editorDocumentID != documentID {
            documentID = model.editorDocumentID; documentPath = model.selected?.relativePath ?? ""
            installed = false; lastSent = nil; lastRevision = -1; lastConfig = ""
        } else if let path = model.selected?.relativePath, path != documentPath { documentPath = path }
        guard let documentID else { return }
        var payload: [String:Any] = ["currentPath":documentPath,"documentID":documentID.uuidString,"tabID":model.activeTabID?.uuidString ?? "","openTabs":model.tabs.map(\.id.uuidString),
                                     "title":model.isDraft ? model.draftTitle : model.selected?.name ?? "","draft":true,"fontSize":model.fontSize,"editable":!model.loading,"language":model.language.rawValue,"appearance":appearance,
                                     "pageTitle":model.isDraft ? "" : (model.selected?.url.deletingPathExtension().lastPathComponent ?? "")]
        let sendText = !installed || lastSent.map { !model.text.sameBytes($0) } ?? true
        if model.refreshPending { model.refreshPending = false; if sendText && installed { payload["refresh"] = ["base":lastSent ?? ""] } }
        if sendText {
            payload["text"] = model.text
            if payload["refresh"] == nil, let root = model.index?.root { payload["comments"] = PageComments.read(page:documentPath,root:root) ?? "" }
            if let place = model.frontTabView { payload["view"] = ["anchor":place.anchor,"head":place.head,"scroll":["pos":place.scrollPosition,"offset":place.scrollOffset]] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8), sendText || json != lastConfig else { afterRender(); return }
        if sendText { lastSent = model.text }
        installed = true; lastConfig = json
        view.evaluateJavaScript("window.acdianSetDocument(\(json));") { [weak self] _,error in
            guard let self, self.isCurrent, self.documentID == documentID else { return }
            if error != nil { self.lastConfig = ""; if sendText { self.installed = false; self.lastSent = nil }; return }
            self.afterRender()
        }
    }
    private func afterRender() {
        guard let model else { return }
        if !model.anchor.isEmpty, model.anchorRequest != lastAnchor, let data = try? JSONSerialization.data(withJSONObject:[model.anchor]), let json = String(data:data,encoding:.utf8) {
            lastAnchor = model.anchorRequest
            view.evaluateJavaScript("window.acdianScrollTo(\(json)[0]);",completionHandler:nil)
        }
        if isCurrent, !model.loading, let insertion = model.insertion, pendingInsertion != insertion.id, let data = try? JSONSerialization.data(withJSONObject:[insertion.text,insertion.id.uuidString,insertion.block]), let json = String(data:data,encoding:.utf8) {
            pendingInsertion = insertion.id
            view.evaluateJavaScript("window.acdianInsertText(\(json)[0], \(json)[1], \(json)[2]);") { [weak self] result,error in
                guard let self, let model = self.model else { return }
                if error != nil || (result as? Bool) == false { self.pendingInsertion = nil; return }
                if model.insertion?.id == insertion.id { model.insertion = nil }
            }
        }
    }
    /// A formatting button above the keyboard, or undo/redo.
    func format(_ action: String) { view.evaluateJavaScript("window.acdianFormat&&window.acdianFormat('\(action)');",completionHandler:nil) }
    func dismissKeyboard() { view.evaluateJavaScript("document.activeElement&&document.activeElement.blur();",completionHandler:nil) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; render(); return }
        if type == "focus" { focused = value["focused"] as? Bool ?? false; return }
        if type == "comments" { model?.storeComments(value["data"] as? String,page:value["currentPath"] as? String); return }
        guard isCurrent, let model, let documentID, value["documentID"] as? String == documentID.uuidString else { return }
        if type == "change", let text = value["text"] as? String {
            let revision = value["revision"] as? Int ?? lastRevision
            guard revision >= lastRevision else { return }
            lastRevision = revision; lastSent = text
            if let anchor = value["selectionAnchor"] as? Int, let head = value["selectionHead"] as? Int { model.editorSelection = (anchor,head) }
            if !model.text.sameBytes(text) { model.text = text }
        }
        if type == "save", let text = value["text"] as? String { lastSent = text; model.text = text; model.save() }
        if type == "navigate", let target = value["target"] as? String { model.navigate(target) }
        if type == "external", let target = value["target"] as? String { model.external(target) }
        if type == "copyImage", let target = value["target"] as? String { model.copyImage(target,from:documentPath) }
        if type == "copy", let text = value["text"] as? String { UIPasteboard.general.string = text }
        if type == "titleTyped", let title = value["title"] as? String { model.titleTyped(title) }
        if type == "titleEnded", !model.titleEditEnded() { view.evaluateJavaScript("window.acdianRefreshTitle()",completionHandler:nil) }
        if type == "paste" {
            if let image = UIPasteboard.general.image, let png = image.pngData() { model.insertImage(png,ext:"png") }
            else if let text = UIPasteboard.general.string { model.insertText(text) }
        }
        if type == "pickImage" { model.importAttachment(imagesOnly:true) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType != .linkActivated else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" ? .allow : .cancel)
    }
    /// WebKit killed the page's process: load it again and restore the document
    /// from the model, which keeps the text of every edit it has received.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url, let components = URLComponents(url:request,resolvingAgainstBaseURL:false) else { task.didFailWithError(URLError(.badURL)); return }
        let path = String(components.percentEncodedPath.dropFirst())
        if components.host == "interactive" { ReaderWebView.serveInteractive(task,request:request,path:path); return }
        let from = components.queryItems?.first { $0.name == "from" }?.value ?? ""
        guard let url = model?.index?.resolve(path,from:from) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let id = ObjectIdentifier(task as AnyObject); tasks.insert(id)
        let pending = PendingTask(task:task)
        Task {
            let result: Result<Data,Error>
            do { result = .success(try await ReaderFiles.data(url)) } catch { result = .failure(error) }
            let task = pending.task
            guard tasks.remove(id) != nil else { return }
            switch result {
            case .success(let data):
                task.didReceive(URLResponse(url:request,mimeType:UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",expectedContentLength:data.count,textEncodingName:nil))
                task.didReceive(data); task.didFinish()
            case .failure(let error): task.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { tasks.remove(ObjectIdentifier(task as AnyObject)) }
    private struct PendingTask: @unchecked Sendable { let task: WKURLSchemeTask }
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var host: EditorHost?
        init(_ host: EditorHost) { self.host = host }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { MainActor.assumeIsolated { host?.userContentController(controller,didReceive:message) } }
    }
    private final class SchemeRelay: NSObject, WKURLSchemeHandler {
        weak var host: EditorHost?
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { if let host { host.webView(webView,start:task) } else { task.didFailWithError(URLError(.cancelled)) } } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { host?.webView(webView,stop:task) } }
    }
}

struct EditorWebView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    func makeUIView(context: Context) -> UIView {
        let container = UIView(); attach(container)
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        let host = EditorHost.shared
        host.model = model; host.appearance = colorScheme == .light ? "light" : "dark"
        attach(container); host.render()
    }
    private func attach(_ container: UIView) {
        let view = EditorHost.shared.view
        guard view.superview !== container else { return }
        view.frame = container.bounds; view.autoresizingMask = [.flexibleWidth,.flexibleHeight]; container.addSubview(view)
    }
}
