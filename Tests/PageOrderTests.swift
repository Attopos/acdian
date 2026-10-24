import Foundation
import AppKit

@main
struct PageOrderTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-page-order-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:root)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"PageOrderTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func vault(_ name: String, _ files: [String: String]) throws -> URL {
            let directory = root.appendingPathComponent(name,isDirectory:true)
            for (path,source) in files {
                let url = directory.appendingPathComponent(path)
                try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                if path.hasSuffix("/") { try fm.createDirectory(at:url,withIntermediateDirectories:true) }
                else { try Data(source.utf8).write(to:url) }
            }
            return directory.standardizedFileURL.resolvingSymlinksInPath()
        }
        func names(_ entries: [VaultEntry]) -> [String] { entries.map(\.name) }

        // Reordering within a folder is stored and survives a rescan; new names follow.
        let ordering = try vault("ordering",["A.md":"a","B.md":"b","C.md":"c","Notes/":""])
        try check(names(try VaultIndex(root:ordering).entries) == ["Notes","A.md","B.md","C.md"],"Default order lists folders first, then names")
        let organizer = PageOrganizer(root:ordering)
        try check(try organizer.move("C.md",to:PageDropTarget(folder:"",anchor:"A.md")) == "C.md","Reordering keeps the path")
        try check(names(try VaultIndex(root:ordering).entries) == ["Notes","C.md","A.md","B.md"],"C is placed before A")
        try organizer.move("Notes",to:PageDropTarget(folder:"",anchor:"B.md",after:true))
        try check(names(try VaultIndex(root:ordering).entries) == ["C.md","A.md","B.md","Notes"],"A folder can be placed after a file")
        try Data("d".utf8).write(to:ordering.appendingPathComponent("D.md"))
        try check(names(try VaultIndex(root:ordering).entries) == ["C.md","A.md","B.md","Notes","D.md"],"Unlisted new pages follow the custom order")
        try check(fm.fileExists(atPath:ordering.appendingPathComponent(PageOrganizer.orderFileName).path),"Order is stored in the hidden order file")
        try check(!(try VaultIndex(root:ordering).files.contains { $0.name == PageOrganizer.orderFileName }),"The order file is not listed as a page")

        // Moving into a folder is a real move that never overwrites.
        let moving = try vault("moving",["Page.md":"outer","Folder/Page.md":"inner","Folder/Sub/":""])
        let mover = PageOrganizer(root:moving)
        let moved = try mover.move("Page.md",to:PageDropTarget(folder:"Folder"))
        try check(moved == "Folder/Page 2.md","An occupied name gets a number suffix")
        try check(try String(contentsOf:moving.appendingPathComponent("Folder/Page.md"),encoding:.utf8) == "inner","The existing page is untouched")
        try check(try String(contentsOf:moving.appendingPathComponent("Folder/Page 2.md"),encoding:.utf8) == "outer","The moved page keeps its content")
        try check(!fm.fileExists(atPath:moving.appendingPathComponent("Page.md").path),"The source is gone after the move")
        try check(names(try VaultIndex(root:moving).entries.first { $0.name == "Folder" }?.children ?? []).last == "Page 2.md","A moved page goes to the end of its new folder")
        var refused = false
        do { try mover.move("Folder",to:PageDropTarget(folder:"Folder/Sub")) } catch VaultCoreError.invalidMove { refused = true }
        try check(refused,"A folder cannot move into its own descendant")
        refused = false
        do { try mover.move("Folder",to:PageDropTarget(folder:"Folder")) } catch VaultCoreError.invalidMove { refused = true }
        try check(refused,"A folder cannot move into itself")
        refused = false
        do { try mover.move("../Page.md",to:PageDropTarget(folder:"")) } catch VaultCoreError.unsafeLocation { refused = true }
        try check(refused,"Paths outside the vault are refused")
        try check(try mover.move("Folder/Page.md",to:PageDropTarget(folder:"")) == "Page.md","Moving back to the root works")

        // The open page stays open at its new path, with unsaved edits saved first.
        let modelRoot = try vault("model",["Open.md":"# Saved","Box/":""])
        let suite = "acdian-page-order-tests-\(UUID().uuidString)"; suites.append(suite)
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated preferences") }
        let model = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:modelRoot,trashNow:{ Date() })
        model.index = try VaultIndex(root:modelRoot)
        guard let page = model.index?.files.first(where: { $0.name == "Open.md" }) else { throw NSError(domain:"PageOrderTest",code:2) }
        model.open(page,skipConfirmation:true)
        for _ in 0..<200 where model.loading || model.selected?.relativePath != "Open.md" { try await Task.sleep(nanoseconds:10_000_000) }
        model.text = "# Edited"
        model.movePage("Open.md",to:PageDropTarget(folder:"Box"))
        for _ in 0..<200 where model.loading || model.selected?.relativePath != "Box/Open.md" { try await Task.sleep(nanoseconds:10_000_000) }
        try check(model.selected?.relativePath == "Box/Open.md","The open page is selected at its new path")
        try check(try String(contentsOf:modelRoot.appendingPathComponent("Box/Open.md"),encoding:.utf8) == "# Edited","Unsaved edits are saved before the move")

        // New folders go right below the clicked item, then are named in place.
        let folders = try vault("folders",["Top.md":"t","Box/A.md":"a","Box/B.md":"b","Box/Z/":"","Box/新建文件夹/":"","Box/资料/":""])
        let foldersModel = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:folders,trashNow:{ Date() })
        foldersModel.language = .simplifiedChinese
        foldersModel.index = try VaultIndex(root:folders)
        func found(_ path: String) -> VaultEntry? { foldersModel.index.flatMap { AppModel.entry(path,in:$0.entries) } }
        func tree(_ entries: [VaultEntry]) -> [String] { entries.flatMap { [$0.relativePath] + tree($0.children ?? []) } }
        func box() -> [String] { names(found("Box")?.children ?? []) }
        foldersModel.query = "A"
        try check(foldersModel.newFolder(near:found("Box")!) == "Box/新建文件夹 2","A folder made on a folder goes inside it, numbered when the name is taken")
        try check(box().first == "新建文件夹 2","A folder made on a folder is first inside it, right below it")
        try check(foldersModel.renamingPath == "Box/新建文件夹 2" && foldersModel.folderExpanded("Box") == true && foldersModel.query.isEmpty,"Its name is being edited, its parent is open and the tree is shown")
        foldersModel.finishRenaming("Box/新建文件夹 2",to:"  第一章 ")
        try check(foldersModel.renamingPath == nil && box().first == "第一章" && fm.fileExists(atPath:folders.appendingPathComponent("Box/第一章").path) && !fm.fileExists(atPath:folders.appendingPathComponent("Box/新建文件夹 2").path),"Typing a name renames it on disk, trimmed, keeping its place")
        try check(foldersModel.newFolder(near:found("Box/A.md")!) == "Box/新建文件夹 2","A folder made on a file goes next to it")
        try check(Array(box().drop { $0 != "A.md" }.prefix(2)) == ["A.md","新建文件夹 2"],"A folder made on a file sits right below the file")
        foldersModel.finishRenaming("Box/新建文件夹 2",to:nil)
        try check(foldersModel.renamingPath == nil && found("Box/新建文件夹 2") != nil,"Escape keeps the name it was made with")
        try check(foldersModel.newFolder(near:found("Top.md")!) == "新建文件夹" && names(foldersModel.index!.entries) == ["Box","Top.md","新建文件夹"],"A folder made on a top-level file sits right below it in the pages root")
        foldersModel.finishRenaming("新建文件夹",to:"新建文件夹")
        try check(found("新建文件夹") != nil && foldersModel.renamingPath == nil,"Keeping the same name changes nothing")
        foldersModel.finishRenaming("新建文件夹",to:"再改")
        try check(found("新建文件夹") != nil,"Only the item being named can be renamed")
        try check(tree(foldersModel.index!.entries) == tree(try VaultIndex(root:folders).entries),"The sidebar lists new folders where a rescan would")

        // Renaming existing files and folders.
        foldersModel.startRenaming(found("Box/B.md")!)
        try check(AppModel.editableName(found("Box/B.md")!) == "B","A page is renamed without its .md ending")
        foldersModel.finishRenaming("Box/B.md",to:"笔记")
        try check(try String(contentsOf:folders.appendingPathComponent("Box/笔记.md"),encoding:.utf8) == "b" && found("Box/笔记.md") != nil && found("Box/B.md") == nil,"Renaming a page keeps .md and its content")
        foldersModel.startRenaming(found("Box/笔记.md")!); foldersModel.finishRenaming("Box/笔记.md",to:"笔记.md")
        try check(found("Box/笔记.md") != nil,"Typing .md does not double the ending")
        let position = box().firstIndex(of:"笔记.md")
        foldersModel.startRenaming(found("Box/Z")!); foldersModel.finishRenaming("Box/Z",to:"Zed")
        try check(found("Box/Zed")?.isDirectory == true && box().firstIndex(of:"笔记.md") == position,"Renaming a folder keeps the order of its siblings")
        try Data("pdf".utf8).write(to:folders.appendingPathComponent("Box/Scan.pdf")); foldersModel.index = try VaultIndex(root:folders)
        try check(AppModel.editableName(found("Box/Scan.pdf")!) == "Scan.pdf","Other files are renamed with their extension")
        foldersModel.startRenaming(found("Box/Scan.pdf")!); foldersModel.finishRenaming("Box/Scan.pdf",to:"扫描.pdf")
        try check(found("Box/扫描.pdf") != nil,"Other files rename with the typed name")
        foldersModel.error = nil
        foldersModel.startRenaming(found("Box/笔记.md")!); foldersModel.finishRenaming("Box/笔记.md",to:"A")
        try check(foldersModel.error?.contains("A.md") == true && found("Box/笔记.md") != nil && (try String(contentsOf:folders.appendingPathComponent("Box/A.md"),encoding:.utf8)) == "a","A taken name is refused and nothing is overwritten")
        for bad in ["", "  ", "a/b", "a:b", ".hidden"] {
            foldersModel.error = nil
            foldersModel.startRenaming(found("Box/Zed")!); foldersModel.finishRenaming("Box/Zed",to:bad)
            try check(foldersModel.error != nil && found("Box/Zed") != nil,"An invalid name is refused: \(bad)")
        }

        // Renaming the open page, or a folder holding it, keeps it open with its edits.
        foldersModel.open(found("Box/A.md")!,skipConfirmation:true)
        for _ in 0..<200 where foldersModel.loading || foldersModel.selected?.relativePath != "Box/A.md" { try await Task.sleep(nanoseconds:10_000_000) }
        foldersModel.text = "a edited"
        foldersModel.startRenaming(found("Box/A.md")!); foldersModel.finishRenaming("Box/A.md",to:"甲")
        for _ in 0..<200 where foldersModel.loading || foldersModel.selected?.relativePath != "Box/甲.md" { try await Task.sleep(nanoseconds:10_000_000) }
        try check(foldersModel.selected?.relativePath == "Box/甲.md" && (try String(contentsOf:folders.appendingPathComponent("Box/甲.md"),encoding:.utf8)) == "a edited","The open page is saved, renamed and stays open")
        foldersModel.startRenaming(found("Box")!); foldersModel.finishRenaming("Box",to:"盒子")
        for _ in 0..<200 where foldersModel.loading || foldersModel.selected?.relativePath != "盒子/甲.md" { try await Task.sleep(nanoseconds:10_000_000) }
        try check(foldersModel.selected?.relativePath == "盒子/甲.md" && foldersModel.folderExpanded("盒子") == true,"Renaming a folder keeps the open page inside it open and the folder open")

        refused = false
        do { try PageOrganizer(root:folders).createFolder("X",in:"../Escape") } catch VaultCoreError.unsafeLocation { refused = true }
        try check(refused,"A folder outside the pages folder is refused")
        let caseRoot = try vault("case",["Notes/":""])
        try check(try PageOrganizer(root:caseRoot).rename("Notes",to:"notes") == "notes" && (try fm.contentsOfDirectory(atPath:caseRoot.path)).contains("notes"),"A case-only rename works on a case-insensitive disk")
        print("PageOrder: \(checks) checks passed for custom order, new pages, safe moves, name conflicts, folder rules, keeping the open page, new folders and renaming")
    }
}
