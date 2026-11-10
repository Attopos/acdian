import SwiftUI

extension AppLanguage {
    /// The iOS app has no language setting yet; it follows the device.
    static var forDevice: AppLanguage {
        let first = Locale.preferredLanguages.first ?? "en"
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("es") { return .spanish }
        return .english
    }
}

/// The pages folder as the reader sees it. Reads only.
@MainActor final class ReaderStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var usesICloud = true
    @Published private(set) var index: VaultIndex?
    @Published private(set) var modules: [PageModule] = []
    @Published private(set) var components: [String:ComponentInstance] = [:]
    @Published private(set) var remote: Set<String> = []
    /// Goes up after every rescan, so open pages can check their own file.
    @Published private(set) var changeTick = 0
    @Published private(set) var foldedTexts: [String:NSString] = [:]
    @Published private(set) var notes: [String:String] = [:]
    let language = AppLanguage.forDevice

    private var files: [String:VaultEntry] = [:]
    private var folders: [String:VaultEntry] = [:]
    private var stamps: [String:FileStamp] = [:]
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingReload: Task<Void,Never>?
    private var reloadID = UUID()
    private var textPassID = UUID()

    func localized(_ source: String, _ arguments: CVarArg...) -> String { language.localized(source,arguments:arguments) }

    func start() {
        guard root == nil else { return }
        DispatchQueue.global(qos:.userInitiated).async {
            let found = ReaderFiles.pagesRoot()
            DispatchQueue.main.async {
                self.root = found.root; self.usesICloud = found.iCloud
                if found.iCloud { self.startQuery() }
                Task { await self.reload() }
            }
        }
    }
    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value:true)
        query.notificationBatchingInterval = 0.5
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:query,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        self.query = query
        query.start()
    }
    private func queryItems() -> [ReaderFiles.QueryItem] {
        guard let query else { return [] }
        query.disableUpdates(); defer { query.enableUpdates() }
        return (query.results as? [NSMetadataItem] ?? []).compactMap { item in
            guard let url = item.value(forAttribute:NSMetadataItemURLKey) as? URL else { return nil }
            let status = item.value(forAttribute:NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            return ReaderFiles.QueryItem(path:url.path,isDirectory:item.value(forAttribute:NSMetadataItemContentTypeKey) as? String == "public.folder",
                                         modified:item.value(forAttribute:NSMetadataItemFSContentChangeDateKey) as? Date,
                                         size:(item.value(forAttribute:NSMetadataItemFSSizeKey) as? NSNumber)?.intValue ?? 0,
                                         downloaded:status != NSMetadataUbiquitousItemDownloadingStatusNotDownloaded)
        }
    }
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds:300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private struct Loaded: Sendable {
        let index: VaultIndex
        let modules: [PageModule]
        let components: [String:ComponentInstance]
        let remote: Set<String>
    }
    /// Rescans the folder. A newer rescan makes an older one's result irrelevant.
    func reload() async {
        guard let root else { return }
        let request = UUID(); reloadID = request
        let items = queryItems()
        let loaded: Loaded = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async { continuation.resume(returning:Self.load(root:root,query:items)) }
        }
        guard reloadID == request else { return }
        var files: [String:VaultEntry] = [:], folders: [String:VaultEntry] = [:]
        func walk(_ entries: [VaultEntry]) {
            for entry in entries { if entry.isDirectory { folders[entry.relativePath] = entry; walk(entry.children ?? []) } else { files[entry.relativePath] = entry } }
        }
        walk(loaded.index.entries)
        self.files = files; self.folders = folders
        index = loaded.index; modules = loaded.modules; components = loaded.components; remote = loaded.remote
        changeTick += 1
        readTexts(loaded.index)
    }
    /// Nothing here is on the main thread, because iCloud can make any read wait.
    nonisolated private static func load(root: URL, query: [ReaderFiles.QueryItem]) -> Loaded {
        let scan = ReaderFiles.scan(root:root,query:query)
        // The two files that shape the lists must be local before they are read.
        for name in [PageOrganizer.orderFileName,ModuleStore.fileName] where scan.rootConfig.contains(name) {
            _ = try? ReaderFiles.coordinatedRead(root.appendingPathComponent(name),timeout:5) { _ in }
        }
        let index = VaultIndex(root:root,listing:scan.listing)
        let hasModuleFile = scan.rootConfig.contains(ModuleStore.fileName)
        let modules = hasModuleFile ? ModuleStore.load(root:index.root)
            : index.entries.filter(\.isDirectory).enumerated().map { ModuleStore.suggested(for:$1.name,position:$0) }
        var components: [String:ComponentInstance] = [:]
        for file in index.files where file.ext == ComponentStore.fileExtension {
            if let instance = try? ReaderFiles.coordinatedRead(file.url,timeout:5,{ ComponentStore.read($0) }) { components[file.relativePath] = instance }
        }
        return Loaded(index:index,modules:modules,components:components,remote:scan.remote)
    }

    /// Reads page text for search and card notes. Pages not yet on the device
    /// are requested from iCloud and picked up by a later rescan.
    private func readTexts(_ index: VaultIndex) {
        let request = UUID(); textPassID = request
        // NSString is immutable, so handing these to the reader is safe.
        nonisolated(unsafe) let previous = foldedTexts
        let previousNotes = notes, previousStamps = stamps
        struct Pass: @unchecked Sendable { var folded: [String:NSString] = [:]; var notes: [String:String] = [:]; var stamps: [String:FileStamp] = [:] }
        DispatchQueue.global(qos:.utility).async {
            var pass = Pass()
            for file in index.files where (file.ext == "md" || file.ext == "markdown") && file.size < 2_000_000 {
                let stamp = FileStamp(file)
                if let folded = previous[file.id], previousStamps[file.id] == stamp {
                    pass.folded[file.id] = folded; pass.notes[file.id] = previousNotes[file.id]; pass.stamps[file.id] = stamp; continue
                }
                guard ReaderFiles.isLocal(file.url) else { ReaderFiles.startDownloading(file.url); continue }
                guard let text = try? ReaderFiles.coordinatedRead(file.url,timeout:3,{ try VaultFileIO.readMarkdown(at:$0) }) else { continue }
                pass.folded[file.id] = Self.searchFold(text) as NSString; pass.notes[file.id] = ComponentStore.cardNote(text); pass.stamps[file.id] = stamp
            }
            let finished = pass
            DispatchQueue.main.async {
                guard self.textPassID == request else { return }
                self.foldedTexts = finished.folded; self.notes = finished.notes; self.stamps = finished.stamps
            }
        }
    }

    func file(_ path: String) -> VaultEntry? { files[path] }
    func folder(_ path: String) -> VaultEntry? { folders[path] }
    /// Modules whose folder exists, in the Mac launcher's order.
    var presentModules: [PageModule] { modules.filter { folders[$0.folder] != nil } }
    /// Folders a Card Index shows instead of the sidebar, as on the Mac.
    var hiddenSources: Set<String> { Set(components.values.filter(\.hideSource).map(\.source)) }
    func visible(_ entries: [VaultEntry]) -> [VaultEntry] {
        let hidden = hiddenSources
        return entries.filter { !hidden.contains($0.relativePath) }
    }
    func module(containing path: String) -> PageModule? { modules.filter { $0.contains(path) }.max { $0.folder.count < $1.folder.count } }
    func pageCount(_ module: PageModule) -> Int {
        let prefix = module.folder + "/"
        return (index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && (module.kind == .attachments ? MediaKinds.isMedia($0.ext) : $0.ext == "md") }.count
    }

    nonisolated static func searchFold(_ text: String) -> String { text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil) }
    /// Same rule as the Mac: inside a module when one is open, otherwise
    /// everywhere but hidden modules; a match in the path or the text counts.
    func search(_ text: String, inModule module: String?) -> [VaultEntry] {
        guard let index, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        let folded = Self.searchFold(text), scope = module.map { $0 + "/" }, hidden = modules.filter(\.hidden).map { $0.folder + "/" }
        return index.files.filter { file in
            if let scope { guard file.relativePath.hasPrefix(scope) else { return false } }
            else if hidden.contains(where:{ file.relativePath.hasPrefix($0) }) { return false }
            return Self.searchFold(file.relativePath).contains(folded) || (foldedTexts[file.id]?.range(of:folded,options:.literal).location ?? NSNotFound) != NSNotFound
        }
    }
    /// The page a link points at, or nil when it does not resolve to one file.
    func resolve(_ target: String, from path: String) -> VaultEntry? {
        guard let index, let url = index.resolve(target,from:path) else { return nil }
        return index.files.first { $0.url == url }
    }
}

enum Route: Hashable {
    case folder(String)
    case file(String,fragment: String)
    var isFolder: Bool { if case .folder = self { return true }; return false }
}

/// Folders live in one column and pages in another on iPad; on iPhone the two
/// lists join into one stack, so a size change keeps the place.
@MainActor final class ReaderRouter: ObservableObject {
    @Published var sidebar: [Route] = []
    @Published var detail: [Route] = []
    var compactPath: [Route] {
        get { sidebar + detail }
        set {
            let folders = newValue.prefix { $0.isFolder }
            sidebar = Array(folders); detail = Array(newValue.dropFirst(folders.count))
        }
    }
    /// A file chosen from a list replaces what the page column showed.
    func openFromList(_ path: String) { detail = [.file(path,fragment:"")] }
    /// A link followed from a page goes on top of it.
    func push(_ path: String, fragment: String) { detail.append(.file(path,fragment:fragment)) }
}
