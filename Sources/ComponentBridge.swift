import Foundation
import WebKit

@MainActor final class ComponentBridge {
    let page: String
    weak var view: WKWebView?
    var appearance = "dark"
    var state: () -> String = { "" }
    var payload: (String) -> [String: Any]? = { _ in nil }
    var handle: ([String: Any]) -> Bool = { _ in false }
    var savedView: () -> [String: Double]? = { nil }
    private var ready = false
    private var sent = false
    private var lastState = ""
    private var lastJSON = ""

    init(page: String) { self.page = page }

    var receiver: String { "acdian" + page.prefix(1).uppercased() + page.dropFirst() }

    func load() {
        reset()
        guard let view, let url = Bundle.main.url(forResource:page,withExtension:"html",subdirectory:page) else { return }
        view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent().deletingLastPathComponent())
    }

    func refresh(silently: Bool = false) {
        guard ready else { return }
        let key = state() + "|" + appearance
        guard key != lastState else { return }
        lastState = key
        guard var message = payload(appearance),
              let body = try? JSONSerialization.data(withJSONObject:message,options:[.sortedKeys]), let fingerprint = String(data:body,encoding:.utf8), fingerprint != lastJSON else { return }
        lastJSON = fingerprint
        if silently && sent { return }
        message["type"] = sent ? "update" : "load"
        if !sent, let saved = savedView() { message["view"] = saved }
        sent = true
        send(message)
    }

    func send(_ message: [String: Any]) {
        guard let view, let data = try? JSONSerialization.data(withJSONObject:message), let json = String(data:data,encoding:.utf8) else { return }
        view.evaluateJavaScript("window.\(receiver)&&window.\(receiver).receive(\(json));",completionHandler:nil)
    }

    func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
        if type == "ready" { reset(); ready = true; refresh(); return }
        if handle(value) { lastState = ""; refresh(silently:true) }
    }

    static func allows(_ action: WKNavigationAction) -> Bool {
        guard let url = action.request.url, action.navigationType != .linkActivated else { return false }
        return url.isFileURL || url.scheme == "acdian-resource" || url.scheme == "about"
    }

    private func reset() { ready = false; sent = false; lastState = ""; lastJSON = "" }
}
