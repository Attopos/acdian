import Foundation

@main
struct PagesStorageTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-pages-storage-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:root)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"PagesStorageTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func preferences() -> UserDefaults {
            let suite = "acdian-pages-storage-tests-\(UUID().uuidString)"
            suites.append(suite)
            guard let value = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated preferences") }
            return value
        }
        func path(_ name: String, create: Bool = false) throws -> URL {
            let value = root.appendingPathComponent(name,isDirectory:true)
            if create { try fm.createDirectory(at:value,withIntermediateDirectories:true) }
            return value
        }
        func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
        func resolve(_ prefs: UserDefaults, override: URL? = nil, adjacent: URL? = nil, fallback: URL? = nil) throws -> URL {
            // Every candidate is injected so no test can open real user pages.
            let location = try PagesStorage.resolve(preferences:prefs,override:override,
                adjacentRoot:adjacent ?? root.appendingPathComponent("absent-adjacent"),
                fallbackRoot:fallback ?? root.appendingPathComponent("fallback-\(UUID().uuidString)"))
            defer { location.securityScopedURL?.stopAccessingSecurityScopedResource() }
            return location.root
        }
        func write(_ source: String, _ directory: URL, _ relativePath: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(source.utf8).write(to:url)
        }
        func snapshot(_ directory: URL) throws -> [String:Data] {
            let prefix = directory.path + "/"
            var files: [String:Data] = [:]
            guard let enumerator = fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey]) else { return files }
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                    files[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf:file)
                }
            }
            return files
        }
        func settled(_ model: AppModel) async -> Bool {
            for _ in 0..<200 {
                if !model.loading { return true }
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            return !model.loading
        }

        do {
            let prefs = preferences(), existing = try path("override-existing",create:true)
            let chosen = try path("override-created")
            prefs.set(existing.path,forKey:"pagesPath")
            let result = try resolve(prefs,override:chosen,adjacent:existing,fallback:existing)
            try check(result == canonical(chosen) && fm.fileExists(atPath:chosen.path), "An explicit automatic-storage override must be created and selected")
            try check(prefs.string(forKey:"pagesPath") == existing.path, "A test or command-line override must not replace the remembered pages location")
            try check(try fm.contentsOfDirectory(atPath:chosen.path).isEmpty, "Creating local storage must not create starter notes or metadata files")
        }

        do {
            let prefs = preferences(), saved = try path("saved-pages",create:true)
            let adjacent = try path("saved-adjacent",create:true), legacy = try path("saved-legacy",create:true)
            let fallback = try path("saved-fallback")
            prefs.set(saved.path,forKey:"pagesPath")
            prefs.set(legacy.path,forKey:"vaultPath")
            try check(try resolve(prefs,adjacent:adjacent,fallback:fallback) == canonical(saved), "A remembered pages path must take priority over adjacent and legacy directories")
            try check(!fm.fileExists(atPath:fallback.path), "Resolving existing pages must not create an unused fallback directory")
        }

        do {
            let prefs = preferences(), bookmarked = try path("bookmarked-pages",create:true)
            let stalePath = try path("other-pages",create:true)
            let bookmark = try bookmarked.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            prefs.set(bookmark,forKey:"pagesBookmark")
            prefs.set(stalePath.path,forKey:"pagesPath")
            try check(try resolve(prefs) == canonical(bookmarked), "A valid pages bookmark must take priority over an old remembered path")
            try check(prefs.string(forKey:"pagesPath") == canonical(bookmarked).path, "Resolving a pages bookmark must refresh the remembered pages path")
        }

        do {
            let prefs = preferences(), saved = try path("invalid-bookmark-pages",create:true)
            prefs.set(Data([0x00,0x01,0x02]),forKey:"pagesBookmark")
            prefs.set(saved.path,forKey:"pagesPath")
            try check(try resolve(prefs) == canonical(saved), "An invalid bookmark must safely fall through to an existing pages path")
        }

        do {
            let prefs = preferences(), adjacent = try path("paired/资料库",create:true)
            let legacy = try path("paired-legacy",create:true), fallback = try path("paired-fallback")
            try write("# Existing 中文🌸\n\n[[Nested/Linked]]",adjacent,"Existing.md")
            try write("# Linked\n",adjacent,"Nested/Linked.md")
            try write("{\"theme\":\"original\"}",adjacent,".obsidian/app.json")
            let before = try snapshot(adjacent)
            prefs.set(legacy.path,forKey:"vaultPath")
            try check(try resolve(prefs,adjacent:adjacent,fallback:fallback) == canonical(adjacent), "An existing adjacent 资料库 must be adopted before a legacy saved path")
            try check(try snapshot(adjacent) == before && !fm.fileExists(atPath:fallback.path), "Adopting adjacent pages must preserve all note bytes and hidden configuration in place")
            try check(prefs.string(forKey:"pagesPath") == canonical(adjacent).path, "An adopted adjacent location must become the remembered pages location")
            let otherAdjacent = try path("new-adjacent",create:true)
            try check(try resolve(prefs,adjacent:otherAdjacent,fallback:fallback) == canonical(adjacent), "The adopted pages location must stay stable on later launches")
        }

        do {
            let prefs = preferences(), legacy = try path("legacy-pages",create:true)
            let fallback = try path("legacy-fallback")
            try write("# Keep my original\r\n\r\nBody 🌸",legacy,"Notes/Original.md")
            try write("binary-placeholder\u{0000}\u{00FF}",legacy,"Attachments/reference.bin")
            let before = try snapshot(legacy)
            prefs.set(legacy.path,forKey:"vaultPath")
            try check(try resolve(prefs,fallback:fallback) == canonical(legacy), "Existing legacy pages must be adopted without requiring a previous chooser flag")
            try check(try snapshot(legacy) == before && !fm.fileExists(atPath:fallback.path), "Legacy adoption must not move, copy, delete, or rewrite originals")
            try check(prefs.string(forKey:"pagesPath") == canonical(legacy).path, "Legacy adoption must persist the same physical pages location")
        }

        do {
            let prefs = preferences(), bookmarked = try path("legacy-bookmarked",create:true)
            let oldPath = try path("legacy-old-path",create:true)
            prefs.set(try bookmarked.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil),forKey:"vaultBookmark")
            prefs.set(oldPath.path,forKey:"vaultPath")
            try check(try resolve(prefs) == canonical(bookmarked), "A valid legacy bookmark must preserve its location before trying the old path")
            try check(prefs.string(forKey:"pagesPath") == canonical(bookmarked).path, "A legacy bookmark must be adopted into current pages preferences")
        }

        do {
            let prefs = preferences(), missing = try path("missing-legacy")
            let stalePages = try path("missing-saved-pages"), fallback = try path("new-local-pages")
            prefs.set(stalePages.path,forKey:"pagesPath")
            prefs.set(missing.path,forKey:"vaultPath")
            prefs.set(Data([0x01,0x00]),forKey:"vaultBookmark")
            try check(try resolve(prefs,fallback:fallback) == canonical(fallback), "Missing remembered and legacy directories must fall back to automatic local pages")
            try check(fm.fileExists(atPath:fallback.path) && !fm.fileExists(atPath:missing.path) && !fm.fileExists(atPath:stalePages.path), "Only the fallback may be created; obsolete locations must stay absent")
            try check(prefs.string(forKey:"pagesPath") == canonical(fallback).path, "The fallback must be remembered for the next launch")
        }

        do {
            let prefs = preferences(), file = root.appendingPathComponent("not-a-directory")
            try Data("Keep this file".utf8).write(to:file)
            var rejected = false
            do { _ = try resolve(prefs,override:file) } catch { rejected = true }
            try check(rejected && (try String(contentsOf:file,encoding:.utf8)) == "Keep this file", "A non-directory storage target must fail without replacing the original file")
        }

        do {
            let prefs = preferences(), directory = try path("blank-startup",create:true)
            try write("# Already here\n\nKeep this page",directory,"Already here.md")
            let before = try snapshot(directory)
            let model = AppModel(preferences:prefs,pagesRoot:directory)
            let didSettle = await settled(model)
            try check(didSettle, "Startup indexing must finish for an ordinary local pages directory")
            try check(model.index?.root == canonical(directory) && model.markdownCount == 1 && model.error == nil, "Startup must automatically index existing pages")
            try check(model.selected == nil && model.text.isEmpty && !model.isDraft, "Startup must leave the main area blank instead of automatically opening a page")
            try check(try snapshot(directory) == before, "Startup indexing must preserve existing page bytes")
        }

        do {
            let prefs = preferences(), directory = try path("instant-new")
            let model = AppModel(loadInitialVault:false,preferences:prefs,pagesRoot:directory)
            var completed = 0
            model.newPageFromEditor { completed += 1 }
            try check(model.isDraft && model.index?.root == canonical(directory) && completed == 1, "Cmd+N must create an editable draft immediately without prior setup or asynchronous loading")
            try check(try fm.contentsOfDirectory(atPath:directory.path).isEmpty, "Cmd+N must leave an untouched empty draft virtual")
            model.draftTitle = "Automatic page"
            model.text = "Saved body"
            try check(model.save(), "A draft created without setup must save successfully")
            try check(try String(contentsOf:directory.appendingPathComponent("Automatic page.md"),encoding:.utf8) == "# Automatic page\n\nSaved body", "Saving must write the page to automatic local storage")
        }

        do {
            let prefs = preferences(), directory = try path("startup-race",create:true)
            try write("# Existing page\n\nDo not change",directory,"Existing.md")
            let model = AppModel(preferences:prefs,pagesRoot:directory)
            model.newPageFromEditor()
            let identity = model.editorDocumentID, draftPath = model.selected?.relativePath
            model.draftTitle = "Typed immediately"
            model.text = "The first keystroke 中文🌸"
            // Give the initial background index and its main-thread callback time
            // to complete after Cmd+N invalidates the initial load request.
            for _ in 0..<20 { try? await Task.sleep(nanoseconds:10_000_000) }
            try check(model.isDraft && model.draftTitle == "Typed immediately" && model.text == "The first keystroke 中文🌸", "An initial asynchronous index must not erase a draft opened immediately at launch")
            try check(model.editorDocumentID == identity && model.selected?.relativePath == draftPath && !model.loading, "A superseded startup load must not replace the active draft identity or loading state")
            try check(model.save() && model.persistedPage?.name == "Typed immediately.md" && model.editorDocumentID == identity, "The surviving immediate-startup draft must save without replacing its editor")
            try check(try String(contentsOf:directory.appendingPathComponent("Existing.md"),encoding:.utf8) == "# Existing page\n\nDo not change", "Immediate draft creation and save must preserve previously stored pages")
        }

        do {
            let prefs = preferences(), blocked = root.appendingPathComponent("blocked-storage")
            try Data("Keep this file".utf8).write(to:blocked)
            let model = AppModel(loadInitialVault:false,preferences:prefs,pagesRoot:blocked)
            let identity = model.editorDocumentID
            var completed = false
            model.newPageFromEditor { completed = true }
            try check(!model.isDraft && model.selected == nil && model.editorDocumentID == identity && !completed && model.error != nil, "An inaccessible storage location must report an error without creating an unusable draft")
            try check(try String(contentsOf:blocked,encoding:.utf8) == "Keep this file", "A failed automatic-storage attempt must preserve the blocking file")
        }

        print("PagesStorage: \(checks) checks passed for automatic setup, location priority, in-place adoption, original-file preservation, blank startup and immediate-draft safety")
    }
}
