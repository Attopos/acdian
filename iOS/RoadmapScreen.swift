import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor final class ComponentCanvasHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let bridge: ComponentBridge
    var appearance: String { get { bridge.appearance } set { bridge.appearance = newValue } }
    var state: () -> String { get { bridge.state } set { bridge.state = newValue } }
    var payload: (String) -> [String: Any]? { get { bridge.payload } set { bridge.payload = newValue } }
    var handle: ([String: Any]) -> Bool { get { bridge.handle } set { bridge.handle = newValue } }
    var savedView: () -> [String: Double]? { get { bridge.savedView } set { bridge.savedView = newValue } }
    var resolve: (String, String) -> URL? = { _, _ in nil }
    private var tasks = Set<ObjectIdentifier>()

    init(page: String) {
        bridge = ComponentBridge(page:page)
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let relay = Relay()
        config.setURLSchemeHandler(relay,forURLScheme:"acdian-resource")
        config.userContentController.add(relay,name:"acdian")
        view = WKWebView(frame:.zero,configuration:config)
        super.init()
        relay.host = self
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsLinkPreview = false
        view.navigationDelegate = self
        bridge.view = view
        bridge.load()
    }
    func refresh() { bridge.refresh() }
    func flush() { bridge.send(["type":"flush"]) }
    fileprivate func start(_ task: WKURLSchemeTask) {
        guard let request = task.request.url, let components = URLComponents(url:request,resolvingAgainstBaseURL:false) else { task.didFailWithError(URLError(.badURL)); return }
        let path = String(components.percentEncodedPath.dropFirst())
        let from = components.queryItems?.first { $0.name == "from" }?.value ?? ""
        guard let url = resolve(path,from) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
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
    fileprivate func stop(_ task: WKURLSchemeTask) { tasks.remove(ObjectIdentifier(task as AnyObject)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ComponentBridge.allows(navigationAction) ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { bridge.load() }
    private struct PendingTask: @unchecked Sendable { let task: WKURLSchemeTask }
    private final class Relay: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
        weak var host: ComponentCanvasHost?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { MainActor.assumeIsolated { host?.bridge.receive(message) } }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { MainActor.assumeIsolated { if let host { host.start(task) } else { task.didFailWithError(URLError(.cancelled)) } } }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { MainActor.assumeIsolated { host?.stop(task) } }
    }
}

struct ComponentCanvas: UIViewRepresentable {
    let page: String
    let configure: (ComponentCanvasHost) -> Void
    var stateKey: String
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> ComponentCanvasHost { ComponentCanvasHost(page:page) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.view }
    func updateUIView(_ view: WKWebView, context: Context) {
        let host = context.coordinator
        configure(host)
        host.appearance = colorScheme == .light ? "light" : "dark"
        host.refresh()
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: ComponentCanvasHost) { coordinator.flush() }
}

/// iPad: the shared model, the same as the Mac, including editing where the platform allows it.
struct EditableRoadmap: View {
    @ObservedObject var model: AppModel
    let file: VaultEntry
    var body: some View {
        ComponentCanvas(page:"roadmap",configure: { host in
            let model = model, file = file
            host.state = { "\(model.indexGeneration)|\(model.roadmapRevision)|\(model.language.rawValue)|\(file.relativePath)|\(file.modified?.timeIntervalSince1970 ?? 0)" }
            host.payload = { [weak model] appearance in model?.roadmapPayload(file,appearance:appearance,platform:"ios") }
            host.handle = { [weak model] value in model?.roadmapMessage(value,file:file) ?? false }
            host.savedView = { [weak model] in model?.roadmapView(file) }
            host.resolve = { [weak model] target,from in model?.index?.resolve(target,from:from) }
        },stateKey:file.relativePath + "|\(model.roadmapRevision)|\(model.indexGeneration)")
        .ignoresSafeArea(edges:.bottom)
    }
}

/// iPhone: the reader's store. The roadmap can be read and followed into its pages; editing stays on the Mac and iPad.
struct RoadmapScreen: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var router: ReaderRouter
    let file: VaultEntry
    var focus: String? = nil
    var body: some View {
        ComponentCanvas(page:"roadmap",configure: { host in
            let store = store, router = router, file = file, focus = focus
            host.state = { "\(store.changeTick)|\(file.relativePath)|\(file.modified?.timeIntervalSince1970 ?? 0)" }
            host.payload = { [weak store] appearance in
                guard let store, let index = store.index else { return nil }
                var message = RoadmapPayload.make(file,index:index,language:store.language.rawValue,editable:false,appearance:appearance,platform:"ios")
                if let focus { message?["focus"] = focus }
                return message
            }
            host.handle = { [weak store, weak router] value in
                guard let store, let router, let type = value["type"] as? String else { return false }
                if type == "openPage", let key = value["key"] as? String, let index = store.index, let page = RoadmapPayload.page(key,in:file,index:index) {
                    router.push(page.relativePath,fragment:value["heading"] as? String ?? "")
                }
                if type == "viewChanged", let x = value["x"] as? Double, let y = value["y"] as? Double, let k = value["k"] as? Double {
                    UserDefaults.standard.set([x,y,k],forKey:"roadmapView2:" + file.relativePath)
                }
                return false
            }
            host.savedView = {
                guard let saved = UserDefaults.standard.array(forKey:"roadmapView2:" + file.relativePath) as? [Double], saved.count == 3 else { return nil }
                return ["x":saved[0],"y":saved[1],"k":saved[2]]
            }
            host.resolve = { [weak store] target,from in store?.index?.resolve(target,from:from) }
        },stateKey:"\(store.changeTick)")
        .ignoresSafeArea(edges:.bottom)
        .toolbar {
            if let source = RoadmapDocument.read(file.url)?.source, !source.isEmpty, store.folder(source) != nil {
                ToolbarItem(placement:.topBarTrailing) {
                    NavigationLink(value:Route.folder(source)) { Image(systemName:"list.bullet") }.accessibilityLabel(store.localized("页面"))
                }
            }
        }
    }
}
