import SwiftUI
import Network

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
    /// Goes up whenever more page text is in the search cache.
    @Published private(set) var textsRevision = 0
    /// Pages read for search so far, while the search index is being built.
    @Published private(set) var indexing: (done: Int, total: Int)?
    let language = AppLanguage.forDevice

    private var files: [String:VaultEntry] = [:]
    private var folders: [String:VaultEntry] = [:]
    private var counts: [String:(pages: Int, media: Int)] = [:]
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var publishedAnything = false
    /// One rescan at a time, in order; the query's own work happens on another queue.
    nonisolated private let work = DispatchQueue(label:"acdian.reader.index",qos:.userInitiated)
    nonisolated private let texts = DispatchQueue(label:"acdian.reader.texts",qos:.utility)
    nonisolated private let pending = PendingItems()
    /// The derived page cache: titles, card notes and full text, in SQLite.
    private(set) var db: PageDB?
    /// The last listing read from the disk, which query changes are added to.
    nonisolated(unsafe) private var diskScan: ReaderFiles.Scan?
    /// Set once the whole folder has been listed; only then may the cache drop pages.
    nonisolated(unsafe) private var listed = false

    func localized(_ source: String, _ arguments: CVarArg...) -> String { language.localized(source,arguments:arguments) }

    /// Shows what was known last time straight away, then catches up with iCloud.
    func start() {
        guard root == nil else { return }
        DispatchQueue.global(qos:.userInitiated).async {
            let found = ReaderFiles.pagesRoot()
            DispatchQueue.main.async {
                PerfLog.mark("pages root found (iCloud \(found.iCloud))")
                self.root = found.root; self.usesICloud = found.iCloud
                self.db = PageDB(root:found.root)
                PerfLog.mark("page cache open: \(self.db?.count ?? 0) pages, full text \(self.db?.fullText ?? false)")
                let root = found.root, iCloud = found.iCloud
                self.work.async {
                    // The saved snapshot, or else just the top-level folders, is enough for the launcher.
                    if let snapshot = IndexSnapshot.load(root:root) {
                        // Early query batches are partial: until the folder has been listed
                        // they only add to the snapshot, never replace it.
                        self.diskScan = snapshot.scan
                        let loaded = Self.load(root:root,scan:snapshot.scan)
                        DispatchQueue.main.async { if !self.publishedAnything { self.publish(loaded,final:false,note:"from snapshot") } }
                    } else {
                        let loaded = Self.load(root:root,scan:ReaderFiles.scanTopLevel(root:root))
                        DispatchQueue.main.async { if !self.publishedAnything { self.publish(loaded,final:false,note:"top level only") } }
                    }
                    // Then the whole folder, listed in one pass with its attributes prefetched.
                    self.rescanDisk(root:root)
                }
                if iCloud { self.startQuery() }
            }
        }
    }
    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value:true)
        query.notificationBatchingInterval = 1
        // Results are read on the query's own queue, never on the main thread.
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        query.operationQueue = queue
        let root = root!
        for name in [NSNotification.Name.NSMetadataQueryGatheringProgress,.NSMetadataQueryDidFinishGathering,.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:query,queue:queue) { [weak self] note in
                guard let self, let query = note.object as? NSMetadataQuery else { return }
                query.disableUpdates()
                let items = Self.items(of:query)
                query.enableUpdates()
                self.submit(items,root:root,final:note.name != .NSMetadataQueryGatheringProgress)
            })
        }
        self.query = query
        PerfLog.mark("query start")
        query.start()
    }
    nonisolated private static func items(of query: NSMetadataQuery) -> [ReaderFiles.QueryItem] {
        (0..<query.resultCount).compactMap { index in
            guard let item = query.result(at:index) as? NSMetadataItem, let url = item.value(forAttribute:NSMetadataItemURLKey) as? URL else { return nil }
            let status = item.value(forAttribute:NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            return ReaderFiles.QueryItem(path:url.path,isDirectory:item.value(forAttribute:NSMetadataItemContentTypeKey) as? String == "public.folder",
                                         modified:item.value(forAttribute:NSMetadataItemFSContentChangeDateKey) as? Date,
                                         size:(item.value(forAttribute:NSMetadataItemFSSizeKey) as? NSNumber)?.intValue ?? 0,
                                         downloaded:status != NSMetadataUbiquitousItemDownloadingStatusNotDownloaded)
        }
    }
    /// Query results arrive in bursts while iCloud gathers; only the newest
    /// batch is turned into an index, at most about once a second.
    nonisolated private func submit(_ items: [ReaderFiles.QueryItem], root: URL, final: Bool) {
        guard pending.put(items,final:final) else { return }
        work.asyncAfter(deadline:.now() + 0.8) { [weak self] in
            guard let self, let (items,final) = self.pending.take() else { return }
            let scan = ReaderFiles.scan(root:root,query:items,walkDisk:false,base:self.diskScan)
            let loaded = Self.load(root:root,scan:scan)
            let complete = self.listed
            if final, complete { IndexSnapshot(scan:scan).save(root:root) }
            DispatchQueue.main.async { self.publish(loaded,final:final && complete,note:"\(items.count) query items") }
        }
    }
    /// Lists the folder on the device directly; the query then adds what iCloud knows beyond it.
    nonisolated private func rescanDisk(root: URL) {
        work.async { [weak self] in
            guard let self else { return }
            let scan = PerfLog.measure("enumerate folder") { ReaderFiles.enumerate(root:root) }
            self.diskScan = scan; self.listed = true
            let loaded = Self.load(root:root,scan:scan)
            IndexSnapshot(scan:scan).save(root:root)
            DispatchQueue.main.async { self.publish(loaded,final:true,note:"disk") }
        }
    }
    /// Rescans the folder: on pull to refresh and when the app comes back.
    func reload() async {
        guard let root else { return }
        if let query, usesICloud {
            let done = await withCheckedContinuation { continuation in
                query.operationQueue?.addOperation {
                    query.disableUpdates(); let items = Self.items(of:query); query.enableUpdates()
                    continuation.resume(returning:items)
                }
            }
            submit(done,root:root,final:true)
        } else { rescanDisk(root:root) }
    }

    private struct Loaded: Sendable {
        let index: VaultIndex
        let modules: [PageModule]
        let components: [String:ComponentInstance]
        let remote: Set<String>
        let counts: [String:(pages: Int, media: Int)]
    }
    private func publish(_ loaded: Loaded, final: Bool, note: String) {
        var files: [String:VaultEntry] = [:], folders: [String:VaultEntry] = [:]
        func walk(_ entries: [VaultEntry]) {
            for entry in entries { if entry.isDirectory { folders[entry.relativePath] = entry; walk(entry.children ?? []) } else { files[entry.relativePath] = entry } }
        }
        walk(loaded.index.entries)
        self.files = files; self.folders = folders; counts = loaded.counts
        index = loaded.index; modules = loaded.modules; components = loaded.components; remote = loaded.remote
        changeTick += 1
        if !publishedAnything { PerfLog.mark("launcher can show (\(note))") }
        publishedAnything = true
        PerfLog.mark("index published: \(loaded.index.files.count) files (\(note))")
        // The cache starts filling from the snapshot at once; pages are only dropped
        // from it once a complete listing says they are gone.
        if final || note == "from snapshot" { readTexts(loaded.index,prune:final) }
    }
    /// Nothing here is on the main thread, because iCloud can make any read wait.
    nonisolated private static func load(root: URL, scan: ReaderFiles.Scan) -> Loaded {
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
        var counts: [String:(pages: Int, media: Int)] = [:]
        for file in index.files {
            guard let slash = file.relativePath.firstIndex(of:"/") else { continue }
            let top = String(file.relativePath[..<slash])
            if file.ext == "md" { counts[top,default:(0,0)].pages += 1 } else if MediaKinds.isMedia(file.ext) { counts[top,default:(0,0)].media += 1 }
        }
        return Loaded(index:index,modules:modules,components:components,remote:scan.remote,counts:counts)
    }

    /// Brings the page cache up to date: only pages whose date or size changed
    /// are read, in batches, and pages that are gone are dropped. Pages not on
    /// the device are asked for and picked up by a later pass.
    private func readTexts(_ index: VaultIndex, prune: Bool) {
        guard let db else { return }
        generation += 1
        let request = generation
        let pages = index.files.filter { ($0.ext == "md" || $0.ext == "markdown") && $0.size < 2_000_000 }
        indexing = (0,pages.count)
        texts.async { [weak self] in
            let known = db.stamps()
            var batch: [PageDB.Row] = [], missing = 0, read = 0, done = 0
            func flush() {
                db.apply(upserts:batch,deletions:[]); batch.removeAll(keepingCapacity:true)
                let progress = done
                DispatchQueue.main.async { if let self, self.generation == request { self.indexing = (progress,pages.count); self.textsRevision += 1 } }
            }
            for file in pages {
                done += 1
                let mtime = file.modified?.timeIntervalSinceReferenceDate ?? 0
                if let old = known[file.relativePath], old.size == file.size, abs(old.mtime - mtime) < 0.001 { continue }
                // Storage is plentiful on the phone: every page is kept downloaded.
                guard ReaderFiles.isLocal(file.url) else { ReaderFiles.startDownloading(file.url); missing += 1; continue }
                guard let data = try? Data(contentsOf:file.url) else { continue }
                let text = VaultDecode.text(data), title = (file.name as NSString).deletingPathExtension
                batch.append(.init(path:file.relativePath,title:Self.searchFold(title),note:ComponentStore.cardNote(text),body:Self.searchFold(text),mtime:mtime,size:file.size))
                read += 1
                if batch.count >= 300 { flush() }
            }
            let present = Set(pages.map(\.relativePath))
            db.apply(upserts:batch,deletions:prune ? known.keys.filter { !present.contains($0) } : [])
            // Pictures and PDFs follow on Wi-Fi; over cellular they load when opened.
            if NetworkWatch.shared.onWiFi { for file in index.files where (MediaKinds.isMedia(file.ext) || file.ext == "pdf") && !ReaderFiles.isLocal(file.url) { ReaderFiles.startDownloading(file.url) } }
            PerfLog.mark("text pass done: \(read) read, \(missing) not on the device yet, \(db.count) in cache")
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.indexing = nil; self.textsRevision += 1
            }
        }
    }
    /// Card notes for the pages under a folder, from the page cache.
    func cardNotes(_ folder: String) -> [String:String] { db?.notes(prefix:folder + "/") ?? [:] }
    nonisolated func cardNotesAsync(_ folder: String) async -> [String:String] {
        let db = await MainActor.run { self.db }
        return db?.notes(prefix:folder + "/") ?? [:]
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
        let count = counts[module.folder] ?? (0,0)
        return module.kind == .attachments ? count.media : count.pages
    }

    nonisolated static func searchFold(_ text: String) -> String { text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil) }
    /// Same rule as the Mac: inside a module when one is open, otherwise
    /// everywhere but hidden modules; a match in the path or the text counts.
    func search(_ text: String, inModule module: String?) -> [VaultEntry] {
        guard let index, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        let folded = Self.searchFold(text.trimmingCharacters(in:.whitespaces)), scope = module.map { $0 + "/" }, hidden = modules.filter(\.hidden).map { $0.folder + "/" }
        func allowed(_ path: String) -> Bool {
            if let scope { return path.hasPrefix(scope) }
            return !hidden.contains(where:{ path.hasPrefix($0) })
        }
        // Paths match from the listing; page text matches from the cache's full-text index.
        let byPath = index.files.filter { allowed($0.relativePath) && Self.searchFold($0.relativePath).contains(folded) }
        let seen = Set(byPath.map(\.relativePath))
        let byText = (db?.search(folded,prefix:scope) ?? []).filter { !seen.contains($0) && allowed($0) }.compactMap { files[$0] }
        return byPath + byText
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

/// The newest query batch waiting to be indexed; whoever finds it waiting takes it.
final class PendingItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ReaderFiles.QueryItem]?
    private var final = false
    /// Returns true when no batch was waiting, so the caller schedules the work.
    func put(_ items: [ReaderFiles.QueryItem], final: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = self.items == nil
        self.items = items; self.final = self.final || final
        return wasEmpty
    }
    func take() -> ([ReaderFiles.QueryItem],Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let items else { return nil }
        let result = (items,final); self.items = nil; final = false
        return result
    }
}

