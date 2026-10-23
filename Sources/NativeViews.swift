import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers

struct LiveMarkdownEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator,name:"acdian")
        config.setURLSchemeHandler(context.coordinator,forURLScheme:"acdian-resource")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame:.zero,configuration:config)
        view.setValue(false,forKey:"drawsBackground")
        view.navigationDelegate = context.coordinator
        view.isInspectable = false
        context.coordinator.view = view
        context.coordinator.attachBridge()
        if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
        return view
    }
    func updateNSView(_ view: WKWebView,context: Context) { context.coordinator.model = model; context.coordinator.render() }
    static func dismantleNSView(_ view: WKWebView,coordinator: Coordinator) {
        coordinator.disposed = true
        view.configuration.userContentController.removeScriptMessageHandler(forName:"acdian")
        view.stopLoading(); coordinator.activeTasks.removeAll()
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
        var model: AppModel
        weak var view: WKWebView?
        let representedPath: String
        let representedDocumentID: UUID
        var ready = false
        var disposed = false
        var documentInstalled = false
        var focusPending = false
        var initialSelection: (anchor:Int,head:Int)?
        var lastJSText: String?
        var latestJSRevision = -1
        var syncFailures = 0
        var syncBlocked = false
        var lastConfig = ""
        var lastAnchor = ""
        var pendingInsertion: UUID?
        var activeTasks = Set<ObjectIdentifier>()
        init(_ model: AppModel) {
            self.model = model; representedPath = model.selected?.relativePath ?? ""; representedDocumentID = model.editorDocumentID
            initialSelection = model.pendingEditorSelection; focusPending = initialSelection != nil
            model.pendingEditorSelection = nil
        }
        var isCurrent: Bool { !disposed && model.selected?.relativePath == representedPath && model.editorDocumentID == representedDocumentID }
        func attachBridge() {
            model.editorFocus = { [weak self] in
                guard let self, self.isCurrent else { return }
                self.focusPending = true
                self.focusEditorIfReady()
            }
            model.editorSnapshot = { [weak self] completion in
                guard let self, self.isCurrent, let view = self.view else { completion(.failure(URLError(.cancelled))); return }
                if !self.ready || !self.documentInstalled {
                    completion(.success(EditorSnapshot(text:self.model.text,currentPath:self.representedPath))); return
                }
                view.evaluateJavaScript("window.acdianGetDocument()") { result,error in
                    guard self.isCurrent else { completion(.failure(URLError(.cancelled))); return }
                    if let error { completion(.failure(error)); return }
                    guard let result = result as? [String:Any], let text = result["text"] as? String, let path = result["currentPath"] as? String, path == self.representedPath else { completion(.failure(URLError(.cannotParseResponse))); return }
                    let revision = result["revision"] as? Int ?? self.latestJSRevision
                    // Getter completion and change messages cross independent IPC
                    // paths; never replace a newer accepted change with an old read.
                    let newest = revision < self.latestJSRevision ? (self.lastJSText ?? text) : text
                    self.latestJSRevision = max(self.latestJSRevision,revision)
                    self.lastJSText = newest
                    let selection = revision < self.latestJSRevision ? self.model.editorSelection : nil
                    completion(.success(EditorSnapshot(text:newest,currentPath:path,selectionAnchor:selection?.anchor ?? result["selectionAnchor"] as? Int,selectionHead:selection?.head ?? result["selectionHead"] as? Int)))
                }
            }
        }
        func focusEditorIfReady() {
            guard focusPending, ready, documentInstalled, isCurrent, let view else { return }
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
            guard ready, isCurrent, !syncBlocked, let view else { return }
            var payload: [String:Any] = ["currentPath":representedPath,"title":model.isDraft ? model.draftTitle : model.selected?.name ?? "","draft":model.isDraft,"fontSize":model.fontSize,"editable":!model.loading,"language":model.language.rawValue]
            let sendText = !documentInstalled || model.text != lastJSText
            if sendText { payload["text"] = model.text }
            if let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8), sendText || json != lastConfig {
                let textSent = payload["text"] as? String
                // Record the scheduled source, so unrelated SwiftUI changes never
                // enqueue an old document over a keystroke still crossing IPC.
                if let textSent { lastJSText = textSent }
                documentInstalled = true; lastConfig = json
                view.evaluateJavaScript("window.acdianSetDocument(\(json));") { [weak self] _,error in
                    guard let self, self.isCurrent else { return }
                    if let error {
                        self.lastConfig = ""
                        if textSent != nil { self.documentInstalled = false; self.lastJSText = nil }
                        self.syncFailures += 1
                        if self.syncFailures < 3 { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { if self.isCurrent { self.render() } } }
                        else { self.syncBlocked = true; self.model.error = self.model.localized("编辑器加载失败，请重新载入文件。\n%@",error.localizedDescription) }
                        return
                    }
                    self.syncFailures = 0
                    self.scroll(); self.insertPendingAttachment(); self.focusEditorIfReady()
                }
            } else { scroll(); insertPendingAttachment(); focusEditorIfReady() }
        }
        func scroll() {
            guard !model.anchor.isEmpty, model.anchor != lastAnchor, let data = try? JSONSerialization.data(withJSONObject:[model.anchor]), let json = String(data:data,encoding:.utf8) else { return }
            let anchor = model.anchor
            view?.evaluateJavaScript("window.acdianScrollTo(\(json)[0]);") { [weak self] _,error in if error == nil { self?.lastAnchor = anchor } }
        }
        func insertPendingAttachment() {
            guard isCurrent, ready, !model.loading, let insertion = model.insertion, pendingInsertion != insertion.id,
                  let data = try? JSONSerialization.data(withJSONObject:[insertion.text,insertion.id.uuidString]), let json = String(data:data,encoding:.utf8) else { return }
            pendingInsertion = insertion.id
            view?.evaluateJavaScript("window.acdianInsertText(\(json)[0], \(json)[1]);") { [weak self] result,error in
                guard let self, self.isCurrent else { return }
                if let error { self.pendingInsertion = nil; self.model.error = self.model.localized("附件链接插入失败：%@",error.localizedDescription); return }
                if let accepted = result as? Bool, !accepted { self.pendingInsertion = nil; return }
                if self.model.insertion?.id == insertion.id { self.model.insertion = nil }
            }
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard isCurrent, message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
            if type == "ready" { ready = true; render(); return }
            let path = value["currentPath"] as? String ?? value["from"] as? String
            guard path == representedPath else { return }
            if type == "change", let text = value["text"] as? String {
                let revision = value["revision"] as? Int ?? latestJSRevision
                guard revision >= latestJSRevision else { return }
                latestJSRevision = revision; lastJSText = text
                if let anchor = value["selectionAnchor"] as? Int, let head = value["selectionHead"] as? Int { model.editorSelection = (anchor,head) }
                if model.text != text { model.text = text }
            }
            if type == "save", let text = value["text"] as? String {
                lastJSText = text; model.text = text
                if let anchor = value["selectionAnchor"] as? Int, let head = value["selectionHead"] as? Int { model.editorSelection = (anchor,head) }
                model.save()
            }
            if type == "navigate", let target = value["target"] as? String { model.navigate(target) }
            if type == "external", let target = value["target"] as? String { model.external(target) }
        }
        func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); return }
            if url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView,start urlSchemeTask: WKURLSchemeTask) {
            guard let request = urlSchemeTask.request.url,
                  let index = model.index,
                  let components = URLComponents(url:request,resolvingAgainstBaseURL:false) else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
            let path = String(components.percentEncodedPath.dropFirst())
            let from = components.queryItems?.first(where: {$0.name == "from"})?.value ?? ""
            guard let url = index.resolve(path,from:from) else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
            let taskID = ObjectIdentifier(urlSchemeTask as AnyObject); activeTasks.insert(taskID)
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try Data(contentsOf:url) }
                DispatchQueue.main.async {
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
    }
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
        }.background(Color(red:0.065,green:0.065,blue:0.08))
    }
}
