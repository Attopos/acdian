import SwiftUI
import AppKit
import Combine

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var nsAppearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named:.aqua); case .dark: return NSAppearance(named:.darkAqua) } }
}
/// The two ACdian icon colourings. Pink with a black mark is the bundle's own icon.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case pink, black
    var id: String { rawValue }
    var title: String { switch self { case .pink: return "粉底黑字"; case .black: return "黑底粉字" } }
    static func stored() -> AppIconStyle { AppIconStyle(rawValue:UserDefaults.standard.string(forKey:"appIconStyle") ?? "") ?? .pink }
    /// Swaps the Dock icon of the running app, and gives the installed bundle a
    /// matching Finder icon so the Dock and Finder keep it while the app is closed.
    func apply(toBundle: Bool = true) {
        guard NSApp != nil else { return }
        if let url = Bundle.main.url(forResource:self == .pink ? "AppIcon-Pink" : "AppIcon-Black",withExtension:"png"), let image = NSImage(contentsOf:url) { NSApp.applicationIconImage = image }
        guard toBundle else { return }
        let bundle = Bundle.main.bundleURL
        let customIcon = FileManager.default.fileExists(atPath:bundle.appendingPathComponent("Icon\r").path)
        if self == .black, !customIcon, let url = Bundle.main.url(forResource:"AppIcon-Black",withExtension:"icns"), let image = NSImage(contentsOf:url) {
            NSWorkspace.shared.setIcon(image,forFile:bundle.path,options:[])
        } else if self == .pink, customIcon {
            NSWorkspace.shared.setIcon(nil,forFile:bundle.path,options:[])
        }
    }
}
/// Where a sidebar drag would land, shown while hovering a row.
enum SidebarDrop: Equatable { case before, after, into }
struct SidebarDropHighlight: Equatable { let path: String; let place: SidebarDrop }
/// The sidebar's drop highlight, observed only by row indicators.
@MainActor final class SidebarDragState: ObservableObject { @Published var highlight: SidebarDropHighlight? }
struct EditorInsertion: Equatable { let id = UUID(); let text: String }
struct EditorSnapshot {
    let text: String
    let currentPath: String
    var selectionAnchor: Int? = nil
    var selectionHead: Int? = nil
    var scrollPosition: Int? = nil
    var scrollOffset: Double? = nil
}
/// Where the reader was in a page: the selection, and the scroll place as the
/// document position of the top line with that line's offset from the view top.
struct EditorViewState: Equatable {
    var anchor: Int
    var head: Int
    var scrollPosition: Int
    var scrollOffset: Double
}
extension String {
    /// Byte-for-byte equality. `==` compares canonical equivalence, which for a
    /// long page with non-ASCII text costs milliseconds on every keystroke.
    func sameBytes(_ other: String) -> Bool {
        let fast = utf8.withContiguousStorageIfAvailable { a in
            other.utf8.withContiguousStorageIfAvailable { b in a.count == b.count && (a.isEmpty || memcmp(a.baseAddress!,b.baseAddress!,a.count) == 0) }
        }
        if case let same?? = fast { return same }
        return utf8.elementsEqual(other.utf8)
    }
}
/// One open page in the tab bar. A new page has no path until its first save.
struct PageTab: Identifiable { let id = UUID(); var path: String? }

