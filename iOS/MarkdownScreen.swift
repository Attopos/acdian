import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// A page, read-only, in the same web editor the Mac app uses.
struct MarkdownScreen: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var router: ReaderRouter
    @Environment(\.colorScheme) private var colorScheme
    let file: VaultEntry
    let text: String
    let fragment: String
    @State private var missingLink: String?
    var body: some View {
        ReaderWebView(store:store,path:file.relativePath,name:(file.name as NSString).deletingPathExtension,text:text,fragment:fragment,appearance:colorScheme == .light ? "light" : "dark") { target in
            let parts = target.components(separatedBy:"#")
            guard let page = store.resolve(target,from:file.relativePath) else { missingLink = target; return }
            let linked = parts.dropFirst().joined(separator:"#")
            router.push(page.relativePath,fragment:linked.removingPercentEncoding ?? linked)
        }
        .ignoresSafeArea(edges:.bottom).background(Color.canvas)
        // The page shows its own title, so the bar stays clear.
        .toolbar { ToolbarItem(placement:.principal) { Text("") } }
        .alert(store.localized("没有找到匹配的文件"),isPresented:Binding(get:{ missingLink != nil },set:{ if !$0 { missingLink = nil } })) {
            Button(store.localized("好"),role:.cancel) {}
        } message: { Text(missingLink ?? "") }
    }
}

