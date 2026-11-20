import SwiftUI
import WebKit

struct RoadmapView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let file: VaultEntry
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> RoadmapHost { RoadmapHost(model:model,file:file) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.view }
    func updateNSView(_ view: WKWebView, context: Context) {
        let host = context.coordinator
        host.file = file; host.appearance = colorScheme == .light ? "light" : "dark"
        host.refresh()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: RoadmapHost) { coordinator.close() }
}

/// Draws one roadmap file in its own web view. The page only posts changes; every file write happens in the model.
@MainActor final class RoadmapHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    weak var model: AppModel?
    var file: VaultEntry
    var appearance = "dark"
    private var ready = false
    private var sent = false
    private var lastState = ""
    private var lastJSON = ""
    private var observer: NSObjectProtocol?
    init(model: AppModel, file: VaultEntry) {
        self.model = model; self.file = file
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SchemeRelay(),forURLScheme:"acdian-resource")
        view = WKWebView(frame:NSRect(x:0,y:0,width:900,height:700),configuration:config)
        super.init()
        config.userContentController.add(MessageRelay(self),name:"acdian")
        view.setValue(false,forKey:"drawsBackground")
        view.navigationDelegate = self
        view.isInspectable = false
        view.allowsMagnification = false
        observer = NotificationCenter.default.addObserver(forName:Notification.Name("acdianFindInPage"),object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.view.window?.makeFirstResponder(self.view)
                self.view.evaluateJavaScript("window.acdianRoadmap&&window.acdianRoadmap.receive({type:'find'})",completionHandler:nil)
            }
        }
        load()
    }
    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        view.evaluateJavaScript("window.acdianRoadmap&&window.acdianRoadmap.receive({type:'flush'})",completionHandler:nil)
    }
    private func load() {
        ready = false; sent = false; lastState = ""; lastJSON = ""
        guard let url = Bundle.main.url(forResource:"roadmap",withExtension:"html",subdirectory:"roadmap") else { return }
        view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent().deletingLastPathComponent())
    }
    func refresh(silently: Bool = false) {
        guard ready, let model else { return }
        let state = "\(model.indexGeneration)|\(model.roadmapRevision)|\(appearance)|\(model.language.rawValue)|\(file.relativePath)|\(file.modified?.timeIntervalSince1970 ?? 0)"
        guard state != lastState else { return }
        lastState = state
        guard var payload = model.roadmapPayload(file,appearance:appearance,platform:"mac"),
              let body = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]), let fingerprint = String(data:body,encoding:.utf8), fingerprint != lastJSON else { return }
        lastJSON = fingerprint
        if silently && sent { return }
        payload["type"] = sent ? "update" : "load"
        if !sent, let saved = model.roadmapView(file) { payload["view"] = saved }
        guard let data = try? JSONSerialization.data(withJSONObject:payload), let json = String(data:data,encoding:.utf8) else { return }
        sent = true
        view.evaluateJavaScript("window.acdianRoadmap.receive(\(json));",completionHandler:nil)
    }
    fileprivate func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; sent = false; lastState = ""; lastJSON = ""; refresh(); return }
        if model?.roadmapMessage(value,file:file) == true { refresh(silently:true) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, navigationAction.navigationType != .linkActivated else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }
    private final class SchemeRelay: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,start:task) } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,stop:task) } }
    }
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var host: RoadmapHost?
        init(_ host: RoadmapHost) { self.host = host }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { host?.received(message) }
    }
}
