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
    var body: some Scene { WindowGroup { RootView() } }
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
        .task { store.start() }
        .onChange(of:scenePhase) { _,phase in if phase == .active { Task { await store.reload() } } }
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
            if let file = store.file(path) { FileScreen(file:file,fragment:fragment) } else { missing }
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
