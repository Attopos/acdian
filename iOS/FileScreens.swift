import SwiftUI
import PDFKit
import QuickLook
import WebKit

/// Loads one file, waiting for iCloud if it has to, and re-reads it when it
/// changes. A file that has not arrived yet is shown as waiting, never missing.
@MainActor final class FileLoader: ObservableObject {
    enum State { case loading, waiting, ready(Data?) }
    @Published private(set) var state = State.loading
    private var stamp: FileStamp?
    private var task: Task<Void,Never>?
    private let url: URL
    private let readsContent: Bool
    init(url: URL, readsContent: Bool) { self.url = url; self.readsContent = readsContent }
    deinit { task?.cancel() }
    func load() {
        task?.cancel()
        let url = url, readsContent = readsContent
        task = Task { [weak self] in
            do {
                if readsContent {
                    let data = try await ReaderFiles.data(url)
                    guard !Task.isCancelled, let self else { return }
                    self.stamp = FileStamp(of:url); self.state = .ready(data)
                } else {
                    try await ReaderFiles.materialize(url)
                    guard !Task.isCancelled, let self else { return }
                    self.stamp = FileStamp(of:url); self.state = .ready(nil)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state = .waiting
            }
        }
    }
    /// After a rescan: fetch a newer version, retry a failed read, reload what changed.
    func folderChanged() {
        switch state {
        case .loading: break
        case .waiting: load()
        case .ready:
            if ReaderFiles.isOutdated(url) { ReaderFiles.startDownloading(url) }
            else if let current = FileStamp(of:url), current != stamp { load() }
        }
    }
}

/// Opens a file by kind, once its content is on the device.
struct FileScreen: View {
    @EnvironmentObject private var store: ReaderStore
    let file: VaultEntry
    let fragment: String
    @StateObject private var loader: FileLoader
    init(file: VaultEntry, fragment: String) {
        self.file = file; self.fragment = fragment
        let quickLook = !["md","markdown",ComponentStore.fileExtension,"pdf"].contains(file.ext) && !Self.isDrawnImage(file.ext)
        _loader = StateObject(wrappedValue:FileLoader(url:file.url,readsContent:!quickLook))
    }
    private static func isDrawnImage(_ ext: String) -> Bool { MediaKinds.images.contains(ext) }
    private var title: String { ["md","markdown",ComponentStore.fileExtension].contains(file.ext) ? (file.name as NSString).deletingPathExtension : file.name }
    var body: some View {
        content
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .onAppear(perform:loader.load)
            .onChange(of:store.changeTick) { loader.folderChanged() }
    }
    @ViewBuilder private var content: some View {
        switch loader.state {
        case .loading: ProgressView(store.localized("正在从 iCloud 下载…")).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas)
        case .waiting:
            VStack(spacing:14) {
                ReaderEmptyState(icon:"icloud.and.arrow.down",message:store.localized("这个文件还在 iCloud 里，连上网络后会自动显示。")).frame(height:200)
                Button(store.localized("重试"),action:loader.load).buttonStyle(.bordered)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas)
        case .ready(let data): ready(data)
        }
    }
    @ViewBuilder private func ready(_ data: Data?) -> some View {
        if file.ext == "md" || file.ext == "markdown", let data {
            MarkdownScreen(file:file,text:VaultDecode.text(data),fragment:fragment)
        } else if file.ext == ComponentStore.fileExtension {
            if let data, let instance = try? JSONDecoder().decode(ComponentInstance.self,from:data) { CardIndexScreen(file:file,instance:instance) }
            else { ReaderEmptyState(icon:"puzzlepiece.extension",message:store.localized("无法读取这个组件。")) }
        } else if file.ext == "pdf", let data {
            PDFScreen(data:data,fragment:fragment).ignoresSafeArea(edges:.bottom)
        } else if file.ext == "svg", let data {
            SVGScreen(data:data)
        } else if MediaKinds.images.contains(file.ext), let data {
            ImageScreen(data:data)
        } else {
            QuickLookScreen(url:file.url).ignoresSafeArea(edges:.bottom)
        }
    }
}

enum VaultDecode {
    /// UTF-8 with an optional byte-order mark, as the Mac reads it.
    static func text(_ data: Data) -> String {
        let content = data.starts(with:[0xEF,0xBB,0xBF]) ? data.dropFirst(3) : data[...]
        return String(decoding:content,as:UTF8.self)
    }
}

struct PDFScreen: UIViewRepresentable {
    let data: Data
    var fragment = ""
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = UIColor(white:0.09,alpha:1)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.shown != data else { return }
        context.coordinator.shown = data
        view.document = PDFDocument(data:data)
        if fragment.hasPrefix("page="), let n = Int(fragment.dropFirst(5).prefix(while:{ $0.isNumber })), let page = view.document?.page(at:max(0,n-1)) { view.go(to:page) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown: Data? }
}

/// An image filling the screen. Pinch to zoom; a tap hides the bars.
struct ImageScreen: View {
    let data: Data
    @State private var barsHidden = false
    var body: some View {
        ZoomableImage(data:data) { withAnimation(.easeInOut(duration:0.18)) { barsHidden.toggle() } }
            .ignoresSafeArea().background(Color.black.ignoresSafeArea())
            .toolbar(barsHidden ? .hidden : .visible,for:.navigationBar).statusBarHidden(barsHidden)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let data: Data
    let tapped: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6; scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let image = UIImageView(); image.contentMode = .scaleAspectFit
        image.autoresizingMask = [.flexibleWidth,.flexibleHeight]; image.frame = scroll.bounds
        scroll.addSubview(image); context.coordinator.image = image
        scroll.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap)))
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.tapped = tapped
        if context.coordinator.shown != data { context.coordinator.shown = data; context.coordinator.image?.image = UIImage(data:data) }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var image: UIImageView?; var shown: Data?; var tapped: () -> Void = {}
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
        @objc func tap() { tapped() }
    }
}

/// SVG files, drawn with scripts switched off.
private struct SVGScreen: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false; config.websiteDataStore = .nonPersistent()
        let view = MenuFreeWebView(frame:.zero,configuration:config); view.allowsLinkPreview = false; view.isOpaque = false; view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.load(data,mimeType:"image/svg+xml",characterEncodingName:"utf-8",baseURL:URL(string:"about:blank")!)
    }
}

/// Everything else the system can preview, video included.
private struct QuickLookScreen: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url:url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
