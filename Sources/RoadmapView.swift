import SwiftUI
import WebKit

struct RoadmapView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let file: VaultEntry
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(model:model,file:file) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.host.view }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.file = file
        coordinator.host.bridge.appearance = colorScheme == .light ? "light" : "dark"
        coordinator.host.bridge.refresh()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.host.close() }

    @MainActor final class Coordinator {
        let host = ComponentWebHost(page:"roadmap")
        weak var model: AppModel?
        var file: VaultEntry
        init(model: AppModel, file: VaultEntry) {
            self.model = model; self.file = file
            let bridge = host.bridge
            bridge.state = { [weak self] in
                guard let self, let model = self.model else { return "" }
                return "\(model.indexGeneration)|\(model.roadmapRevision)|\(model.language.rawValue)|\(self.file.relativePath)|\(self.file.modified?.timeIntervalSince1970 ?? 0)"
            }
            bridge.payload = { [weak self] appearance in
                guard let self else { return nil }
                return self.model?.roadmapPayload(self.file,appearance:appearance,platform:"mac")
            }
            bridge.handle = { [weak self] value in
                guard let self else { return false }
                return self.model?.roadmapMessage(value,file:self.file) ?? false
            }
            bridge.savedView = { [weak self] in
                guard let self else { return nil }
                return self.model?.roadmapView(self.file)
            }
            host.start()
        }
    }
}

@MainActor final class ComponentWebHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let bridge: ComponentBridge
    private var observer: NSObjectProtocol?
    init(page: String) {
        bridge = ComponentBridge(page:page)
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
        bridge.view = view
        observer = NotificationCenter.default.addObserver(forName:Notification.Name("acdianFindInPage"),object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.view.window?.makeFirstResponder(self.view)
                self.bridge.send(["type":"find"])
            }
        }
    }
    func start() { bridge.load() }
    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        bridge.send(["type":"flush"])
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ComponentBridge.allows(navigationAction) ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { bridge.load() }
    private final class SchemeRelay: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,start:task) } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { LiveEditorHost.shared.webView(webView,stop:task) } }
    }
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var host: ComponentWebHost?
        init(_ host: ComponentWebHost) { self.host = host }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { MainActor.assumeIsolated { host?.bridge.receive(message) } }
    }
}