struct ReaderWebView: UIViewRepresentable {
    let store: ReaderStore
    let path: String
    let name: String
    let text: String
    let fragment: String
    let appearance: String
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        // A web view with the editor already loaded is taken from the pool, so a
        // page shows without waiting for the editor's scripts to start.
        let (view,relay) = WebViewPool.shared.take()
        PerfLog.mark("web view taken (prewarmed \(relay.ready))")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(self)
        relay.coordinator = context.coordinator
        if relay.ready { context.coordinator.becameReady() }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self); context.coordinator.render() }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    /// Keeps one web view loaded and ready for the next page.
    @MainActor final class WebViewPool {
        static let shared = WebViewPool()
        private var spare: (WKWebView,Relay)?
        func warm() {
            guard spare == nil else { return }
            let relay = Relay()
            let config = WKWebViewConfiguration()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(relay,forURLScheme:"acdian-resource")
            config.userContentController.add(relay,name:"acdian")
            config.userContentController.addUserScript(WKUserScript(source:ReaderWebView.touchScript,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
            let view = MenuFreeWebView(frame:CGRect(x:0,y:0,width:390,height:800),configuration:config)
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
            // CodeMirror scrolls inside the page; the outer view must stay still.
            view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
            view.scrollView.contentInsetAdjustmentBehavior = .never
            view.allowsLinkPreview = false
            if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
            spare = (view,relay)
        }
        func take() -> (WKWebView,Relay) {
            if spare == nil { warm() }
            let taken = spare!; spare = nil
            DispatchQueue.main.async { self.warm() }
            return taken
        }
    }
    /// Passes the page's messages and resource requests to whichever page took the view.
    final class Relay: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
        weak var coordinator: Coordinator?
        var ready = false
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                if (message.body as? [String:Any])?["type"] as? String == "ready" { ready = true }
                coordinator?.userContentController(controller,didReceive:message)
            }
        }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { if let coordinator { coordinator.webView(webView,start:task) } else { task.didFailWithError(URLError(.cancelled)) } } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { coordinator?.webView(webView,stop:task) } }
    }

    /// The touch adjustments live only in this app; the Mac editor never loads them.
    static let touchBasics: String = {
        let css = Bundle.main.url(forResource:"reader-touch",withExtension:"css").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""
        let literal = (try? JSONSerialization.data(withJSONObject:[css])).flatMap { String(data:$0,encoding:.utf8) } ?? "[\"\"]"
        return """
        (function(){
          var meta=document.querySelector('meta[name=viewport]');
          if(meta)meta.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
          var style=document.createElement('style');style.textContent=\(literal)[0];document.head.appendChild(style);
        })();
        """
    }()
    /// The read-only reader has no comment rail, and a tapped picture opens full screen.
    static let touchScript: String = touchBasics + """
    (function(){
      var style=document.createElement('style');style.textContent='.cm-comments,.cm-comments-panel,.cm-comments-header,.cm-comments-opener,.cm-comments-solved,.cm-comment-badge{display:none!important}';document.head.appendChild(style);
      document.addEventListener('click',function(event){
        var image=event.target.closest&&event.target.closest('img[data-live-resource]');
        if(!image||image.closest('a,[data-live-target]'))return;
        event.preventDefault();event.stopPropagation();
        window.webkit.messageHandlers.acdian.postMessage({type:'openImage',target:image.dataset.liveResource});
      },true);
    })();
    """

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        private var page: ReaderWebView?
        private var ready = false
        private let documentID = UUID().uuidString
        private var sentText: String?
        private var sentConfig = ""
        private var scrolled = false
        private var tasks = Set<ObjectIdentifier>()

        func update(_ page: ReaderWebView) { self.page = page }
        func becameReady() { PerfLog.mark("editor ready"); ready = true; render() }
        func load() {
            ready = false; sentText = nil; sentConfig = ""
            if let url = Bundle.main.url(forResource:"live-editor",withExtension:"html") { view?.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
        }
        func render() {
            guard ready, let page else { return }
            var payload: [String:Any] = ["currentPath":page.path,"documentID":documentID,"tabID":documentID,"openTabs":[documentID],"title":page.name,"draft":true,"fontSize":17,
                                         "editable":false,"language":page.store.language.rawValue,"appearance":page.appearance,"pageTitle":page.name]
            let sendText = sentText != page.text
            if sendText {
                payload["text"] = page.text
                if let sentText { payload["refresh"] = ["base":sentText] }
            }
            guard let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8), sendText || json != sentConfig else { return }
            sentText = page.text; sentConfig = json
            view?.evaluateJavaScript("window.acdianSetDocument(\(json));") { [weak self] _,error in
                guard let self, error == nil else { return }
                PerfLog.mark("page text shown")
                self.scrollToFragment()
            }
        }
        private func scrollToFragment() {
            guard !scrolled, let fragment = page?.fragment, !fragment.isEmpty, !fragment.hasPrefix("page=") else { return }
            scrolled = true; scroll(fragment)
        }
        private func scroll(_ anchor: String) {
            guard let data = try? JSONSerialization.data(withJSONObject:[anchor]), let json = String(data:data,encoding:.utf8) else { return }
            view?.evaluateJavaScript("window.acdianScrollTo(\(json)[0]);",completionHandler:nil)
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
            // Anything that would change a file (save, change, comments…) is not listened to.
            switch type {
            case "ready": becameReady()
            case "navigate":
                guard let target = value["target"] as? String else { return }
                if target.hasPrefix("#") { scroll(String(target.dropFirst())) } else { page?.open(target) }
            case "openImage":
                if let target = value["target"] as? String { page?.open(target) }
            case "external":
                guard let raw = value["target"] as? String, let url = URL(string:raw), ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
                UIApplication.shared.open(url)
            case "copy":
                if let text = value["text"] as? String { UIPasteboard.general.string = text }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, action.navigationType != .linkActivated else { decisionHandler(.cancel); return }
            decisionHandler(url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let request = task.request.url, let components = URLComponents(url:request,resolvingAgainstBaseURL:false) else { task.didFailWithError(URLError(.badURL)); return }
            let path = String(components.percentEncodedPath.dropFirst())
            if components.host == "interactive" { Self.serveInteractiveFrame(task,request:request,path:path); return }
            let from = components.queryItems?.first { $0.name == "from" }?.value ?? ""
            guard let url = page?.store.index?.resolve(path,from:from) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            let id = ObjectIdentifier(task as AnyObject); tasks.insert(id)
            let pending = PendingTask(task:task)
            Task {
                let result: Result<Data,Error>
                do { result = .success(try await ReaderFiles.data(url)) } catch { result = .failure(error) }
                let task = pending.task
                guard tasks.remove(id) != nil else { return }
                switch result {
                case .success(let data):
                    let mime = UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    task.didReceive(URLResponse(url:request,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil))
                    task.didReceive(data); task.didFinish()
                case .failure(let error): task.didFailWithError(error)
                }
            }
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { tasks.remove(ObjectIdentifier(task as AnyObject)) }
        private static let interactivePolicy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' acdian-resource://interactive; style-src 'unsafe-inline' acdian-resource://interactive; img-src data: blob: acdian-resource://interactive; font-src data: acdian-resource://interactive; media-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'"
        /// Interactive blocks load their frame and libraries from the app itself, as on the Mac.
        fileprivate static func serveInteractiveFrame(_ task: WKURLSchemeTask, request: URL, path: String) {
            let parts = (path.removingPercentEncoding ?? "").split(separator:"/").map(String.init)
            guard let resources = Bundle.main.resourceURL, !parts.isEmpty, !parts.contains(where:{ $0.hasPrefix(".") }) else { task.didFailWithError(URLError(.badURL)); return }
            let library = parts[0] == "lib", rest = library ? Array(parts.dropFirst()) : parts
            let url = rest.reduce(resources.appendingPathComponent(library ? "vendor" : "interactive",isDirectory:true)) { $0.appendingPathComponent($1) }
            guard !rest.isEmpty, let data = try? Data(contentsOf:url) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            var mime = UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if ["html","js","css"].contains(url.pathExtension) { mime += "; charset=utf-8" }
            let headers = ["Content-Type":mime,"Content-Security-Policy":Self.interactivePolicy,"Access-Control-Allow-Origin":"*","Cache-Control":"no-store"]
            guard let response = HTTPURLResponse(url:request,statusCode:200,httpVersion:"HTTP/1.1",headerFields:headers) else { task.didFailWithError(URLError(.badServerResponse)); return }
            task.didReceive(response); task.didReceive(data); task.didFinish()
        }
        private struct PendingTask: @unchecked Sendable { let task: WKURLSchemeTask }
    }
    @MainActor static func serveInteractive(_ task: WKURLSchemeTask, request: URL, path: String) { Coordinator.serveInteractiveFrame(task,request:request,path:path) }
    /// WebKit keeps message handlers strongly; this keeps only a weak link back.
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { coordinator?.userContentController(controller,didReceive:message) }
        }
    }
}
