import SwiftUI

extension Color {
    static let acPink = Color(.sRGB,red:217.0/255,green:59.0/255,blue:134.0/255,opacity:1)
    static func adaptive(dark: UIColor, light: UIColor) -> Color { Color(uiColor:UIColor { $0.userInterfaceStyle == .light ? light : dark }) }
    static let canvas = adaptive(dark:UIColor(red:0.065,green:0.065,blue:0.078,alpha:1),light:.white)
    static let faint = adaptive(dark:UIColor.white.withAlphaComponent(0.07),light:UIColor.black.withAlphaComponent(0.08))
    static let ink = adaptive(dark:UIColor(red:0.96,green:0.95,blue:0.97,alpha:1),light:UIColor(red:0.09,green:0.086,blue:0.106,alpha:1))
    static let wash = adaptive(dark:UIColor.white.withAlphaComponent(0.045),light:UIColor.black.withAlphaComponent(0.04))
}

@main struct ReaderApp: App {
    // Editing is iPad-only: an iPhone always gets the read-only reader.
    var body: some Scene { WindowGroup { if UIDevice.current.userInterfaceIdiom == .pad { EditorRoot() } else { RootView() } } }
}

struct RootView: View {
    @StateObject private var store = ReaderStore()
    @StateObject private var router = ReaderRouter()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack(path:$router.compactPath) { LauncherScreen().withRoutes() }
            } else {
                NavigationSplitView {
                    NavigationStack(path:$router.sidebar) { LauncherScreen().withRoutes() }
                } detail: {
                    NavigationStack(path:$router.detail) {
                        ReaderEmptyState(icon:"doc.text",message:store.localized("页面")).withRoutes()
                    }
                }
            }
        }
        .environmentObject(store).environmentObject(router).tint(.acPink)
        .task { PerfLog.mark("root view appears"); store.start(); ReaderWebView.WebViewPool.shared.warm(); if PerfLog.enabled { await perfRun() } }
        .onChange(of:scenePhase) { _,phase in if phase == .active { Task { await store.reload() } } }
    }
}

extension RootView {
    /// With `--perf`: opens the biggest Card Index and searches, timing each.
    @MainActor private func perfRun() async {
        while store.index == nil { try? await Task.sleep(nanoseconds:20_000_000) }
        PerfLog.mark("launcher ready (\(store.presentModules.count) modules)")
        try? await Task.sleep(nanoseconds:1_000_000_000)
        if let card = store.components.keys.sorted().last(where: { $0.contains("GRE") }) ?? store.components.keys.first {
            PerfLog.mark("open card index \(card)")
            router.compactPath = [.file(card,fragment:"")]
        } else { PerfLog.mark("no card index known yet") }
        try? await Task.sleep(nanoseconds:5_000_000_000)
        router.compactPath = []
        for (label,word) in [("first search","abate"),("search","the"),("Chinese search","中文")] {
            let found = PerfLog.measure("\(label) '\(word)'") { store.search(word,inModule:nil).count }
            PerfLog.mark("  \(found) results, \(store.db?.count ?? 0) pages in cache")
        }
        try? await Task.sleep(nanoseconds:45_000_000_000)
        let found = PerfLog.measure("later search 'abate'") { store.search("abate",inModule:nil).count }
        PerfLog.mark("  \(found) results, \(store.db?.count ?? 0) pages in cache")
    }
}

extension View {
    func withRoutes() -> some View { navigationDestination(for:Route.self) { RouteScreen(route:$0) } }
    /// The app's canvas behind a list or grid.
    func readerBackground() -> some View { scrollContentBackground(.hidden).background(Color.canvas) }
}

struct RouteScreen: View {
    @EnvironmentObject private var store: ReaderStore
    let route: Route
    var body: some View {
        switch route {
        case .folder(let path):
            if let folder = store.folder(path) { FolderScreen(folder:folder) } else { missing }
        case .file(let path,let fragment):
            // The id gives each page its own loader when one page replaces another in the same column.
            if let file = store.file(path) { FileScreen(file:file,fragment:fragment).id(route) } else { missing }
        }
    }
    private var missing: some View { ReaderEmptyState(icon:"questionmark.folder",message:store.localized("没有找到匹配的文件")) }
}

struct ReaderEmptyState: View {
    let icon: String
    let message: String
    var body: some View {
        VStack(spacing:12) {
            Image(systemName:icon).font(.system(size:40,weight:.ultraLight)).foregroundStyle(Color.acPink)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas)
    }
}
