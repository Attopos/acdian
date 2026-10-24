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

        print("Tabs: \(checks) checks passed for opening, reuse, closing, new pages, moves, trash and relaunch restore")
    }
}
