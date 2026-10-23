import SwiftUI
import AppKit
import Combine

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var nsAppearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named:.aqua); case .dark: return NSAppearance(named:.darkAqua) } }
}
/// Where a sidebar drag would land, shown while hovering a row.
enum SidebarDrop: Equatable { case before, after, into }
struct SidebarDropHighlight: Equatable { let path: String; let place: SidebarDrop }
struct EditorInsertion: Equatable { let id = UUID(); let text: String }
struct EditorSnapshot {
    let text: String
    let currentPath: String
    var selectionAnchor: Int? = nil
    var selectionHead: Int? = nil
}

@MainActor final class AppModel: ObservableObject {
    @Published var index: VaultIndex?
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
        didSet { if oldValue != text { scheduleAutosave() } }
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
    @Published var query = ""
    @Published var showOutline = true
    @Published var showSidebar = true
    @Published var showingTrash = false
    @Published private(set) var trashEntries: [PageTrash.Entry] = []
    @Published var error: String?
    private let preferences: UserDefaults
    @Published var appearance: AppAppearance = AppAppearance(rawValue:UserDefaults.standard.string(forKey:"appAppearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue,forKey:"appAppearance"); NSApp?.appearance = appearance.nsAppearance }
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
    @Published var pdfPage = 1
    @Published var pdfZoomAction = 0
    @Published var pdfPageCount = 0
    @Published var fontSize: Double = UserDefaults.standard.double(forKey: "readingFontSize") == 0 ? 16 : UserDefaults.standard.double(forKey: "readingFontSize")
    private var searchCache: [String:String] = [:]
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
            if let savedDraftContent { return draftContent != savedDraftContent }
            return !draftTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !text.isEmpty
        }
        return text != originalText
    }
    var markdownCount: Int { index?.files.filter { $0.ext == "md" }.count ?? 0 }
    var imageCount: Int { index?.files.filter { Self.images.contains($0.ext) }.count ?? 0 }
    var pdfCount: Int { index?.files.filter { $0.ext == "pdf" }.count ?? 0 }
    static let images = Set(["png","jpg","jpeg","gif","webp","svg","heic","tiff","tif","bmp","avif"])
    var wordCount: Int { text.count }
    func localized(_ source: String, _ arguments: CVarArg...) -> String { language.localized(source,arguments:arguments) }
    func localizedError(_ error: Error) -> String {
        if let error = error as? VaultCoreError {
            switch error {
            case .notDirectory(let url): return localized("无法打开页面文件夹：%@",url.lastPathComponent)
            case .invalidUTF8(let url): return localized("“%@”不是 UTF-8 文本，无法安全编辑。",url.lastPathComponent)
            case .conflict(let url): return localized("“%@”已被其他应用修改。请重新载入后再保存，避免覆盖外部修改。",url.lastPathComponent)
            case .unsafeLocation(let url): return localized("“%@”指向页面存储位置以外，已停止读取或保存。",url.lastPathComponent)
            case .invalidMove(let url): return localized("无法把“%@”移动到它自己里面。",url.lastPathComponent)
            }
        }
        return localized(error.localizedDescription)
    }
    var matches: [VaultEntry] {
        guard let index, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return index.files.filter { $0.relativePath.localizedCaseInsensitiveContains(query) || (searchCache[$0.id]?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    var headings: [(level: Int,title: String)] {
        var inFence = false
        return text.components(separatedBy: .newlines).compactMap { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); return nil }
            guard !inFence else { return nil }
            let n = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(n), line.count > n, line[line.index(line.startIndex,offsetBy:n)] == " " else { return nil }
            return (n, String(line.dropFirst(n+1)).trimmingCharacters(in: .whitespaces))
        }
    }
    init(loadInitialVault: Bool = true, preferences: UserDefaults = .standard, pagesRoot: URL? = nil, trashNow: @escaping () -> Date = Date.init, autosaveDelay: TimeInterval = 0.5) {
        self.preferences = preferences
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
            index = newIndex; rebuildSearch(); statusValue = .openedPages(newIndex.files.count)
            refreshTrash()
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
                    self.showingTrash = false; self.rebuildSearch(); self.statusValue = .openedPages(newIndex.files.count)
                    self.refreshTrash()
                }
            } catch { DispatchQueue.main.async { guard self.loadID == request else { return }; self.loading = false; self.error = self.localizedError(error) } }
        }
    }
    deinit { trashTimer?.invalidate(); autosaveTask?.cancel() }

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
                if affectsSelection { self.clearOpenDocument() }
                self.reindexAfterTrashMutation(root)
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
    /// Moves a sidebar item, or reorders it within its folder. Unsaved edits are
    /// saved first when the open page moves, and it stays open at its new path.
    // One drop highlight for the whole sidebar, so a finished or cancelled drag
    // can never leave a stale insertion line on some other row.
    @Published var sidebarDrop: SidebarDropHighlight?
    var draggingPath: String?
    func setSidebarDrop(_ highlight: SidebarDropHighlight?) { if sidebarDrop != highlight { sidebarDrop = highlight } }
    func movePage(_ relativePath: String, to target: PageDropTarget) {
        setSidebarDrop(nil); draggingPath = nil
        guard let root = index?.root, let entry = index.flatMap({ Self.entry(relativePath, in: $0.entries) }) else { return }
        let affectsSelection = deletionAffectsSelection(entry)
        let openPath = persistedPage?.relativePath
        let action = {
            guard self.index?.root == root else { return }
            if affectsSelection, !self.saveBeforeLeaving() { return }
            let request = UUID(); self.loadID = request
            // The move and the rescan run off the main thread, so the sidebar
            // stays responsive; the new tree replaces the old one in one step.
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { () -> (String,VaultIndex) in
                    let newPath = try PageOrganizer(root:root).move(relativePath,to:target)
                    return (newPath,try VaultIndex(root:root))
                }
                DispatchQueue.main.async {
                    guard self.index?.root == root else { return }
                    switch result {
                    case .success(let (newPath,newIndex)):
                        if self.loadID == request { self.loading = false }
                        if entry.isDirectory { self.moveFolderStates(from:relativePath,to:newPath) }
                        self.index = newIndex; self.rebuildSearch()
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
    func rebuildSearch() {
        let request = UUID(); searchID = request; searchCache = [:]
        guard let index else { return }
        DispatchQueue.global(qos:.utility).async {
            for file in index.files where file.ext == "md" && file.size < 2_000_000 {
                if let value = try? VaultFileIO.readMarkdown(at:file.url,allowedRoot:index.root) {
                    DispatchQueue.main.async { if self.searchID == request { self.searchCache[file.id] = value; self.objectWillChange.send() } }
                }
            }
        }
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
                self.text = snapshot.text
                if let anchor = snapshot.selectionAnchor, let head = snapshot.selectionHead {
                    let length = Self.editorUTF16Count(snapshot.text)
                    self.editorSelection = (max(0,min(anchor,length)),max(0,min(head,length)))
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
    func open(_ entry: VaultEntry, fragment: String = "", skipConfirmation: Bool = false) {
        guard !entry.isDirectory, entry.relativePath != currentPagePath || skipConfirmation else { return }
        openID = UUID()
        if skipConfirmation { openAfterSnapshot(entry,fragment:fragment,skipConfirmation:true) }
        else { withEditorSnapshot { self.openAfterSnapshot(entry,fragment:fragment,skipConfirmation:false) } }
    }
    private func openAfterSnapshot(_ entry: VaultEntry, fragment: String, skipConfirmation: Bool) {
        guard skipConfirmation || saveBeforeLeaving() else { return }
        showingTrash = false
        let needsText = entry.ext == "md" || ["txt","json","csv","css","js","yaml","yml","canvas","xml","html","log"].contains(entry.ext)
        let request = UUID(); openID = request
        let root = index?.root
        func install(_ content: String) {
            selected = entry; text = content; originalText = content; clearDraftState(); anchor = fragment; pdfPage = fragment.hasPrefix("page=") ? (Int(fragment.dropFirst(5)) ?? 1) : 1; pdfPageCount = 0; insertion = nil; loading = false; editorDocumentID = UUID()
            status = entry.relativePath
        }
        if !needsText { install(""); return }
        guard entry.size < 20_000_000 else { error = localized("文件较大，无法作为文本打开。"); return }
        loading = true; statusValue = .opening(entry.name)
        // Cloud storage can take time to download a note. Never block the window.
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let content = try VaultFileIO.readMarkdown(at:entry.url,allowedRoot:root)
                DispatchQueue.main.async {
                    guard self.openID == request else { return }
                    self.selected = entry; self.text = content; self.originalText = content; self.clearDraftState(); self.anchor = fragment; self.pdfPage = fragment.hasPrefix("page=") ? (Int(fragment.dropFirst(5)) ?? 1) : 1; self.pdfPageCount = 0; self.insertion = nil; self.loading = false; self.status = entry.relativePath; self.editorDocumentID = UUID()
                }
            } catch { DispatchQueue.main.async { guard self.openID == request else { return }; self.loading = false; self.error = self.localizedError(error) } }
        }
    }
    func goHome() {
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving() else { return }
            self.clearOpenDocument(); self.showingTrash = false; self.statusValue = .ready
        }
    }
    @discardableResult func save(automatically: Bool = false) -> Bool {
        cancelAutosave()
        if isDraft { return saveDraft(automatically:automatically) }
        guard let selected, selected.ext == "md", dirty else { return true }
        do {
            try VaultFileIO.saveMarkdown(text,at:selected.url,expectedContent:originalText,allowedRoot:index?.root)
            originalText = text; searchCache[selected.id] = text; statusValue = .saved(Date()); lastAutosaveError = nil; return true
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
        open(selected,skipConfirmation:true)
    }
    func navigate(_ raw: String) {
        if raw.hasPrefix("#") { anchor = String(raw.dropFirst()); return }
        guard let index, let url = index.resolve(raw, from:selected?.relativePath ?? ""), let entry = index.files.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { error = localized("找不到链接的文件：%@\n请检查文件路径；同名文件请使用完整路径。",raw); return }
        let fragment = raw.components(separatedBy:"#").dropFirst().joined(separator:"#")
        open(entry,fragment:fragment.removingPercentEncoding ?? fragment)
        if currentPagePath == entry.relativePath {
            anchor = fragment.removingPercentEncoding ?? fragment
            if fragment.hasPrefix("page="), let n = Int(fragment.dropFirst(5).prefix(while: {$0.isNumber})) { pdfPage = max(1,n) }
        }
    }
    func external(_ raw: String) {
        guard let url = URL(string:raw), ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func newPageFromEditor(completion: (() -> Void)? = nil) {
        guard ensurePageStorage() else { return }
        openID = UUID()
        withEditorSnapshot {
            guard self.saveBeforeLeaving(), let root = self.index?.root else { return }
            self.clearDraftState()
            let path = ".acdian-draft-\(UUID().uuidString).md"
            self.openID = UUID(); self.loadID = UUID()
            self.selected = VaultEntry(relativePath:path,url:root.appendingPathComponent(path),name:"New Page",isDirectory:false,children:nil,modified:nil,size:0)
            self.editorSelection = nil; self.pendingEditorSelection = nil
            self.isDraft = true; self.draftTitle = ""; self.text = ""; self.originalText = ""
            self.showingTrash = false
            self.anchor = ""; self.insertion = nil; self.pdfPage = 1; self.pdfPageCount = 0; self.loading = false
            self.editorDocumentID = UUID(); self.statusValue = .ready
            completion?()
        }
    }
    private func clearDraftState() {
        cancelAutosave(); isDraft = false; draftTitle = ""; draftFile = nil; savedDraftContent = nil
        editorSelection = nil; pendingEditorSelection = nil; lastAutosaveError = nil
    }
    private static func editorUTF16Count(_ text: String) -> Int {
        text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").utf16.count
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
                var number = 1
                while true {
                    let filename = base + (number == 1 ? "" : " \(number)") + ".md"
                    let url = root.appendingPathComponent(filename)
                    if fm.fileExists(atPath:url.path) || (try? fm.destinationOfSymbolicLink(atPath:url.path)) != nil { number += 1; continue }
                    do { try VaultFileIO.saveMarkdown(content,at:url,expectedContent:nil,allowedRoot:root) }
                    catch VaultCoreError.conflict { number += 1; continue }
                    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { number += 1; continue }
                    // Only the backing file changes. The current editor keeps
                    // its body, title, selection, history and bridge identity.
                    let refreshed = try? VaultIndex(root:root)
                    file = refreshed?.files.first(where: { $0.relativePath == filename }) ?? VaultEntry(relativePath:filename,url:url,name:filename,isDirectory:false,children:nil,modified:Date(),size:content.utf8.count)
                    if let refreshed { index = refreshed; rebuildSearch() }
                    break
                }
            }
            draftFile = file; savedDraftContent = content; originalText = text
            searchCache[file.id] = content; statusValue = .saved(Date()); lastAutosaveError = nil
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
            try VaultFileIO.saveMarkdown("# \(String(filename.dropLast(3)))\n\n",at:url,expectedContent:nil,allowedRoot:root)
            index = try VaultIndex(root:root); rebuildSearch()
            if let file = index?.files.first(where: {$0.relativePath.precomposedStringWithCanonicalMapping == filename.precomposedStringWithCanonicalMapping}) { open(file,skipConfirmation:true) }
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
            let directory = root.appendingPathComponent("Attachments").resolvingSymlinksInPath()
            guard directory.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw NSError(domain:"acdian",code:2,userInfo:[NSLocalizedDescriptionKey:"附件目录指向页面存储范围以外，无法导入。"]) }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var links: [String] = []
            for source in panel.urls {
                var dest = directory.appendingPathComponent(source.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath:dest.path) { dest = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(n).\(source.pathExtension)"); n += 1 }
                try FileManager.default.copyItem(at:source,to:dest)
                let embed = Self.images.contains(dest.pathExtension.lowercased()) || dest.pathExtension.lowercased() == "pdf"
                links.append("\(embed ? "!" : "")[[Attachments/\(dest.lastPathComponent)]]")
            }
            insertion = EditorInsertion(text:"\n" + links.joined(separator:"\n") + "\n"); refresh()
        } catch { self.error = self.localizedError(error) }
    }
}