/// The last full listing of the pages folder, saved so the next launch can show it at once.
struct IndexSnapshot: Codable {
    struct Item: Codable { let path: String; let folder: Bool; let modified: Date?; let size: Int }
    var root: String
    var items: [Item]
    var remote: [String]
    var config: [String]
    init(scan: ReaderFiles.Scan) {
        root = ""; items = scan.listing.map { Item(path:$0.relativePath,folder:$0.isDirectory,modified:$0.modified,size:$0.size) }
        remote = Array(scan.remote); config = Array(scan.rootConfig)
    }
    var scan: ReaderFiles.Scan {
        var scan = ReaderFiles.Scan()
        scan.listing = items.map { VaultListing(relativePath:$0.path,isDirectory:$0.folder,modified:$0.modified,size:$0.size) }
        scan.remote = Set(remote); scan.rootConfig = Set(config)
        return scan
    }
    static func file(root: URL, name: String) -> URL {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Reader",isDirectory:true)
        try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
        return support.appendingPathComponent(name)
    }
    static func load(root: URL) -> IndexSnapshot? {
        guard let data = try? Data(contentsOf:file(root:root,name:"index.plist")), let snapshot = try? PropertyListDecoder().decode(IndexSnapshot.self,from:data), snapshot.root == root.path else { return nil }
        return snapshot
    }
    func save(root: URL) {
        var copy = self; copy.root = root.path
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try? encoder.encode(copy).write(to:Self.file(root:root,name:"index.plist"),options:.atomic)
    }
}


/// Whether the phone is on Wi-Fi, for downloading attachments ahead of time.
final class NetworkWatch: @unchecked Sendable {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private(set) var onWiFi = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi) }
        monitor.start(queue:DispatchQueue(label:"acdian.network"))
    }
}