@MainActor final class AppModel: ObservableObject {
    @Published var index: VaultIndex? { didSet { indexGeneration &+= 1 } }
    private var indexGeneration = 0
    @Published var loading = false {
        didSet { if oldValue && !loading { scheduleAutosave() } }
    }
    private var loadID = UUID()
    private var searchID = UUID()
    private var openID = UUID()
    private var accessURLs: [URL] = []
    private var trashTimer: Timer?
    private var autosaveTask: Task<Void,Never>?
    private let autosaveDelay: TimeInterval
    private var lastAutosaveError: String?
    private let trashNow: () -> Date
    private let pagesRootOverride: URL?
    private var pageStorageRoot: URL?
    @Published var selected: VaultEntry? {
        didSet { if oldValue?.relativePath != selected?.relativePath { cancelAutosave() } }
    }
    @Published var editorDocumentID = UUID() {
        didSet { if oldValue != editorDocumentID { cancelAutosave() } }
    }
    @Published var text = "" {
        didSet { if !oldValue.sameBytes(text) { textFacts = nil; scheduleAutosave() } }
    }
    @Published var originalText = ""
    @Published private(set) var isDraft = false
    @Published var draftTitle = "" {
        didSet { if oldValue != draftTitle && isDraft { scheduleAutosave() } }
    }
    // Keep the live draft's identity and body stable across its first save so
    // WebKit focus, composition and CodeMirror history are never reset.
    private var draftFile: VaultEntry?
    private var savedDraftContent: String?
    var persistedPage: VaultEntry? { isDraft ? draftFile : selected }
    var currentPagePath: String? { persistedPage?.relativePath }
    // Open pages, like browser tabs. The active tab holds the page in the editor,
    // and stays active behind the trash view so a relaunch returns to it.
    @Published private(set) var tabs: [PageTab] = [] {
        didSet { tabMemory = tabMemory.filter { id,_ in tabs.contains { $0.id == id } }; saveTabs() }
    }
    @Published private(set) var activeTabID: UUID? = nil { didSet { saveTabs() } }
    // What a tab keeps while another one is in front: the page text as last
    // read from or written to disk, with the file stamp seen before reading it,
    // so the tab comes back without waiting for the disk; and where the reader was.
    private struct TabMemory { var text: String?; var stamp: FileStamp?; var view: EditorViewState?; var pdfPage: Int?; var facts: TextFacts? }
    private var tabMemory: [UUID:TabMemory] = [:]
    /// Where the reader was in the front tab, for an editor starting that page afresh.
    var frontTabView: EditorViewState? { activeTabID.flatMap { tabMemory[$0]?.view } }
    @Published var query = ""
    // Modules: top-level folders shown as tiles in the launcher. The active
    // module scopes the sidebar, search and new pages to its folder.
    @Published private(set) var modules: [PageModule] = []
    @Published var activeModuleID: String? {
        didSet { if oldValue != activeModuleID, index != nil { preferences.set(activeModuleID,forKey:activeModuleKey) } }
    }
    @Published private(set) var folderStateRevision = 0
    // Attachments dropped from a page wait a little before going to the trash,
    // so an undo or a paste into another page keeps them.
    private var pendingCleanup: [String:Date] = [:]
    private var cleanupTimer: Timer?
    private let attachmentCleanupDelay: TimeInterval
    private var draftFolder = ""
    @Published var showOutline = true
    @Published var showSidebar = true
    @Published var showingTrash = false { didSet { if showingTrash { showingMarket = false } } }
    /// The component market fills the main area, like the trash.
    @Published var showingMarket = false { didSet { if showingMarket { showingTrash = false } } }
    @Published private(set) var trashEntries: [PageTrash.Entry] = []
    @Published var error: String?
    private let preferences: UserDefaults
    @Published var appearance: AppAppearance = AppAppearance(rawValue:UserDefaults.standard.string(forKey:"appAppearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue,forKey:"appAppearance"); NSApp?.appearance = appearance.nsAppearance }
    }
    @Published var iconStyle: AppIconStyle = AppIconStyle.stored() {
        didSet { UserDefaults.standard.set(iconStyle.rawValue,forKey:"appIconStyle"); iconStyle.apply() }
    }
    @Published var language: AppLanguage = .english {
        didSet { preferences.set(language.rawValue,forKey:"appLanguage") }
    }
    @Published private var statusValue: AppStatus = .ready
    var status: String {
        get { statusValue.localized(language) }
        set { statusValue = .path(newValue) }
    }
    @Published var insertion: EditorInsertion?
    // Every request counts, so asking for the same heading again still scrolls.
    @Published var anchor = "" { didSet { anchorRequest &+= 1 } }
    @Published private(set) var anchorRequest = 0
    /// The outline entry for the part of the page being read: -1 is the page title.
    @Published var activeHeading = -1
    @Published var pdfPage = 1 {
        didSet { if selected?.ext == "pdf", let tab = activeTabID { tabMemory[tab,default:TabMemory()].pdfPage = pdfPage } }
    }
    @Published var pdfZoomAction = 0
    @Published var pdfPageCount = 0
    @Published var fontSize: Double = UserDefaults.standard.double(forKey: "readingFontSize") == 0 ? 16 : UserDefaults.standard.double(forKey: "readingFontSize")
    private var searchCache: [String:String] = [:] { didSet { searchRevision &+= 1 } }
    // The same texts case- and accent-folded once, so each search is a plain
    // byte search; and the last result, which a longer query only narrows.
    private var searchFolded: [String:NSString] = [:]
    private var searchRevision = 0
    private var matchMemo: (scope: String, query: String, result: [VaultEntry])?
    private var foldedPaths: (generation: Int, paths: [String:String]) = (-1,[:])
    // The stamp each cached text was read at, so a rebuild reads only files that
    // changed, and the pages saved while a rebuild is still reading.
    private var searchStamps: [String:FileStamp] = [:]
    private var searchSaves: [String:String] = [:]
    // The live WebKit editor supplies an immediate document snapshot before a
    // native action, even when its normal change message is still in flight.
    var editorSnapshot: ((@escaping (Result<EditorSnapshot, Error>) -> Void) -> Void)?
    var editorFocus: (() -> Void)?
    // CodeMirror positions use UTF-16 in the newline-normalized document.
    var editorSelection: (anchor: Int, head: Int)?
    var pendingEditorSelection: (anchor: Int, head: Int)?
    var dirty: Bool {
        guard selected?.ext == "md" else { return false }
        if isDraft {
            if let savedDraftContent { return !draftContent.sameBytes(savedDraftContent) }
            return !draftTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !text.isEmpty
        }
        return !text.sameBytes(originalText)
    }
    var markdownCount: Int { index?.files.filter { $0.ext == "md" }.count ?? 0 }
    var imageCount: Int { index?.files.filter { Self.images.contains($0.ext) }.count ?? 0 }
    var pdfCount: Int { index?.files.filter { $0.ext == "pdf" }.count ?? 0 }
    static let images = MediaKinds.images
    static let videos = MediaKinds.videos
    // The outline and character count are worked out once per text, not on every view update.
    // Each tab keeps them for its text, so returning to a long page skips the work.
    private struct TextFacts { let text: String; let headings: [(level: Int,title: String)]; let count: Int }
    private var textFacts: TextFacts?
    private var facts: TextFacts {
        if let textFacts { return textFacts }
        let tab = activeTabID
        if let tab, let kept = tabMemory[tab]?.facts, kept.text.sameBytes(text) { textFacts = kept; return kept }
        let facts = TextFacts(text:text,headings:Self.headings(in:text),count:text.count); textFacts = facts
        if let tab, tabMemory[tab] != nil { tabMemory[tab]?.facts = facts }
        return facts
    }
    var wordCount: Int { facts.count }
    func localized(_ source: String, _ arguments: CVarArg...) -> String { language.localized(source,arguments:arguments) }
    func localizedError(_ error: Error) -> String {
        if let error = error as? VaultCoreError {
            switch error {
            case .notDirectory(let url): return localized("无法打开页面文件夹：%@",url.lastPathComponent)
            case .invalidUTF8(let url): return localized("“%@”不是 UTF-8 文本，无法安全编辑。",url.lastPathComponent)
            case .conflict(let url): return localized("“%@”已被其他应用修改。请重新载入后再保存，避免覆盖外部修改。",url.lastPathComponent)
            case .unsafeLocation(let url): return localized("“%@”指向页面存储位置以外，已停止读取或保存。",url.lastPathComponent)
            case .invalidMove(let url): return localized("无法把“%@”移动到它自己里面。",url.lastPathComponent)
            case .nameTaken(let url): return localized("已经有名为“%@”的项目，请换一个名称。",url.lastPathComponent)
            }
        }
        return localized(error.localizedDescription)
    }
    nonisolated static func searchFold(_ text: String) -> String { text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil) }
    var matches: [VaultEntry] {
        guard let index, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let folded = Self.searchFold(query)
        let scope = activeModule.map { $0.folder + "/" }, hidden = hiddenFolders
        let scopeKey = "\(scope ?? "")|\(hidden.joined(separator:"\n"))|\(indexGeneration)|\(searchRevision)"
        var candidates: [VaultEntry]
        if let memo = matchMemo, memo.scope == scopeKey, folded.hasPrefix(memo.query) {
            if memo.query == folded { return memo.result }
            candidates = memo.result
        } else {
            candidates = index.files.filter { file in
                if let scope { return file.relativePath.hasPrefix(scope) }
                return !hidden.contains(where: { file.relativePath.hasPrefix($0 + "/") })
            }
        }
        if foldedPaths.generation != indexGeneration {
            foldedPaths = (indexGeneration,Dictionary(index.files.map { ($0.id,Self.searchFold($0.relativePath)) },uniquingKeysWith: { first,_ in first }))
        }
        let paths = foldedPaths.paths
        let result = candidates.filter { file in
            (paths[file.id] ?? Self.searchFold(file.relativePath)).contains(folded) || (searchFolded[file.id].map { $0.range(of:folded,options:.literal).location != NSNotFound } ?? false)
        }
        matchMemo = (scopeKey,folded,result)
        return result
    }
    var headings: [(level: Int,title: String)] { facts.headings }
    private static func headings(in text: String) -> [(level: Int,title: String)] {
        var inFence = false
        return text.components(separatedBy: .newlines).compactMap { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); return nil }
            guard !inFence else { return nil }
            let n = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(n), line.count > n, line[line.index(line.startIndex,offsetBy:n)] == " " else { return nil }
            return (n, String(line.dropFirst(n+1)).trimmingCharacters(in: .whitespaces))
        }
    }
    init(loadInitialVault: Bool = true, preferences: UserDefaults = .standard, pagesRoot: URL? = nil, trashNow: @escaping () -> Date = Date.init, autosaveDelay: TimeInterval = 0.5, attachmentCleanupDelay: TimeInterval = 10) {
        self.preferences = preferences
        self.attachmentCleanupDelay = max(0,attachmentCleanupDelay)
        self.trashNow = trashNow
        self.autosaveDelay = max(0.01,autosaveDelay)
        let args = CommandLine.arguments
        let argumentRoot: URL?
        if let i = args.firstIndex(of:"--pages-root"), args.count > i+1 { argumentRoot = URL(fileURLWithPath:args[i+1]) }
        else { argumentRoot = nil }
        self.pagesRootOverride = pagesRoot ?? argumentRoot
        self.language = AppLanguage.stored(in:preferences)
        guard loadInitialVault else { return }
        do { loadPages(try resolvePageStorage()) }
        catch { self.error = localizedError(error) }
    }
    private func resolvePageStorage() throws -> URL {
        if let pageStorageRoot { return pageStorageRoot }
        let location = try PagesStorage.resolve(preferences:preferences,override:pagesRootOverride)
        pageStorageRoot = location.root
        if let scope = location.securityScopedURL { accessURLs.append(scope) }
        return location.root
    }
    @discardableResult func ensurePageStorage() -> Bool {
        // A synchronous Cmd+N must supersede an unfinished startup scan without
        // allowing its later completion to clear the newly installed draft.
        loadID = UUID(); loading = false
        if index != nil { return true }
        do {
            let newIndex = try VaultIndex(root:resolvePageStorage())
            index = newIndex; loadModules(); rebuildSearch(); statusValue = .openedPages(newIndex.files.count)
            refreshTrash(); restoreTabs(openActive:false)
            return true
        } catch { self.error = localizedError(error); return false }
    }
    func loadPages(_ url: URL) {
        pageStorageRoot = url
        let request = UUID(); loadID = request; openID = UUID(); loading = true; statusValue = .readingPages
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let newIndex = try VaultIndex(root:url)
                DispatchQueue.main.async {
                    guard self.loadID == request else { return }
                    self.index = newIndex; self.selected = nil; self.text = ""; self.originalText = ""; self.clearDraftState(); self.query = ""; self.insertion = nil; self.loading = false; self.editorDocumentID = UUID()
                    self.showingTrash = false; self.showingMarket = false; self.loadModules(); self.rebuildSearch(); self.statusValue = .openedPages(newIndex.files.count)
                    self.refreshTrash(); self.restoreTabs(openActive:true)
                }
            } catch { DispatchQueue.main.async { guard self.loadID == request else { return }; self.loading = false; self.error = self.localizedError(error) } }
        }
    }
    deinit { trashTimer?.invalidate(); cleanupTimer?.invalidate(); autosaveTask?.cancel() }

    private func cancelAutosave() {
        autosaveTask?.cancel(); autosaveTask = nil
    }
    private func scheduleAutosave() {
        cancelAutosave()
        guard selected?.ext == "md", !loading else { return }
        guard dirty else {
            statusValue = isDraft && draftFile == nil ? .ready : .saved(Date())
            return
        }
        statusValue = .saving
        let documentID = editorDocumentID, path = selected?.relativePath, root = index?.root
        let delay = UInt64(autosaveDelay * 1_000_000_000)
        autosaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds:delay) } catch { return }
            guard let self, !Task.isCancelled, !self.loading,
                  self.editorDocumentID == documentID, self.selected?.relativePath == path, self.index?.root == root else { return }
            self.autosaveTask = nil
            // Bridge changes already contain committed editor state. Reading a
            // second asynchronous snapshot here could race with newer typing.
            self.save(automatically:true)
        }
    }
    private func reportSaveFailure(_ failure: Error, automatically: Bool) {
        let message = localizedError(failure)
        statusValue = .saveFailed
        if !automatically || lastAutosaveError != message { error = message }
        lastAutosaveError = message
    }

    @discardableResult func refreshTrash() -> Bool {
        guard let root = index?.root ?? pageStorageRoot else { return true }
        do {
            let trash = try PageTrash(root:root,nowDate:trashNow)
            try trash.purgeExpired()
            trashEntries = try trash.entries()
            scheduleTrashCleanup()
            return true
        } catch {
            self.error = localizedError(error)
            scheduleTrashCleanup(retrying:true)
            return false
        }
    }
    private func scheduleTrashCleanup(retrying: Bool = false) {
        trashTimer?.invalidate(); trashTimer = nil
        guard retrying || !trashEntries.isEmpty else { return }
        // Shorter checks also refresh remaining-day labels and recover after
        // clock changes; the earliest expiry still gets its own exact deadline.
        let next = trashEntries.map(\.expiresAt).min() ?? trashNow()
        let interval = retrying ? 60 : min(3600,max(0.1,next.timeIntervalSince(trashNow())))
        trashTimer = Timer.scheduledTimer(withTimeInterval:interval,repeats:false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTrash() }
        }
    }
    func showTrash() {
        guard ensurePageStorage() else { return }
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving() else { return }
            self.clearOpenDocument(); self.showingTrash = true
            self.refreshTrash(); self.statusValue = .ready
        }
    }
    private func clearOpenDocument() {
        openID = UUID(); selected = nil; text = ""; originalText = ""; clearDraftState()
        insertion = nil; anchor = ""; loading = false; pdfPage = 1; pdfPageCount = 0; editorDocumentID = UUID()
    }
    func delete(_ entry: VaultEntry, completion: ((Bool) -> Void)? = nil) {
        guard let root = index?.root else { completion?(false); return }
        let affectsSelection = deletionAffectsSelection(entry)
        let action = {
            guard self.index?.root == root else { completion?(false); return }
            if affectsSelection, !self.saveBeforeLeaving() { completion?(false); return }
            do {
                let trash = try PageTrash(root:root,nowDate:self.trashNow)
                try trash.moveToTrash(relativePath:entry.relativePath)
                // Cancel directory scans and pending opens of the moved path.
                self.loadID = UUID(); self.openID = UUID(); self.loading = false
                let activeIndex = self.tabs.firstIndex(where: { $0.id == self.activeTabID })
                self.tabs.removeAll { tab in (affectsSelection && tab.id == self.activeTabID) || tab.path.map { $0 == entry.relativePath || $0.hasPrefix(entry.relativePath + "/") } == true }
                if !self.tabs.contains(where: { $0.id == self.activeTabID }) { self.activeTabID = nil }
                if affectsSelection { self.clearOpenDocument() }
                // The sidebar drops the item at once; a rescan off the main
                // thread then catches aliases that pointed into it.
                self.index = self.index?.removing(entry.relativePath)
                self.rescanInBackground(root)
                if affectsSelection, let activeIndex { self.selectTab(near:activeIndex) }
                self.refreshTrash(); self.statusValue = .trashed
                completion?(true)
            } catch { self.error = self.localizedError(error); completion?(false) }
        }
        if affectsSelection { withEditorSnapshot(action,onFailure:{ completion?(false) }) }
        else { action() }
    }
    @discardableResult func restoreFromTrash(_ entry: PageTrash.Entry) -> Bool {
        guard let root = index?.root ?? pageStorageRoot else { return false }
        do {
            let trash = try PageTrash(root:root,nowDate:trashNow)
            try trash.restore(entry.id)
            loadID = UUID(); openID = UUID(); loading = false
            reindexAfterTrashMutation(root)
            refreshTrash(); statusValue = .restored
            return true
        } catch { self.error = localizedError(error); refreshTrash(); return false }
    }
    private func reindexAfterTrashMutation(_ root: URL) {
        do { index = try VaultIndex(root:root); rebuildSearch() }
        catch { self.error = localizedError(error) }
    }
    /// Rescans the pages folder off the main thread. An index set meanwhile is newer and wins.
    private func rescanInBackground(_ root: URL) {
        let generation = indexGeneration
        DispatchQueue.global(qos:.utility).async {
            guard let rescanned = try? VaultIndex(root:root) else { return }
            DispatchQueue.main.async {
                guard self.indexGeneration == generation, self.index?.root == root else { return }
                self.index = rescanned; self.rebuildSearch()
            }
        }
    }
    private func deletionAffectsSelection(_ entry: VaultEntry) -> Bool {
        guard let selected = persistedPage else { return false }
        if selected.relativePath == entry.relativePath || (entry.isDirectory && selected.relativePath.hasPrefix(entry.relativePath + "/")) { return true }
        // A separately listed file alias can still be displaying a document
        // inside the folder being removed. Deleting an alias itself only moves
        // that alias, so it does not affect another open path to the same file.
        guard (try? entry.url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        let target = entry.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.precomposedStringWithCanonicalMapping }
        let current = selected.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.precomposedStringWithCanonicalMapping }
        return current == target || (entry.isDirectory && current.count > target.count && Array(current.prefix(target.count)) == target)
    }
    /// The sidebar item whose name is being edited in place.
    @Published var renamingPath: String? { didSet { if renamingPath != nil { renamingSession = UUID() } } }
    /// A fresh name field for every edit, even one reusing a path.
    private(set) var renamingSession = UUID()
    /// Creates a folder inside `entry` when it is a folder, or next to it when
    /// it is a file, right below it, and starts editing its name.
    @discardableResult func newFolder(near entry: VaultEntry) -> String? {
        guard let root = index?.root else { return nil }
        let parent = entry.isDirectory ? entry.relativePath : (entry.relativePath as NSString).deletingLastPathComponent
        do {
            let path = try PageOrganizer(root:root).createFolder(localized("新建文件夹"),in:parent,after:entry.isDirectory ? nil : entry.name)
            if !parent.isEmpty { setFolderExpanded(parent,true) }
            if index?.root == root { index = index?.addingFolder(path) }
            query = ""; renamingPath = path
            return path
        } catch { self.error = localizedError(error); return nil }
    }
    func startRenaming(_ entry: VaultEntry) { renamingPath = entry.relativePath }
    /// The part of a name the sidebar edits: pages without their .md ending.
    static func editableName(_ entry: VaultEntry) -> String {
        !entry.isDirectory && ["md",ComponentStore.fileExtension].contains(entry.ext) ? (entry.name as NSString).deletingPathExtension : entry.name
    }
    /// Ends editing a name. `nil` keeps the current name. The open page is
    /// saved first when it moves, and stays open at its new path.
    func finishRenaming(_ path: String, to typed: String?) {
        guard renamingPath == path else { return }
        renamingPath = nil
        guard let typed, let root = index?.root, let entry = index.flatMap({ Self.entry(path,in:$0.entries) }) else { return }
        var name = typed.trimmingCharacters(in:.whitespacesAndNewlines)
        guard name != Self.editableName(entry) else { return }
        // Pages and components keep their ending; only the name before it is edited.
        let ending = !entry.isDirectory && ["md",ComponentStore.fileExtension].contains(entry.ext) ? "." + entry.ext : ""
        let page = !ending.isEmpty
        if page, name.lowercased().hasSuffix(ending) { name = String(name.dropLast(ending.count)).trimmingCharacters(in:.whitespaces) }
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.utf8.count <= 250 else {
            error = localized("请输入有效的名称，不包含 / 或 :。"); return
        }
        if page { name += ending }
        let affectsSelection = deletionAffectsSelection(entry)
        let openPath = persistedPage?.relativePath
        let action = {
            guard self.index?.root == root else { return }
            if affectsSelection, !self.saveBeforeLeaving() { return }
            do {
                let newPath = try PageOrganizer(root:root).rename(path,to:name)
                if entry.isDirectory { self.moveFolderStates(from:path,to:newPath); self.moduleFolderMoved(from:path,to:newPath); self.componentSourcesMoved(from:path,to:newPath) }
                self.remapTabs(from:path,to:newPath)
                // The renamed paths are updated in memory; a rescan off the
                // main thread then catches anything else that changed.
                guard let newIndex = self.index?.renaming(path,to:newPath) else { return }
                self.index = newIndex; self.rebuildSearch(); self.rescanInBackground(root)
                if affectsSelection, let openPath, openPath == path || openPath.hasPrefix(path + "/"),
                   let file = newIndex.files.first(where: { $0.relativePath == newPath + openPath.dropFirst(path.count) }) {
                    self.open(file,skipConfirmation:true)
                }
            } catch { self.error = self.localizedError(error) }
        }
        if affectsSelection { withEditorSnapshot(action) } else { action() }
    }
    /// Moves a sidebar item, or reorders it within its folder. Unsaved edits are
    /// saved first when the open page moves, and it stays open at its new path.
    // One drop highlight for the whole sidebar, so a finished or cancelled drag
    // can never leave a stale insertion line on some other row.
    // The highlight lives in its own small object: a drag updates it on every
    // mouse move, and only the rows' indicators should redraw, not the window.
    let drag = SidebarDragState()
    var sidebarDrop: SidebarDropHighlight? { drag.highlight }
    var draggingPath: String?
    func setSidebarDrop(_ highlight: SidebarDropHighlight?) { if drag.highlight != highlight { drag.highlight = highlight } }
    func movePage(_ relativePath: String, to target: PageDropTarget) {
        setSidebarDrop(nil); draggingPath = nil
        guard let root = index?.root, let entry = index.flatMap({ Self.entry(relativePath, in: $0.entries) }) else { return }
        let affectsSelection = deletionAffectsSelection(entry)
        let openPath = persistedPage?.relativePath
        let action = {
            guard self.index?.root == root else { return }
            if affectsSelection, !self.saveBeforeLeaving() { return }
            let request = UUID(); self.loadID = request
            // The move runs off the main thread. The sidebar then updates in
            // memory at once, and a rescan in the background confirms it.
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try PageOrganizer(root:root).move(relativePath,to:target) }
                DispatchQueue.main.async {
                    guard self.index?.root == root, let current = self.index else { return }
                    switch result {
                    case .success(let newPath):
                        let newIndex = current.moving(relativePath,to:newPath)
                        if self.loadID == request { self.loading = false }
                        if entry.isDirectory { self.moveFolderStates(from:relativePath,to:newPath); self.moduleFolderMoved(from:relativePath,to:newPath); self.componentSourcesMoved(from:relativePath,to:newPath) }
                        self.remapTabs(from:relativePath,to:newPath)
                        self.index = newIndex; self.rebuildSearch(); self.rescanInBackground(root)
                        if affectsSelection, let openPath, newPath != relativePath {
                            let moved = openPath == relativePath ? newPath : newPath + openPath.dropFirst(relativePath.count)
                            if let file = newIndex.files.first(where: { $0.relativePath == moved }) { self.open(file,skipConfirmation:true) }
                        }
                    case .failure(let error): self.error = self.localizedError(error)
                    }
                }
            }
        }
        if affectsSelection { withEditorSnapshot(action) } else { action() }
    }
    // Sidebar folders remember being opened or closed, per pages folder.
    private var folderStateKey: String { "expandedFolders:" + (index?.root.path ?? "") }
    func folderExpanded(_ path: String) -> Bool? { (preferences.dictionary(forKey:folderStateKey) as? [String:Bool])?[path] }
    func setFolderExpanded(_ path: String, _ expanded: Bool) {
        var states = preferences.dictionary(forKey:folderStateKey) as? [String:Bool] ?? [:]
        states[path] = expanded; preferences.set(states,forKey:folderStateKey)
        folderStateRevision &+= 1
    }
    private func moveFolderStates(from old: String, to new: String) {
        guard old != new, var states = preferences.dictionary(forKey:folderStateKey) as? [String:Bool] else { return }
        for key in states.keys where key == old || key.hasPrefix(old + "/") { states[new + key.dropFirst(old.count)] = states.removeValue(forKey:key) }
        preferences.set(states,forKey:folderStateKey)
    }
    static func entry(_ path: String, in entries: [VaultEntry]) -> VaultEntry? {
        for entry in entries {
            if entry.relativePath == path { return entry }
            if entry.isDirectory, path.hasPrefix(entry.relativePath + "/"), let found = Self.entry(path, in: entry.children ?? []) { return found }
        }
        return nil
    }
    func trashDaysRemaining(_ entry: PageTrash.Entry) -> Int {
        max(0,Int(ceil(entry.expiresAt.timeIntervalSince(trashNow()) / 86400)))
    }
    /// Reads page text for search. Files whose stamp in the new index matches the
    /// one their cached text was read at are not read again, and results reach
    /// the sidebar in batches rather than one update per file.
    func rebuildSearch() {
        let request = UUID(); searchID = request; searchSaves = [:]
        guard let index else { searchCache = [:]; searchFolded = [:]; searchStamps = [:]; return }
        let previous = searchCache, previousStamps = searchStamps
        // Read-only here; NSString is immutable, so sharing it with the reader is safe.
        nonisolated(unsafe) let previousFolded = searchFolded
        DispatchQueue.global(qos:.utility).async {
            var cache: [String:String] = [:], folded: [String:NSString] = [:], stamps: [String:FileStamp] = [:]
            var batch: [String:String] = [:], foldedBatch: [String:NSString] = [:]
            func publish(_ texts: [String:String], _ foldedTexts: [String:NSString]) {
                DispatchQueue.main.async {
                    guard self.searchID == request else { return }
                    self.searchFolded.merge(foldedTexts) { _,new in new }
                    self.searchCache.merge(texts) { _,new in new }; self.objectWillChange.send()
                }
            }
            for file in index.files where file.ext == "md" && file.size < 2_000_000 {
                let stamp = FileStamp(file)
                if let text = previous[file.id], previousStamps[file.id] == stamp {
                    cache[file.id] = text; folded[file.id] = previousFolded[file.id] ?? Self.searchFold(text) as NSString; stamps[file.id] = stamp; continue
                }
                guard let value = try? VaultFileIO.readMarkdown(at:file.url,allowedRoot:index.root) else { continue }
                let foldedValue = Self.searchFold(value) as NSString
                cache[file.id] = value; folded[file.id] = foldedValue; stamps[file.id] = stamp; batch[file.id] = value; foldedBatch[file.id] = foldedValue
                // Large batches: each one redraws the sidebar.
                if batch.count >= 1000 { publish(batch,foldedBatch); batch = [:]; foldedBatch = [:] }
            }
            DispatchQueue.main.async {
                guard self.searchID == request else { return }
                // Pages saved meanwhile keep their newer text, to be read again next time.
                for (id,text) in self.searchSaves { cache[id] = text; folded[id] = Self.searchFold(text) as NSString; stamps[id] = nil }
                self.searchFolded = folded
                self.searchCache = cache; self.searchStamps = stamps; self.searchSaves = [:]; self.objectWillChange.send()
            }
        }
    }
    private func searchSaved(_ id: String, _ text: String) {
        searchFolded[id] = Self.searchFold(text) as NSString
        searchCache[id] = text; searchStamps[id] = nil; searchSaves[id] = text
    }
    func refresh() {
        guard ensurePageStorage(), let root = index?.root else { return }
        let request = UUID(); loadID = request; loading = true
        DispatchQueue.global(qos:.userInitiated).async {
            do { let refreshed = try VaultIndex(root:root); DispatchQueue.main.async { guard self.loadID == request else { return }; self.index = refreshed; self.rebuildSearch(); self.loading = false; self.statusValue = .refreshed; self.refreshTrash() } }
            catch { DispatchQueue.main.async { guard self.loadID == request else { return }; self.loading = false; self.error = self.localizedError(error) } }
        }
    }
    @discardableResult func saveBeforeLeaving() -> Bool {
        cancelAutosave()
        return !dirty || save()
    }
    func withEditorSnapshot(_ action: @escaping () -> Void, onFailure: (() -> Void)? = nil) {
        guard selected?.ext == "md", let requestSnapshot = editorSnapshot else { action(); return }
        let expectedPath = selected?.relativePath
        let expectedRoot = index?.root
        let expectedDocumentID = editorDocumentID
        let expectedOpenID = openID
        let expectedLoadID = loadID
        var finished = false
        func finish(_ result: Result<EditorSnapshot, Error>) {
            guard !finished else { return }; finished = true
            guard self.selected?.relativePath == expectedPath, self.index?.root == expectedRoot,
                  self.editorDocumentID == expectedDocumentID,
                  self.openID == expectedOpenID, self.loadID == expectedLoadID else { onFailure?(); return }
            switch result {
            case .success(let snapshot):
                guard snapshot.currentPath == expectedPath else {
                    self.error = self.localized("编辑器仍在切换笔记，请稍后重试。"); onFailure?(); return
                }
                if !self.text.sameBytes(snapshot.text) { self.text = snapshot.text }
                if let anchor = snapshot.selectionAnchor, let head = snapshot.selectionHead {
                    let length = Self.editorUTF16Count(snapshot.text)
                    self.editorSelection = (max(0,min(anchor,length)),max(0,min(head,length)))
                    if let position = snapshot.scrollPosition, let offset = snapshot.scrollOffset, let selection = self.editorSelection {
                        self.rememberView(EditorViewState(anchor:selection.anchor,head:selection.head,scrollPosition:max(0,min(position,length)),scrollOffset:offset))
                    }
                } else { self.editorSelection = nil }
                action()
            case .failure(let error):
                let nativeError = error as NSError
                if nativeError.domain == NSURLErrorDomain && nativeError.code == URLError.cancelled.rawValue {
                    onFailure?(); return
                }
                self.error = self.localized("无法读取编辑器中的最新内容，已取消操作。\n%@",self.localizedError(error))
                onFailure?()
            }
        }
        requestSnapshot { result in
            if Thread.isMainThread { MainActor.assumeIsolated { finish(result) } }
            else { DispatchQueue.main.async { finish(result) } }
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 8) {
            guard !finished else { return }
            finish(.failure(NSError(domain:"acdian.editor",code:1,userInfo:[NSLocalizedDescriptionKey:"编辑器响应超时，请稍后重试。"])))
        }
    }
    func saveFromEditor() { withEditorSnapshot { self.save() } }
    /// Opens a page in its tab. A page whose tab still holds its text shows at
    /// once, and the file is checked in the background; `fromDisk` always reads it.
    func open(_ entry: VaultEntry, fragment: String = "", skipConfirmation: Bool = false, fromDisk: Bool = false, inPlace: Bool = false) {
        guard !entry.isDirectory, entry.relativePath != currentPagePath || skipConfirmation else { return }
        openID = UUID()
        if skipConfirmation { openAfterSnapshot(entry,fragment:fragment,skipConfirmation:true,fromDisk:fromDisk,inPlace:inPlace) }
        else { withEditorSnapshot { self.openAfterSnapshot(entry,fragment:fragment,skipConfirmation:false,fromDisk:fromDisk,inPlace:inPlace) } }
    }
    private func openAfterSnapshot(_ entry: VaultEntry, fragment: String, skipConfirmation: Bool, fromDisk: Bool, inPlace: Bool = false) {
        guard skipConfirmation || saveBeforeLeaving() else { return }
        showingTrash = false; showingMarket = false
        // A page already in a tab is shown there, and a blank new page hands
        // its tab to the page opened from it; anything else gets a new tab.
        let tab = tabs.first(where: { $0.path == entry.relativePath })?.id ?? (isDraft && draftFile == nil || inPlace ? activeTabID : nil)
        let needsText = entry.ext == "md" || ["txt","json","csv","css","js","yaml","yml","canvas","xml","html","log"].contains(entry.ext)
        let request = UUID(); openID = request
        let root = index?.root
        if !needsText { install(entry,content:"",fragment:fragment,tab:tab); return }
        guard entry.size < 20_000_000 else { error = localized("文件较大，无法作为文本打开。"); return }
        if !fromDisk, let tab, tabs.contains(where: { $0.id == tab && $0.path == entry.relativePath }), let kept = tabMemory[tab]?.text {
            install(entry,content:kept,fragment:fragment,tab:tab)
            verifyKeptText(entry,tab:tab,text:kept)
            return
        }
        loading = true; statusValue = .opening(entry.name)
        // Cloud storage can take time to download a note. Never block the window.
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                // The stamp is taken first, so a change made during the read
                // still differs from it when the tab is next checked.
                let stamp = FileStamp(of:entry.url)
                let content = try VaultFileIO.readMarkdown(at:entry.url,allowedRoot:root)
                DispatchQueue.main.async {
                    guard self.openID == request else { return }
                    self.install(entry,content:content,fragment:fragment,tab:tab)
                    self.keepFrontText(content,stamp:stamp)
                }
            } catch { DispatchQueue.main.async { guard self.openID == request else { return }; self.loading = false; self.error = self.localizedError(error) } }
        }
    }
    private func install(_ entry: VaultEntry, content: String, fragment: String, tab: UUID?) {
        showInTab(tab,path:entry.relativePath)
        followModule(to:entry.relativePath)
        selected = entry; text = content; originalText = content; clearDraftState(); anchor = fragment
        pdfPage = fragment.hasPrefix("page=") ? (Int(fragment.dropFirst(5)) ?? 1) : (activeTabID.flatMap { tabMemory[$0]?.pdfPage } ?? 1)
        pdfPageCount = 0; insertion = nil; loading = false; status = entry.relativePath; editorDocumentID = UUID()
    }
    private func keepFrontText(_ text: String, stamp: FileStamp?) {
        guard let tab = activeTabID else { return }
        tabMemory[tab,default:TabMemory()].text = text; tabMemory[tab]?.stamp = stamp
    }
    /// Checks a tab shown from kept text against the file. If it changed while
    /// the tab was in the back, the page shows the file's text instead, unless
    /// it was already edited here; saving those edits then reports the conflict.
    private func verifyKeptText(_ entry: VaultEntry, tab: UUID, text kept: String) {
        let stamp = tabMemory[tab]?.stamp, documentID = editorDocumentID, root = index?.root
        DispatchQueue.global(qos:.utility).async {
            let current = FileStamp(of:entry.url)
            if let stamp, current == stamp { return }
            guard let disk = try? VaultFileIO.readMarkdown(at:entry.url,allowedRoot:root) else { return }
            DispatchQueue.main.async {
                guard self.tabMemory[tab]?.text?.sameBytes(kept) == true else { return }
                self.tabMemory[tab]?.text = disk; self.tabMemory[tab]?.stamp = current
                guard !disk.sameBytes(kept), self.editorDocumentID == documentID, self.activeTabID == tab,
                      self.selected?.relativePath == entry.relativePath, !self.dirty else { return }
                self.originalText = disk; self.text = disk; self.status = entry.relativePath; self.editorDocumentID = UUID()
            }
        }
    }
    private func rememberView(_ view: EditorViewState) {
        guard !isDraft, let tab = activeTabID, tabMemory[tab]?.view != view else { return }
        tabMemory[tab,default:TabMemory()].view = view; saveTabViews()
    }
    func goHome() {
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving() else { return }
            self.clearOpenDocument(); self.showingTrash = false; self.showingMarket = false; self.statusValue = .ready
            self.activeModuleID = nil; self.query = ""
        }
    }
    // Tabs are remembered per pages folder, so a relaunch reopens them.
    private var tabsKey: String { "openTabs:" + (index?.root.path ?? "") }
    private var activeTabKey: String { "activeTab:" + (index?.root.path ?? "") }
    // Each tab's last selection and scroll place, so a relaunch returns to them.
    private var tabViewsKey: String { "tabViews:" + (index?.root.path ?? "") }
    private func saveTabs() {
        guard index != nil else { return }
        preferences.set(tabs.compactMap(\.path),forKey:tabsKey)
        preferences.set(tabs.first(where: { $0.id == activeTabID })?.path,forKey:activeTabKey)
        saveTabViews()
    }
    private func saveTabViews() {
        guard index != nil else { return }
        var views: [String:[Double]] = [:]
        for tab in tabs { if let path = tab.path, let view = tabMemory[tab.id]?.view { views[path] = [Double(view.anchor),Double(view.head),Double(view.scrollPosition),view.scrollOffset] } }
        if views.isEmpty { preferences.removeObject(forKey:tabViewsKey) } else { preferences.set(views,forKey:tabViewsKey) }
    }
    private func restoreTabs(openActive: Bool) {
        guard let index else { return }
        let files = Set(index.files.map(\.relativePath)), active = preferences.string(forKey:activeTabKey)
        let views = preferences.dictionary(forKey:tabViewsKey) as? [String:[Double]] ?? [:]
        var seen = Set<String>()
        tabs = (preferences.stringArray(forKey:tabsKey) ?? []).filter { files.contains($0) && seen.insert($0).inserted }.map { PageTab(path:$0) }
        for tab in tabs {
            guard let path = tab.path, let view = views[path], view.count == 4, view.allSatisfy({ $0.isFinite && abs($0) < 1e12 }) else { continue }
            tabMemory[tab.id] = TabMemory(view:EditorViewState(anchor:max(0,Int(view[0])),head:max(0,Int(view[1])),scrollPosition:max(0,Int(view[2])),scrollOffset:view[3]))
        }
        saveTabViews()
        if openActive, let tab = tabs.first(where: { $0.path == active }) ?? tabs.last { selectTab(tab.id) }
    }
    private func showInTab(_ id: UUID?, path: String?) {
        guard let id, let i = tabs.firstIndex(where: { $0.id == id }) else { let tab = PageTab(path:path); tabs.append(tab); activeTabID = tab.id; return }
        // A tab that now shows another page forgets the old page's text and place.
        if tabs[i].path != path { tabs[i].path = path; if path != nil { tabMemory[id] = nil } }
        if activeTabID != id { activeTabID = id }
    }
    private func remapTabs(from old: String, to new: String) {
        guard old != new, tabs.contains(where: { $0.path == old || $0.path?.hasPrefix(old + "/") == true }) else { return }
        tabs = tabs.map { tab in
            var tab = tab
            if let path = tab.path, path == old || path.hasPrefix(old + "/") { tab.path = new + path.dropFirst(old.count) }
            return tab
        }
    }
    func tabTitle(_ tab: PageTab) -> String {
        if tab.id == activeTabID, isDraft {
            let title = draftTitle.trimmingCharacters(in:.whitespacesAndNewlines)
            return title.isEmpty ? "New Page" : title
        }
        guard let path = tab.path else { return "New Page" }
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") || name.hasSuffix("." + ComponentStore.fileExtension) ? (name as NSString).deletingPathExtension : name
    }
    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID || selected == nil else { return }
        guard let path = tab.path else { newPageFromEditor(inTab:id); return }
        guard let entry = index?.files.first(where: { $0.relativePath == path }) else { closeTab(id); return }
        open(entry)
    }
    private func selectTab(near i: Int) {
        guard !tabs.isEmpty else { return }
        selectTab(tabs[min(i,tabs.count-1)].id)
    }
    /// Closing the front tab saves it first, then shows the tab to its right, or else its left.
    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard id == activeTabID, selected != nil else { tabs.remove(at:i); return }
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving(), let i = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.tabs.remove(at:i); self.activeTabID = nil
            self.clearOpenDocument(); self.statusValue = .ready
            self.selectTab(near:i)
        }
    }
    /// Command-W closes the front tab, and the window once no page is open.
    func closeCurrentTab() {
        if let activeTabID, selected != nil { closeTab(activeTabID) }
        else { NSApp?.mainWindow?.performClose(nil) }
    }
    @discardableResult func save(automatically: Bool = false) -> Bool {
        cancelAutosave()
        if isDraft { return saveDraft(automatically:automatically) }
        guard let selected, selected.ext == "md", dirty else { return true }
        do {
            try VaultFileIO.saveMarkdown(text,at:selected.url,expectedContent:originalText,allowedRoot:index?.root)
            attachmentsChanged(from:originalText,to:text,page:selected.relativePath)
            originalText = text; searchSaved(selected.id,text); keepFrontText(text,stamp:nil); statusValue = .saved(Date()); lastAutosaveError = nil; return true
        } catch { reportSaveFailure(error,automatically:automatically); return false }
    }
    func reload() {
        guard persistedPage != nil else { return }
        withEditorSnapshot { self.reloadAfterSnapshot() }
    }
    private func reloadAfterSnapshot() {
        guard let selected = persistedPage else { return }
        cancelAutosave()
        if dirty {
            let alert = NSAlert(); alert.messageText = localized("放弃本地修改并重新载入？"); alert.informativeText = localized("未保存的修改将丢失，重新读取磁盘中的最新文件。")
            alert.addButton(withTitle:localized("重新载入")); alert.addButton(withTitle:localized("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { scheduleAutosave(); return }
        }
        open(selected,skipConfirmation:true,fromDisk:true)
    }
    func navigate(_ raw: String) {
        if raw.hasPrefix("#") { anchor = String(raw.dropFirst()); return }
        guard let index, let url = index.resolve(raw, from:selected?.relativePath ?? ""), let entry = index.files.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { error = localized("找不到链接的文件：%@\n请检查文件路径；同名文件请使用完整路径。",raw); return }
        let fragment = raw.components(separatedBy:"#").dropFirst().joined(separator:"#")
        // A link opens in the current tab, unless its page already has one.
        open(entry,fragment:fragment.removingPercentEncoding ?? fragment,inPlace:true)
        if currentPagePath == entry.relativePath {
            anchor = fragment.removingPercentEncoding ?? fragment
            if fragment.hasPrefix("page="), let n = Int(fragment.dropFirst(5).prefix(while: {$0.isNumber})) { pdfPage = max(1,n) }
        }
    }
    func external(_ raw: String) {
        guard let url = URL(string:raw), ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func newPageFromEditor(inTab reused: UUID? = nil, completion: (() -> Void)? = nil) {
        guard ensurePageStorage() else { return }
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving(), let root = self.index?.root else { return }
            let tab = reused ?? (self.isDraft && self.draftFile == nil ? self.activeTabID : nil)
            self.clearDraftState()
            self.draftFolder = self.activeModule?.kind == .pages ? self.activeModule!.folder : ""
            let path = ".acdian-draft-\(UUID().uuidString).md"
            self.openID = UUID(); self.loadID = UUID()
            self.selected = VaultEntry(relativePath:path,url:root.appendingPathComponent(path),name:"New Page",isDirectory:false,children:nil,modified:nil,size:0)
            self.editorSelection = nil; self.pendingEditorSelection = nil
            self.isDraft = true; self.draftTitle = ""; self.text = ""; self.originalText = ""
            self.showingTrash = false; self.showingMarket = false
            self.anchor = ""; self.insertion = nil; self.pdfPage = 1; self.pdfPageCount = 0; self.loading = false
            self.editorDocumentID = UUID(); self.statusValue = .ready
            self.showInTab(tab,path:nil)
            completion?()
        }
    }
    /// The sidebar entry for a file just created at the top of the pages folder.
    private static func createdEntry(_ filename: String, at url: URL, root: URL) -> VaultEntry {
        let stamp = FileStamp(of:url)
        return VaultEntry(relativePath:filename,url:root.appendingPathComponent(filename),name:(filename as NSString).lastPathComponent,isDirectory:false,children:nil,modified:stamp?.modified ?? Date(),size:stamp?.size ?? 0)
    }
    private func clearDraftState() {
        cancelAutosave(); isDraft = false; draftTitle = ""; draftFile = nil; savedDraftContent = nil
        editorSelection = nil; pendingEditorSelection = nil; lastAutosaveError = nil
    }
    private static func editorUTF16Count(_ text: String) -> Int {
        // A CRLF pair is one newline in the editor; a lone CR is one too.
        var pairs = 0, previous: UInt8 = 0
        for byte in text.utf8 { if byte == 10 && previous == 13 { pairs += 1 }; previous = byte }
        return text.utf16.count - pairs
    }
    private static func draftFilenameBase(_ title: String) -> String {
        let reserved = CharacterSet(charactersIn:"/\\:?*\"<>|").union(.controlCharacters)
        var base = title.components(separatedBy:reserved).joined(separator:" ").split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
        base = base.trimmingCharacters(in:CharacterSet(charactersIn:". "))
        if base.lowercased().hasSuffix(".md") { base = String(base.dropLast(3)).trimmingCharacters(in:CharacterSet(charactersIn:". ")) }
        while base.utf8.count > 220 { base.removeLast() }
        return base.isEmpty ? "New Page" : base
    }
    private var draftContent: String {
        let title = draftTitle.components(separatedBy:.controlCharacters).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        return "# \(title.isEmpty ? "New Page" : title)\n\n" + text
    }
    private func saveDraft(automatically: Bool) -> Bool {
        guard let root = index?.root, selected?.ext == "md" else { return false }
        let content = draftContent
        do {
            let file: VaultEntry
            if let existing = draftFile {
                if content != savedDraftContent {
                    try VaultFileIO.saveMarkdown(content,at:existing.url,expectedContent:savedDraftContent,allowedRoot:root)
                }
                file = existing
            } else {
                let cleanTitle = draftTitle.components(separatedBy:.controlCharacters).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
                let base = Self.draftFilenameBase(cleanTitle), fm = FileManager.default
                // A page started inside a module is saved in its folder, if it still exists.
                var isFolder: ObjCBool = false
                let folder = !draftFolder.isEmpty && fm.fileExists(atPath:root.appendingPathComponent(draftFolder).path,isDirectory:&isFolder) && isFolder.boolValue ? draftFolder + "/" : ""
                var number = 1
                while true {
                    let filename = folder + base + (number == 1 ? "" : " \(number)") + ".md"
                    let url = root.appendingPathComponent(filename)
                    if fm.fileExists(atPath:url.path) || (try? fm.destinationOfSymbolicLink(atPath:url.path)) != nil { number += 1; continue }
                    do { try VaultFileIO.saveMarkdown(content,at:url,expectedContent:nil,allowedRoot:root) }
                    catch VaultCoreError.conflict { number += 1; continue }
                    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { number += 1; continue }
                    // Only the backing file changes. The current editor keeps
                    // its body, title, selection, history and bridge identity.
                    file = Self.createdEntry(filename,at:url,root:root)
                    if let index, index.root == root { self.index = index.addingFile(file) }
                    break
                }
            }
            attachmentsChanged(from:savedDraftContent ?? "",to:content,page:file.relativePath)
            draftFile = file; savedDraftContent = content; originalText = text
            if let i = tabs.firstIndex(where: { $0.id == activeTabID }), tabs[i].path != file.relativePath { tabs[i].path = file.relativePath }
            searchSaved(file.id,content); keepFrontText(content,stamp:nil); statusValue = .saved(Date()); lastAutosaveError = nil
            return true
        } catch { reportSaveFailure(error,automatically:automatically); return false }
    }
    @discardableResult func newNote(_ name: String) -> Bool {
        guard let root = index?.root, saveBeforeLeaving() else { return false }
        let clean = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix(".") else { error = localized("请输入有效的页面名称，不包含 / 或 :。"); return false }
        let filename = clean.lowercased().hasSuffix(".md") ? clean : clean + ".md"
        let url = root.appendingPathComponent(filename)
        do {
            let content = "# \(String(filename.dropLast(3)))\n\n"
            try VaultFileIO.saveMarkdown(content,at:url,expectedContent:nil,allowedRoot:root)
            let file = Self.createdEntry(filename,at:url,root:root)
            index = index?.addingTopLevelFile(file); searchSaved(file.id,content)
            open(file,skipConfirmation:true)
            return true
        } catch { self.error = self.localizedError(error); return false }
    }
    func newNoteFromEditor(_ name: String, completion: @escaping (Bool) -> Void) {
        withEditorSnapshot({ completion(self.newNote(name)) }, onFailure:{ completion(false) })
    }
    func importAttachment() {
        guard let root = index?.root, selected?.ext == "md" else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.message = localized("附件会复制到页面的 Attachments 文件夹，并插入链接。")
        guard panel.runModal() == .OK else { return }
        do {
            let folder = attachmentsFolder
            let directory = root.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard directory.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw NSError(domain:"acdian",code:2,userInfo:[NSLocalizedDescriptionKey:"附件目录指向页面存储范围以外，无法导入。"]) }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var links: [String] = []
            for source in panel.urls {
                var dest = directory.appendingPathComponent(source.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath:dest.path) { dest = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(n).\(source.pathExtension)"); n += 1 }
                try FileManager.default.copyItem(at:source,to:dest)
                let embed = Self.images.contains(dest.pathExtension.lowercased()) || dest.pathExtension.lowercased() == "pdf"
                links.append("\(embed ? "!" : "")[[\(folder)/\(dest.lastPathComponent)]]")
            }
            insertion = EditorInsertion(text:"\n" + links.joined(separator:"\n") + "\n"); refresh()
        } catch { self.error = self.localizedError(error) }
    }

    // MARK: Modules
    private var activeModuleKey: String { "activeModule:" + (index?.root.path ?? "") }
    var activeModule: PageModule? { activeModuleID.flatMap { id in modules.first { $0.id == id } } }
    /// Modules whose folder is in the vault; a deleted folder's tile comes back if it is restored.
    var presentModules: [PageModule] {
        guard let index else { return [] }
        return modules.filter { module in Self.entry(module.folder,in:index.entries)?.isDirectory == true }
    }
    var attachmentsFolder: String { modules.first { $0.kind == .attachments }?.folder ?? "Attachments" }
    private var hiddenFolders: [String] { modules.filter(\.hidden).map(\.folder) }
    /// The rows at the top of the sidebar: the active module's contents, or
    /// everything except hidden modules.
    var sidebarEntries: [VaultEntry] {
        guard let index else { return [] }
        if let module = activeModule { return Self.entry(module.folder,in:index.entries)?.children ?? [] }
        let hidden = Set(hiddenFolders)
        return index.entries.filter { !hidden.contains($0.relativePath) }
    }
    func module(containing path: String) -> PageModule? {
        modules.filter { $0.contains(path) }.max { $0.folder.count < $1.folder.count }
    }
    private func loadModules() {
        guard let root = index?.root else { return }
        modules = ModuleStore.load(root:root)
        let stored = preferences.string(forKey:activeModuleKey)
        activeModuleID = modules.contains { $0.id == stored } ? stored : nil
    }
    private func saveModules() {
        guard let root = index?.root else { return }
        do { try ModuleStore.save(modules,root:root) } catch { self.error = localizedError(error) }
    }
    func enterModule(_ id: String?) {
        guard activeModuleID != id else { return }
        activeModuleID = id; query = ""
    }
    /// A page opened from outside the active module brings its own module into the sidebar.
    private func followModule(to path: String) {
        guard let active = activeModule, !active.contains(path) else { return }
        activeModuleID = module(containing:path)?.id
    }
    /// Creates a module over a new top-level folder, or adopts an existing
    /// folder of that name, and opens it.
    @discardableResult func createModule(name typed: String, icon: String, color: String) -> Bool {
        guard ensurePageStorage(), let root = index?.root else { return false }
        let name = typed.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.utf8.count <= 200 else {
            error = localized("请输入有效的名称，不包含 / 或 :。"); return false
        }
        var folder = name
        if let existing = modules.first(where: { $0.folder.compare(name,options:.caseInsensitive) == .orderedSame }) {
            if presentModules.contains(existing) { error = localized("已经有名为“%@”的项目，请换一个名称。",name); return false }
            modules.removeAll { $0 == existing }
        }
        var isDirectory: ObjCBool = false
        if !(FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path,isDirectory:&isDirectory) && isDirectory.boolValue) {
            do {
                folder = try PageOrganizer(root:root).createFolder(name,in:"",after:presentModules.last?.folder)
                index = index?.addingFolder(folder)
            } catch { self.error = localizedError(error); return false }
        }
        modules.append(PageModule(name:name,folder:folder,icon:icon,color:color,kind:ModuleStore.suggested(for:folder).kind))
        saveModules(); enterModule(folder)
        return true
    }
    func updateModule(_ id: String, name: String, icon: String, color: String) {
        guard let i = modules.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if !clean.isEmpty { modules[i].name = clean }
        modules[i].icon = icon; modules[i].color = color
        saveModules()
    }
    func setModuleHidden(_ id: String, _ hidden: Bool) {
        guard let i = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[i].hidden = hidden
        if hidden, activeModuleID == id { activeModuleID = nil }
        saveModules()
    }
    /// Takes a module off the launcher. Its folder and pages stay where they are.
    func removeModule(_ id: String) {
        modules.removeAll { $0.id == id }
        if activeModuleID == id { activeModuleID = nil }
        saveModules()
    }
    func moveModule(_ id: String, before target: String) {
        guard id != target, let from = modules.firstIndex(where: { $0.id == id }) else { return }
        let module = modules.remove(at:from)
        modules.insert(module,at:modules.firstIndex(where: { $0.id == target }) ?? modules.endIndex)
        saveModules()
    }
    private func moduleFolderMoved(from old: String, to new: String) {
        guard old != new, modules.contains(where: { $0.folder == old || $0.folder.hasPrefix(old + "/") }) else { return }
        let wasActive = activeModuleID
        for i in modules.indices where modules[i].folder == old || modules[i].folder.hasPrefix(old + "/") {
            if modules[i].folder == old && modules[i].name == (old as NSString).lastPathComponent { modules[i].name = (new as NSString).lastPathComponent }
            modules[i].folder = new + modules[i].folder.dropFirst(old.count)
        }
        if let wasActive, wasActive == old || wasActive.hasPrefix(old + "/") { activeModuleID = new + wasActive.dropFirst(old.count) }
        saveModules()
    }
    /// Creates a folder at the top of `folder` ("" is the vault root) and starts naming it.
    @discardableResult func newFolder(in folder: String) -> String? {
        guard let root = index?.root else { return nil }
        do {
            let path = try PageOrganizer(root:root).createFolder(localized("新建文件夹"),in:folder)
            if !folder.isEmpty { setFolderExpanded(folder,true) }
            if index?.root == root { index = index?.addingFolder(path) }
            query = ""; renamingPath = path
            return path
        } catch { self.error = localizedError(error); return nil }
    }
    /// Whether a sidebar folder shows its contents. Top rows start open, except attachment folders.
    func isExpanded(_ entry: VaultEntry, depth: Int) -> Bool {
        folderExpanded(entry.relativePath) ?? (depth == 0 && !["attachment","attachments","assets"].contains(entry.name.lowercased()))
    }
    /// Text of the pages read for search, for counting attachment links.
    var searchedPages: [(path: String, text: String)] { searchCache.map { ($0.key,$0.value) } }
    var searchedPageCount: Int { searchCache.count }

    // MARK: Attachment cleanup
    /// After a save: images and videos no longer linked from the page are
    /// queued for the trash, and links typed again to a trashed one bring it back.
    private func attachmentsChanged(from old: String, to new: String, page: String) {
        guard let index, old.contains("[") || new.contains("[") else { return }
        let before = AttachmentReferences.targets(in:old), after = AttachmentReferences.targets(in:new)
        guard before != after else { return }
        let folder = attachmentsFolder
        let removed = AttachmentReferences.media(in:before.subtracting(after),from:page,index:index,folder:folder)
            .subtracting(AttachmentReferences.media(in:after,from:page,index:index,folder:folder))
        let added = after.subtracting(before).filter { index.resolve($0,from:page) == nil }
        if !added.isEmpty { restoreTrashedAttachments(added,folder:folder) }
        guard !removed.isEmpty else { return }
        let due = trashNow().addingTimeInterval(attachmentCleanupDelay)
        for path in removed { pendingCleanup[path] = due }
        scheduleAttachmentCleanup()
    }
    private func scheduleAttachmentCleanup() {
        cleanupTimer?.invalidate(); cleanupTimer = nil
        guard let next = pendingCleanup.values.min() else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval:max(0.01,next.timeIntervalSince(trashNow())),repeats:false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runAttachmentCleanup() }
        }
    }
    /// Moves queued attachments that no page links to any more into the
    /// 15-day trash. Every page on disk and the unsaved editor text are checked.
    func runAttachmentCleanup(completion: (() -> Void)? = nil) {
        let now = trashNow()
        let due = pendingCleanup.filter { $0.value <= now }.map(\.key)
        guard let index, !due.isEmpty else { scheduleAttachmentCleanup(); completion?(); return }
        for path in due { pendingCleanup[path] = nil }
        let folder = attachmentsFolder, root = index.root
        var editing: [(path: String, text: String)] = []
        if selected?.ext == "md" { editing.append((currentPagePath ?? selected!.relativePath,isDraft ? draftContent : text)) }
        DispatchQueue.global(qos:.utility).async {
            let pages = AttachmentReferences.pagesOnDisk(index) + editing
            let unused = due.filter { path in
                FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path)
                    && !AttachmentReferences.isReferenced(path,pages:pages,index:index,folder:folder)
            }
            DispatchQueue.main.async {
                defer { self.scheduleAttachmentCleanup(); completion?() }
                guard self.index?.root == root, !unused.isEmpty else { return }
                do {
                    let trash = try PageTrash(root:root,nowDate:self.trashNow)
                    for path in unused where self.pendingCleanup[path] == nil {
                        try trash.moveToTrash(relativePath:path)
                        self.index = self.index?.removing(path)
                        if let i = self.tabs.firstIndex(where: { $0.path == path }), self.tabs[i].id != self.activeTabID { self.tabs.remove(at:i) }
                    }
                    self.refreshTrash(); self.statusValue = .attachmentsCleaned
                } catch { self.error = self.localizedError(error) }
            }
        }
    }
    /// Restores attachments that went to the trash from the attachments folder
    /// when a link to their file name appears again.
    private func restoreTrashedAttachments(_ targets: Set<String>, folder: String) {
        guard let root = index?.root else { return }
        let names = Set(targets.map { AttachmentReferences.fileName($0).lowercased() }.filter { MediaKinds.isMedia(($0 as NSString).pathExtension) })
        guard !names.isEmpty else { return }
        let candidates = trashEntries.filter { !$0.isDirectory && $0.originalRelativePath.hasPrefix(folder + "/") && names.contains($0.name.lowercased()) }
        var restored = Set<String>()
        do {
            let trash = try PageTrash(root:root,nowDate:trashNow)
            for entry in candidates.sorted(by: { $0.deletedAt > $1.deletedAt }) where restored.insert(entry.name.lowercased()).inserted {
                let url = try trash.restore(entry.id)
                guard let path = AttachmentReferences.relativePath(url,root:root) else { continue }
                pendingCleanup[path] = nil
                let stamp = FileStamp(of:url)
                let file = VaultEntry(relativePath:path,url:url,name:url.lastPathComponent,isDirectory:false,children:nil,modified:stamp?.modified,size:stamp?.size ?? 0)
                index = index?.addingFile(file)
            }
        } catch { self.error = localizedError(error) }
        if !restored.isEmpty { refreshTrash() }
    }

    // MARK: Components
    func showMarket() {
        guard ensurePageStorage() else { return }
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving() else { return }
            self.clearOpenDocument(); self.showingMarket = true; self.statusValue = .ready
        }
    }
    private var componentMemo: (generation: Int, list: [(file: VaultEntry, instance: ComponentInstance)]) = (-1,[])
    /// Every component placed in the pages folder.
    var componentInstances: [(file: VaultEntry, instance: ComponentInstance)] {
        guard let index else { return [] }
        if componentMemo.generation != indexGeneration {
            componentMemo = (indexGeneration,index.files.filter { $0.ext == ComponentStore.fileExtension }.compactMap { file in ComponentStore.read(file.url).map { (file,$0) } })
        }
        return componentMemo.list
    }
    /// Folders that a component shows in place of their own sidebar rows.
    var componentHiddenFolders: Set<String> { Set(componentInstances.filter { $0.instance.hideSource }.map(\.instance.source)) }
    /// Places a component in `folder` ("" is the top level) and opens it.
    @discardableResult func createComponent(_ kind: ComponentKind, name typed: String, in folder: String, source: String, hideSource: Bool) -> Bool {
        guard ensurePageStorage(), let root = index?.root else { return false }
        let name = typed.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.utf8.count <= 200 else {
            error = localized("请输入有效的名称，不包含 / 或 :。"); return false
        }
        do {
            let data = try ComponentStore.encode(ComponentInstance(component:kind,source:source,hideSource:hideSource))
            let directory = folder.isEmpty ? root : root.appendingPathComponent(folder,isDirectory:true)
            var number = 1, path = ""
            while true {
                let filename = PageOrganizer.numberedName(name + "." + ComponentStore.fileExtension,isDirectory:false,number:number)
                let url = directory.appendingPathComponent(filename)
                do { try data.write(to:url,options:.withoutOverwriting); path = folder.isEmpty ? filename : folder + "/" + filename; break }
                catch let error as CocoaError where error.code == .fileWriteFileExists { number += 1 }
            }
            let url = root.appendingPathComponent(path), stamp = FileStamp(of:url)
            let file = VaultEntry(relativePath:path,url:url,name:url.lastPathComponent,isDirectory:false,children:nil,modified:stamp?.modified,size:stamp?.size ?? 0)
            index = index?.addingFile(file)
            if !folder.isEmpty { setFolderExpanded(folder,true) }
            open(file,skipConfirmation:true)
            return true
        } catch { self.error = localizedError(error); return false }
    }
    /// Saves a component's settings back to its file.
    func updateComponent(_ file: VaultEntry, _ instance: ComponentInstance) {
        guard let root = index?.root, let data = try? ComponentStore.encode(instance) else { return }
        do { try VaultFileIO.checkedWrite(data,to:file.url,allowedRoot:root); componentMemo = (-1,[]) }
        catch { self.error = localizedError(error) }
    }
    /// Components keep showing their folder after it is renamed or moved.
    private func componentSourcesMoved(from old: String, to new: String) {
        guard old != new else { return }
        for (file,instance) in componentInstances where instance.source == old || instance.source.hasPrefix(old + "/") {
            var updated = instance
            updated.source = new + instance.source.dropFirst(old.count)
            // The component file itself may have moved with the folder.
            let path = file.relativePath == old || file.relativePath.hasPrefix(old + "/") ? new + file.relativePath.dropFirst(old.count) : file.relativePath
            guard let root = index?.root, let data = try? ComponentStore.encode(updated) else { continue }
            try? data.write(to:root.appendingPathComponent(path),options:.atomic)
        }
        componentMemo = (-1,[])
    }

    // MARK: Importing files
    /// Copies files or folders from outside into `target.folder`, next to its
    /// anchor when there is one. Names already in use get a number; nothing is
    /// overwritten. The copy and the rescan run off the main thread.
    func importFiles(_ urls: [URL], to target: PageDropTarget) {
        guard let root = index?.root, !urls.isEmpty else { return }
        let destination = target.folder.isEmpty ? root : root.appendingPathComponent(target.folder,isDirectory:true)
        let request = UUID(); loadID = request; loading = true
        DispatchQueue.global(qos:.userInitiated).async {
            let fm = FileManager.default
            var copied: [String] = [], failure: Error?
            for source in urls {
                let from = source.standardizedFileURL.resolvingSymlinksInPath()
                // A folder cannot be copied into itself.
                if VaultIndex.contains(destination.resolvingSymlinksInPath(),in:from) || destination.resolvingSymlinksInPath() == from { continue }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath:from.path,isDirectory:&isDirectory) else { continue }
                var number = 1
                while true {
                    let name = PageOrganizer.numberedName(from.lastPathComponent,isDirectory:isDirectory.boolValue,number:number)
                    do { try fm.copyItem(at:from,to:destination.appendingPathComponent(name)); copied.append(name); break }
                    catch let error as CocoaError where error.code == .fileWriteFileExists { number += 1 }
                    catch { failure = error; break }
                }
            }
            if !copied.isEmpty {
                let organizer = PageOrganizer(root:root)
                var order = PageOrganizer.loadOrder(root:root)
                var names = organizer.currentOrder(of:target.folder,order:order).filter { !copied.contains($0) }
                let at = target.anchor.flatMap { names.firstIndex(of:$0) }.map { target.after ? $0 + 1 : $0 } ?? names.count
                names.insert(contentsOf:copied,at:at)
                order[target.folder] = names
                try? organizer.saveOrder(order)
            }
            let newIndex = try? VaultIndex(root:root)
            DispatchQueue.main.async {
                if self.loadID == request { self.loading = false }
                guard self.index?.root == root else { return }
                if let newIndex { self.index = newIndex; self.rebuildSearch() }
                if !target.folder.isEmpty, !copied.isEmpty { self.setFolderExpanded(target.folder,true) }
                if let failure { self.error = self.localizedError(failure) }
                else if !copied.isEmpty { self.statusValue = .imported(copied.count) }
            }
        }
    }

    // MARK: Per-scan caches
    private var memoStore: (generation: Int, values: [String:Any]) = (-1,[:])
    /// A value worked out from the index once per scan, so views can ask for it on every redraw.
    func memo<T>(_ key: String, _ make: () -> T) -> T {
        if memoStore.generation != indexGeneration { memoStore = (indexGeneration,[:]) }
        if let value = memoStore.values[key] as? T { return value }
        let value = make(); memoStore.values[key] = value
        return value
    }
}
