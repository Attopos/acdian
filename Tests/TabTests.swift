import Foundation
import AppKit

@main
struct TabTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-tab-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root.appendingPathComponent("Folder",isDirectory:true),withIntermediateDirectories:true)
        for (name,body) in [("A.md","# A\n"),("B.md","# B\n"),("Folder/C.md","# C\n")] { try Data(body.utf8).write(to:root.appendingPathComponent(name)) }
        let suite = "acdian-tab-tests-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated test preferences") }
        defer { try? fm.removeItem(at:root); preferences.removePersistentDomain(forName:suite) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"TabTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func pause() async { try? await Task.sleep(nanoseconds:10_000_000) }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { try check(true,message); return }
                await pause()
            }
            try check(condition(),message)
        }
        func launch() async throws -> AppModel {
            let model = AppModel(preferences:preferences,pagesRoot:root,autosaveDelay:5)
            try await eventually("Pages load at launch") { model.index != nil && !model.loading }
            return model
        }
        func file(_ model: AppModel, _ path: String) -> VaultEntry { model.index!.files.first { $0.relativePath == path }! }
        func paths(_ model: AppModel) -> [String?] { model.tabs.map(\.path) }
        func activePath(_ model: AppModel) -> String? { model.tabs.first { $0.id == model.activeTabID }?.path }
        func open(_ model: AppModel, _ path: String) async throws {
            model.open(file(model,path))
            try await eventually("\(path) opens in the front tab") { model.selected?.relativePath == path && activePath(model) == path && !model.loading }
        }
        func disk(_ path: String) throws -> String { try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8) }

        do {
            let model = try await launch()
            try check(model.tabs.isEmpty && model.selected == nil, "A first launch has no tabs and an empty main area")
            try await open(model,"A.md")
            try await open(model,"B.md")
            try check(paths(model) == ["A.md","B.md"], "Opening another page keeps the previous page in its own tab")
            try await open(model,"A.md")
            try check(paths(model) == ["A.md","B.md"], "Opening a page that is already in a tab returns to that tab")
            model.text = "# A\n\nEdited"
            try await open(model,"Folder/C.md")
            try check(try disk("A.md") == "# A\n\nEdited", "Leaving a tab saves its latest edits")
            try check(paths(model) == ["A.md","B.md","Folder/C.md"], "New tabs open at the end")

            let b = model.tabs[1].id
            model.closeTab(b)
            try check(paths(model) == ["A.md","Folder/C.md"] && model.selected?.relativePath == "Folder/C.md", "Closing a tab in the back leaves the front page in place")
            model.selectTab(model.tabs[0].id)
            try await eventually("Clicking a tab shows its page") { model.selected?.relativePath == "A.md" && model.text == "# A\n\nEdited" }
            model.closeCurrentTab()
            try await eventually("Closing the front tab shows the tab to its right") { paths(model) == ["Folder/C.md"] && model.selected?.relativePath == "Folder/C.md" && !model.loading }

            model.newPageFromEditor()
            try check(model.isDraft && paths(model) == ["Folder/C.md",nil] && model.tabTitle(model.tabs[1]) == "New Page", "A new page opens in its own tab")
            try await open(model,"B.md")
            try check(paths(model) == ["Folder/C.md","B.md"], "A page opened from a blank new page takes over its tab")
            model.newPageFromEditor()
            model.draftTitle = "Draft"
            try check(model.tabTitle(model.tabs[2]) == "Draft", "A new page's tab follows its title")
            model.text = "Body"
            try check(model.save() && paths(model) == ["Folder/C.md","B.md","Draft.md"], "Saving a new page gives its tab the created file")
            try await open(model,"Folder/C.md")
        }

        do {
            let model = try await launch()
            try await eventually("A relaunch restores the open tabs and the front page") { paths(model) == ["Folder/C.md","B.md","Draft.md"] && model.selected?.relativePath == "Folder/C.md" && activePath(model) == "Folder/C.md" && !model.loading }
            model.movePage("B.md",to:PageDropTarget(folder:"Folder"))
            try await eventually("Moving a page keeps its tab on the new path") { paths(model) == ["Folder/C.md","Folder/B.md","Draft.md"] }
            model.delete(AppModel.entry("Folder",in:model.index!.entries)!)
            try await eventually("Moving a folder to the trash closes its tabs and shows the next one") { paths(model) == ["Draft.md"] && model.selected?.relativePath == "Draft.md" && !model.loading }
            model.closeCurrentTab()
            try await eventually("Closing the last tab leaves the main area empty") { model.tabs.isEmpty && model.selected == nil }
        }

        do {
            let model = try await launch()
            try check(model.tabs.isEmpty && model.selected == nil, "Pages closed before quitting stay closed after a relaunch")
            try await open(model,"A.md")
            model.showTrash()
            try check(model.showingTrash && paths(model) == ["A.md"], "The trash view leaves open tabs in place")
        }

        do {
            let model = try await launch()
            try await eventually("Quitting while the trash is shown reopens the last page") { model.selected?.relativePath == "A.md" && !model.loading }
            try fm.removeItem(at:root.appendingPathComponent("A.md"))
        }

        do {
            let model = try await launch()
            try check(model.tabs.isEmpty && model.selected == nil, "A page removed while the app was closed is not restored")
        }

        // Kept tab text: switching back needs no disk read, and the file is checked after.
        for (name,body) in [("Keep.md","# Keep\n\nKept body\n"),("Next.md","# Next\n")] { try Data(body.utf8).write(to:root.appendingPathComponent(name)) }
        do {
            let model = try await launch()
            model.refresh()
            try await eventually("A refresh lists new pages") { model.index?.files.contains { $0.relativePath == "Keep.md" } == true && !model.loading }
            try await open(model,"Keep.md")
            let keepTab = model.activeTabID!
            try await open(model,"Next.md")
            model.selectTab(keepTab)
            try check(model.selected?.relativePath == "Keep.md" && model.text == "# Keep\n\nKept body\n" && !model.loading && model.activeTabID == keepTab, "A tab comes back at once from its kept text, without waiting for the disk")
            let shown = model.editorDocumentID
            await pause(); await pause()
            try check(model.editorDocumentID == shown && model.text == "# Keep\n\nKept body\n", "An unchanged file leaves the shown page alone")

            try await open(model,"Next.md")
            try Data("# Keep\n\nChanged by another app\n".utf8).write(to:root.appendingPathComponent("Keep.md"))
            model.selectTab(keepTab)
            try check(model.text == "# Keep\n\nKept body\n", "The kept text shows first")
            try await eventually("A file changed while its tab was in the back shows what is on disk") { model.text == "# Keep\n\nChanged by another app\n" && model.originalText == model.text && model.editorDocumentID != shown && !model.dirty }

            try await open(model,"Next.md")
            try Data("# Keep\n\nChanged again, elsewhere\n".utf8).write(to:root.appendingPathComponent("Keep.md"))
            model.selectTab(keepTab)
            model.text = "# Keep\n\nTyped here at once"
            try await eventually("A disk check never replaces edits made in the meantime") { model.text == "# Keep\n\nTyped here at once" && model.dirty }
            await pause(); await pause()
            try check(!model.save() && model.error != nil && (try disk("Keep.md")) == "# Keep\n\nChanged again, elsewhere\n", "Saving over the outside change is refused as a conflict")
            model.error = nil
            model.text = model.originalText
            model.reload()
            try await eventually("Reloading reads the file again") { model.text == "# Keep\n\nChanged again, elsewhere\n" && !model.dirty && !model.loading }

            // The editor's place is remembered per tab and kept for a relaunch.
            var answer: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { answer = $0 }
            var leftKeep = false
            model.withEditorSnapshot { leftKeep = true }
            answer?(.success(EditorSnapshot(text:model.text,currentPath:"Keep.md",selectionAnchor:9,selectionHead:14,scrollPosition:8,scrollOffset:-12.5)))
            try check(leftKeep && model.frontTabView == EditorViewState(anchor:9,head:14,scrollPosition:8,scrollOffset:-12.5), "A snapshot records the front tab's selection and scroll place")
            model.editorSnapshot = nil
            try await open(model,"Next.md")
            try check(model.frontTabView == nil, "Each tab has its own place")
            model.selectTab(keepTab)
            try check(model.frontTabView == EditorViewState(anchor:9,head:14,scrollPosition:8,scrollOffset:-12.5), "Returning to a tab offers its place to the editor")
        }
        do {
            let model = try await launch()
            try await eventually("A relaunch restores the front tab") { model.selected?.relativePath == "Keep.md" && !model.loading }
            try check(model.frontTabView == EditorViewState(anchor:9,head:14,scrollPosition:8,scrollOffset:-12.5), "A relaunch returns each tab to its selection and scroll place")
            try check(model.tabs.allSatisfy { $0.path != nil }, "Only saved pages are restored")
            model.closeCurrentTab()
            try await eventually("Closing a tab shows the next one") { model.selected?.relativePath != "Keep.md" && !model.loading }
            let views = preferences.dictionary(forKey:"tabViews:" + model.index!.root.path) as? [String:[Double]] ?? [:]
            try check(views["Keep.md"] == nil, "A closed tab's place is forgotten")
        }

        // Search reuses the text of files whose stamp did not change.
        do {
            let model = try await launch()
            let find = root.appendingPathComponent("Find.md")
            let stamp = Date(timeIntervalSince1970:1_700_000_000)
            try Data("needle-one".utf8).write(to:find)
            try fm.setAttributes([.modificationDate:stamp],ofItemAtPath:find.path)
            model.refresh()
            model.query = "needle-one"
            try await eventually("Search finds page text") { model.matches.map(\.relativePath) == ["Find.md"] }
            try Data("needle-two".utf8).write(to:find)
            try fm.setAttributes([.modificationDate:stamp],ofItemAtPath:find.path)
            model.refresh()
            try await eventually("A refresh finishes") { !model.loading }
            await pause(); await pause(); await pause()
            model.query = "needle-two"
            try check(model.matches.isEmpty, "A file with an unchanged stamp is not read again")
            try fm.setAttributes([.modificationDate:stamp.addingTimeInterval(5)],ofItemAtPath:find.path)
            model.refresh()
            try await eventually("A file whose stamp changed is read again") { model.matches.map(\.relativePath) == ["Find.md"] }
            model.query = "needle-one"
            try check(model.matches.isEmpty, "Its old text is gone from search")
            try await open(model,"Next.md")
            model.text = "# Next\n\nsaved-needle"; try check(model.save(), "Saving a page")
            model.query = "saved-needle"
            try check(model.matches.map(\.relativePath) == ["Next.md"], "A saved page is searchable at once")
            model.refresh()
            try await eventually("A saved page stays searchable after a rescan") { !model.loading && model.matches.map(\.relativePath) == ["Next.md"] }
        }

        print("Tabs: \(checks) checks passed for opening, reuse, closing, new pages, moves, trash, relaunch restore, kept tab text, disk checks, remembered places and search reuse")
    }
}
