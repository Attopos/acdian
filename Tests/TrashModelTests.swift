import Foundation
import AppKit

@main
struct TrashModelTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-trash-model-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:root)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        let epoch = Date(timeIntervalSince1970:1_800_000_000)
        var now = epoch
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"TrashModelTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func fixture(_ name: String) throws -> (AppModel,URL) {
            now = epoch
            let directory = root.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            let suite = "acdian-trash-model-tests-\(UUID().uuidString)"
            suites.append(suite)
            guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated preferences") }
            let model = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:directory,trashNow:{ now })
            model.index = try VaultIndex(root:directory)
            return (model,directory)
        }
        func write(_ source: String, _ directory: URL, _ path: String) throws {
            let url = directory.appendingPathComponent(path)
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(source.utf8).write(to:url)
        }
        func select(_ model: AppModel, _ directory: URL, _ path: String = "Page.md", _ source: String = "# Saved\n\nSaved body") throws -> VaultEntry {
            try write(source,directory,path)
            model.index = try VaultIndex(root:directory)
            guard let entry = model.index?.files.first(where: { $0.relativePath == path }) else { fatalError("Missing fixture entry") }
            model.selected = entry; model.text = source; model.originalText = source
            return entry
        }
        func topEntry(_ model: AppModel, _ name: String) -> VaultEntry {
            guard let entry = model.index?.entries.first(where: { $0.relativePath == name }) else { fatalError("Missing fixture top-level entry") }
            return entry
        }
        func store(_ directory: URL) throws -> PageTrash { try PageTrash(root:directory,nowDate:{ now }) }
        func payload(_ directory: URL, _ id: UUID) -> URL { directory.appendingPathComponent(".acdian-trash/\(id.uuidString)/payload") }
        func disk(_ directory: URL, _ path: String) throws -> String { try String(contentsOf:directory.appendingPathComponent(path),encoding:.utf8) }
        func settle() async { try? await Task.sleep(nanoseconds:50_000_000) }
        func runTimers(for interval: TimeInterval) {
            let until = Date().addingTimeInterval(interval)
            while Date() < until { _ = RunLoop.main.run(mode:.default,before:until) }
        }

        do {
            let (model,directory) = try fixture("selected-conflict")
            let entry = try select(model,directory)
            let generation = model.editorDocumentID
            let insertion = EditorInsertion(text:"pending attachment")
            model.insertion = insertion
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completion: Bool?
            model.delete(entry) { completion = $0 }
            try check(callback != nil && completion == nil && fm.fileExists(atPath:entry.url.path), "Deleting the selected page must wait for its current editor snapshot")
            try write("# External version",directory,"Page.md")
            callback?(.success(EditorSnapshot(text:"# Latest unsaved 中文🌸",currentPath:entry.relativePath)))
            await settle()
            try check(completion == false && model.error != nil && model.text == "# Latest unsaved 中文🌸" && model.dirty, "A pre-delete save conflict retains the latest editor text and reports no deletion")
            try check(model.selected?.id == entry.id && model.editorDocumentID == generation && model.insertion == insertion && !model.showingTrash, "A failed automatic save preserves document identity, pending insertion and view")
            try check(try disk(directory,"Page.md") == "# External version" && store(directory).entries().isEmpty, "A save conflict preserves external edits and creates no trash item")
        }

        do {
            let (model,directory) = try fixture("selected-autosave")
            let entry = try select(model,directory)
            let generation = model.editorDocumentID
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completion: Bool?
            model.delete(entry) { completion = $0 }
            callback?(.success(EditorSnapshot(text:"Keep this latest body",currentPath:entry.relativePath)))
            await settle()
            let items = try store(directory).entries()
            try check(completion == true && !fm.fileExists(atPath:entry.url.path) && items.count == 1, "Deleting the selected page automatically saves before moving it into trash")
            try check(try String(contentsOf:payload(directory,items[0].id),encoding:.utf8) == "Keep this latest body", "The recoverable payload contains the newest editor content")
            try check(model.selected == nil && model.text.isEmpty && model.originalText.isEmpty && !model.isDraft && model.editorDocumentID != generation && model.insertion == nil, "Successful selected-page deletion must clear and rotate the document state")
        }

        do {
            let (model,directory) = try fixture("selected-save")
            let entry = try select(model,directory)
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions: [Bool] = []
            model.delete(entry) { completions.append($0) }
            callback?(.success(EditorSnapshot(text:"# Final saved keystroke 中文🌸",currentPath:entry.relativePath)))
            await settle()
            let items = try store(directory).entries()
            try check(completions == [true] && items.count == 1 && (try String(contentsOf:payload(directory,items[0].id),encoding:.utf8)) == "# Final saved keystroke 中文🌸", "Automatic save-and-delete commits the newest editor snapshot into the recoverable payload")
            let generation = model.editorDocumentID
            callback?(.success(EditorSnapshot(text:"Late duplicate callback",currentPath:entry.relativePath)))
            await settle()
            try check(completions == [true] && model.selected == nil && model.text.isEmpty && model.editorDocumentID == generation && (try store(directory).entries()).count == 1, "A duplicate old snapshot callback must not repeat deletion or revive removed text")
        }

        do {
            let (model,directory) = try fixture("active-draft-backing")
            model.newPageFromEditor()
            model.draftTitle = "Draft recoverable 🌸"; model.text = "First saved body\r\n"
            try check(model.save(),"The active draft has a saved backing page before deletion")
            guard let file = model.persistedPage, let editorPath = model.selected?.relativePath else { fatalError("Saved draft backing missing") }
            let generation = model.editorDocumentID
            model.text = "Native pending body"
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions: [Bool] = []
            model.delete(file) { completions.append($0) }
            try check(callback != nil && completions.isEmpty && fm.fileExists(atPath:file.url.path),"Deleting the active draft backing waits for its synthetic editor's latest snapshot")
            let latest = "最新中文🌸\r\n\r\nLast keystroke\r\n"
            callback?(.success(EditorSnapshot(text:latest,currentPath:editorPath)))
            await settle()
            let items = try store(directory).entries()
            try check(completions == [true] && items.count == 1 && !fm.fileExists(atPath:file.url.path),"The active draft backing moves to trash exactly once")
            let content = "# Draft recoverable 🌸\n\n" + latest
            try check(try String(contentsOf:payload(directory,items[0].id),encoding:.utf8) == content,"Draft deletion saves the exact title plus newest Unicode/CRLF snapshot into trash")
            try check(model.selected == nil && model.persistedPage == nil && model.text.isEmpty && model.draftTitle.isEmpty && !model.isDraft && model.editorDocumentID != generation,"Successful backing deletion clears the live draft and its persistence identity")
            callback?(.success(EditorSnapshot(text:"Late deleted draft callback",currentPath:editorPath)))
            try? await Task.sleep(nanoseconds:600_000_000)
            try check(completions == [true] && !fm.fileExists(atPath:file.url.path) && model.selected == nil && model.text.isEmpty && (try store(directory).entries()).count == 1,"A pending autosave or late callback cannot recreate the deleted backing file")
            try check(try String(contentsOf:payload(directory,items[0].id),encoding:.utf8) == content,"Canceled autosaves cannot mutate the recoverable draft payload")
        }

        do {
            let (model,directory) = try fixture("ancestor-save")
            _ = try select(model,directory,"Folder/Nested/Page.md")
            try write("Attachment bytes",directory,"Folder/Attachments/reference.bin")
            model.index = try VaultIndex(root:directory)
            let folder = topEntry(model,"Folder")
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completion: Bool?
            model.delete(folder) { completion = $0 }
            try check(callback != nil && completion == nil, "Deleting a folder containing the selected page must also wait for its editor snapshot")
            callback?(.success(EditorSnapshot(text:"# Saved before folder deletion",currentPath:"Folder/Nested/Page.md")))
            await settle()
            let items = try store(directory).entries()
            try check(completion == true && model.selected == nil && items.count == 1 && items[0].isDirectory, "Deleting a selected page's ancestor must move the folder once and clear the active document")
            try check(try String(contentsOf:payload(directory,items[0].id).appendingPathComponent("Nested/Page.md"),encoding:.utf8) == "# Saved before folder deletion" && String(contentsOf:payload(directory,items[0].id).appendingPathComponent("Attachments/reference.bin"),encoding:.utf8) == "Attachment bytes", "Folder deletion must retain the newest selected-page content and all sibling assets")
        }

        do {
            let (model,directory) = try fixture("unrelated-draft")
            try write("# Remove only this page",directory,"Other.md")
            model.index = try VaultIndex(root:directory)
            let other = model.index!.files.first!
            model.newPageFromEditor()
            model.draftTitle = "Keep my draft"; model.text = "Unsaved body 中文🌸"
            let generation = model.editorDocumentID, selected = model.selected?.id
            var snapshots = 0, completion: Bool?
            model.editorSnapshot = { _ in snapshots += 1 }
            model.delete(other) { completion = $0 }
            try check(completion == true && snapshots == 0, "Deleting an unrelated page must not snapshot the active draft")
            try check(model.isDraft && model.draftTitle == "Keep my draft" && model.text == "Unsaved body 中文🌸" && model.editorDocumentID == generation && model.selected?.id == selected, "An unrelated deletion must preserve the entire unsaved draft")
            try check(!fm.fileExists(atPath:other.url.path) && (try store(directory).entries()).count == 1, "Only the requested unrelated page may be moved to trash")
        }

        do {
            let (model,directory) = try fixture("physical-alias-ancestor")
            _ = try select(model,directory,"Folder/Page.md")
            try fm.createSymbolicLink(at:directory.appendingPathComponent("Alias.md"),withDestinationURL:directory.appendingPathComponent("Folder/Page.md"))
            model.index = try VaultIndex(root:directory)
            model.selected = model.index?.files.first(where: { $0.relativePath == "Alias.md" })
            let folder = topEntry(model,"Folder")
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completion: Bool?
            model.delete(folder) { completion = $0 }
            try check(callback != nil && completion == nil, "Deleting the physical ancestor of an open file alias must wait for the alias editor snapshot")
            callback?(.success(EditorSnapshot(text:"# Latest alias edits",currentPath:"Alias.md")))
            await settle()
            let items = try store(directory).entries()
            try check(completion == true && model.selected == nil && items.count == 1 && (try String(contentsOf:payload(directory,items[0].id).appendingPathComponent("Page.md"),encoding:.utf8)) == "# Latest alias edits", "Physical-ancestor deletion must preserve alias edits in trash and clear the now-unavailable editor")
        }

        do {
            let (model,directory) = try fixture("prefix-not-ancestor")
            let selected = try select(model,directory,"Folderish.md")
            try write("# Other",directory,"Folder/Page.md")
            model.index = try VaultIndex(root:directory)
            let folder = topEntry(model,"Folder")
            model.text += "Unsaved edits"
            var snapshots = 0
            model.editorSnapshot = { _ in snapshots += 1 }
            model.delete(folder)
            try check(snapshots == 0 && model.selected?.id == selected.id && model.dirty && fm.fileExists(atPath:selected.url.path), "A folder-name prefix must not be mistaken for the selected page's ancestor")
        }

        do {
            let (model,directory) = try fixture("move-failure")
            let entry = try select(model,directory)
            try write("Blocking trash path",directory,".acdian-trash")
            model.text = "Keep these native edits"
            let generation = model.editorDocumentID
            var completion: Bool?
            model.delete(entry) { completion = $0 }
            try check(completion == false && model.error != nil && model.selected?.id == entry.id && model.editorDocumentID == generation && model.text == "Keep these native edits" && !model.dirty, "A failed trash move retains the selected page and editor identity after its edits were safely saved")
            try check(try disk(directory,"Page.md") == "Keep these native edits" && disk(directory,".acdian-trash") == "Blocking trash path", "A failed move preserves the newly saved editor content and blocking path")
        }

        do {
            let (model,directory) = try fixture("save-conflict")
            let entry = try select(model,directory)
            try write("# Changed by another app",directory,"Page.md")
            model.text = "# Unsaved local edit"
            let generation = model.editorDocumentID
            var completion: Bool?
            model.delete(entry) { completion = $0 }
            try check(completion == false && model.error != nil && model.text == "# Unsaved local edit" && model.selected?.id == entry.id && model.editorDocumentID == generation, "A failed automatic save aborts deletion and preserves local edits")
            try check(try disk(directory,"Page.md") == "# Changed by another app" && store(directory).entries().isEmpty, "Save conflict must preserve the externally changed page and create no trash item")
        }

        do {
            let (model,directory) = try fixture("stale-snapshot")
            let entry = try select(model,directory)
            let source = model.text
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completion: Bool?
            model.delete(entry) { completion = $0 }
            model.editorDocumentID = UUID()
            callback?(.success(EditorSnapshot(text:"Stale payload",currentPath:entry.relativePath)))
            await settle()
            try check(completion == false && model.error == nil && model.text == source && model.selected?.id == entry.id && fm.fileExists(atPath:entry.url.path), "A stale-generation delete snapshot must cancel silently without deleting or overwriting current text")
            model.delete(entry) { completion = $0 }
            callback?(.success(EditorSnapshot(text:"Wrong-path payload",currentPath:"Other.md")))
            await settle()
            try check(completion == false && model.error != nil && model.text == source && fm.fileExists(atPath:entry.url.path) && (try store(directory).entries()).isEmpty, "A wrong-path delete snapshot must report an error and preserve the requested file")
        }

        do {
            let (model,directory) = try fixture("trash-view")
            let entry = try select(model,directory)
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            let baseline = model.originalText
            try write("# Externally changed page",directory,"Page.md")
            model.showTrash()
            callback?(.success(EditorSnapshot(text:"# Dirty latest body",currentPath:entry.relativePath)))
            await settle()
            try check(!model.showingTrash && model.selected?.id == entry.id && model.text == "# Dirty latest body" && model.error != nil, "A failed pre-trash save preserves the current page and newest text")
            try write(baseline,directory,"Page.md")
            model.error = nil
            model.showTrash()
            callback?(.success(EditorSnapshot(text:model.text,currentPath:entry.relativePath)))
            await settle()
            try check(model.showingTrash && model.selected == nil && model.text.isEmpty && (try disk(directory,"Page.md")) == "# Dirty latest body", "Opening trash saves the latest snapshot before clearing the editor and displaying trash")
            model.editorSnapshot = nil
            model.newPageFromEditor()
            try check(!model.showingTrash && model.isDraft, "Cmd+N from trash must return directly to a clean editable draft")
            model.showTrash()
            try check(model.showingTrash && !model.isDraft, "An untouched draft may be left for trash without materializing a page")
            model.goHome()
            try check(!model.showingTrash && model.selected == nil, "Home must leave the trash view")
        }

        do {
            let (model,directory) = try fixture("restore-preserves-draft")
            try write("# Restore this body",directory,"Restore.md")
            let item = try store(directory).moveToTrash(relativePath:"Restore.md")
            try write("# Existing active version",directory,"Restore.md")
            model.index = try VaultIndex(root:directory)
            model.newPageFromEditor()
            model.draftTitle = "Active draft"; model.text = "Keep this unsaved body"
            let generation = model.editorDocumentID, selected = model.selected?.id
            try check(model.refreshTrash() && model.trashEntries.map(\.id) == [item.id], "Refreshing trash must load the current recoverable entries")
            try check(model.restoreFromTrash(item), "Restoring a name conflict must succeed with a safe unused filename")
            try check(model.isDraft && model.draftTitle == "Active draft" && model.text == "Keep this unsaved body" && model.selected?.id == selected && model.editorDocumentID == generation, "Restore must preserve any currently edited unsaved draft")
            try check(try disk(directory,"Restore.md") == "# Existing active version" && disk(directory,"Restore 2.md") == "# Restore this body" && model.trashEntries.isEmpty && model.index?.files.contains(where: { $0.relativePath == "Restore 2.md" }) == true, "Restore must preserve the active version and refresh both sidebar and trash contents")
        }

        do {
            let (model,directory) = try fixture("expiry-refresh")
            try write("# Expiring payload",directory,"Expire.md")
            let item = try store(directory).moveToTrash(relativePath:"Expire.md")
            let selected = try select(model,directory,"Keep.md","# Active page")
            model.text += "\nUnsaved edits"
            let generation = model.editorDocumentID
            now = item.expiresAt.addingTimeInterval(-0.001)
            try check(model.refreshTrash() && model.trashEntries.map(\.id) == [item.id], "Trash refresh before expiry must retain recoverable items")
            now = item.expiresAt
            try check(model.refreshTrash() && model.trashEntries.isEmpty && !fm.fileExists(atPath:payload(directory,item.id).path), "Trash refresh at expiry must permanently purge only the expired item")
            try check(model.selected?.id == selected.id && model.editorDocumentID == generation && model.text == "# Active page\nUnsaved edits" && model.dirty && (try disk(directory,"Keep.md")) == "# Active page", "Expiry purge must preserve the selected page, dirty edits, editor identity and saved disk version")
            try check(!model.restoreFromTrash(item) && !fm.fileExists(atPath:directory.appendingPathComponent("Expire.md").path), "A stale UI restore action must not revive a permanently purged item")
        }

        do {
            let (model,directory) = try fixture("restore-failure")
            try write("# Recover me",directory,"Nested/Page.md")
            let item = try store(directory).moveToTrash(relativePath:"Nested/Page.md")
            try fm.removeItem(at:directory.appendingPathComponent("Nested"))
            try write("Blocking parent",directory,"Nested")
            model.newPageFromEditor()
            model.draftTitle = "Keep active draft"; model.text = "Unsaved active body"
            let generation = model.editorDocumentID, selected = model.selected?.id
            try check(!model.restoreFromTrash(item) && model.error != nil, "A blocked restore must return failure and report its error")
            try check(model.isDraft && model.draftTitle == "Keep active draft" && model.text == "Unsaved active body" && model.selected?.id == selected && model.editorDocumentID == generation, "A failed restore must retain the active dirty draft without navigation or editor replacement")
            try check(model.trashEntries.map(\.id) == [item.id] && (try String(contentsOf:payload(directory,item.id),encoding:.utf8)) == "# Recover me" && (try disk(directory,"Nested")) == "Blocking parent", "A failed restore must retain the recoverable item and preserve the blocking active file")
        }

        do {
            let (model,directory) = try fixture("deadline-timer")
            try write("# Timer expiry",directory,"Expire.md")
            let item = try store(directory).moveToTrash(relativePath:"Expire.md")
            let selected = try select(model,directory,"Keep.md","# Keep active")
            model.text += "\nUnsaved edits"
            let generation = model.editorDocumentID
            now = item.expiresAt.addingTimeInterval(-0.05)
            try check(model.refreshTrash() && model.trashEntries.count == 1, "A running app must schedule cleanup for its nearest upcoming expiry")
            now = item.expiresAt
            runTimers(for:0.2)
            await settle()
            try check(model.trashEntries.isEmpty && !fm.fileExists(atPath:payload(directory,item.id).path), "The running-app timer must purge an expired item without a user refresh")
            try check(model.selected?.id == selected.id && model.editorDocumentID == generation && model.text == "# Keep active\nUnsaved edits" && model.dirty, "Timer cleanup must preserve the currently edited dirty page")
        }

        do {
            let (model,directory) = try fixture("overdue-startup")
            try write("# Expired while closed",directory,"Expire.md")
            try write("# Keep active page",directory,"Keep.md")
            let item = try store(directory).moveToTrash(relativePath:"Expire.md")
            now = item.expiresAt.addingTimeInterval(60)
            model.loadPages(directory)
            for _ in 0..<200 {
                if !model.loading { break }
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            try check(!model.loading && model.error == nil && model.trashEntries.isEmpty && !fm.fileExists(atPath:payload(directory,item.id).path), "Opening the page store after downtime must purge overdue trash before showing recoverable entries")
            try check(model.selected == nil && model.index?.files.map(\.relativePath) == ["Keep.md"] && (try disk(directory,"Keep.md")) == "# Keep active page", "Overdue startup cleanup must preserve active pages and the blank initial editor")
        }

        print("TrashModel: \(checks) checks passed for latest snapshots, automatic save before deletion, ancestor deletion, failure recovery, draft preservation, view navigation, conflict restore and expiry")
    }
}
