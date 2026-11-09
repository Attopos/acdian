import Foundation
import AppKit
import CryptoKit

/// Pages folders kept in iCloud: files not downloaded yet, cleanup that must
/// wait, temporary files, and the opt-in move. Runs on temporary folders only.
@main
struct CloudSyncTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("acdian-cloud-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:base)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"CloudSyncTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 { if condition() { checks += 1; return }; await pause(0.01) }
            throw NSError(domain:"CloudSyncTest",code:2,userInfo:[NSLocalizedDescriptionKey:message])
        }
        func vault(_ name: String, _ files: [String:Data]) throws -> URL {
            let root = base.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            for (path,data) in files {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try data.write(to:url)
            }
            return root.standardizedFileURL.resolvingSymlinksInPath()
        }
        func text(_ value: String) -> Data { Data(value.utf8) }
        var now = Date(timeIntervalSince1970:1_800_000_000)
        func model(_ root: URL) async throws -> (AppModel,UserDefaults) {
            let name = "acdian-cloud-tests-\(UUID().uuidString)"; suites.append(name)
            let preferences = UserDefaults(suiteName:name)!
            let app = AppModel(preferences:preferences,pagesRoot:root,trashNow:{ now },autosaveDelay:5,attachmentCleanupDelay:0)
            try await eventually("The pages folder loads") { app.index != nil && !app.loading }
            return (app,preferences)
        }
        func cleanup(_ app: AppModel) async {
            var done = false
            app.runAttachmentCleanup { done = true }
            for _ in 0..<300 where !done { await pause(0.01) }
            await pause(0.3)
        }
        func tree(_ root: URL) throws -> [String:String] {
            var result: [String:String] = [:]
            let walk = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:[])!
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for case let url as URL in walk where (try url.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                result[String(path.dropFirst(prefix.count))] = SHA256.hash(data:try Data(contentsOf:url)).description
            }
            return result
        }

        // A file iCloud has not downloaded is listed under its real name.
        let cloud = try vault("placeholders",["Here.md":text("# Here"),".Far.md.icloud":text("stub"),"Sub/.Deep.md.icloud":text("stub"),".Both.md.icloud":text("stub"),"Both.md":text("real"),"..acdian-order.json.icloud":text("stub")])
        var index = try VaultIndex(root:cloud)
        try check(Set(index.files.map(\.relativePath)) == ["Here.md","Far.md","Sub/Deep.md","Both.md"],"Placeholders appear once, under their real names, and hidden ones stay out")
        try check(index.resolve("Far",from:"Here.md")?.lastPathComponent == "Far.md" && index.resolve("Deep",from:"Here.md") != nil,"Links reach a page that is not downloaded")
        try check(CloudFiles.isNotDownloaded(cloud.appendingPathComponent("Far.md")) && !CloudFiles.isNotDownloaded(cloud.appendingPathComponent("Here.md")),"Not downloaded is told apart from downloaded")
        try check(!CloudFiles.isNotDownloaded(cloud.appendingPathComponent("Nothing.md")),"A name with no file and no stub is not in iCloud")
        try check(PageOrganizer(root:cloud).currentOrder(of:"",order:[:]).contains("Far.md"),"A placeholder keeps its place in the order")
        do { try VaultFileIO.saveMarkdown("new",at:cloud.appendingPathComponent("Far.md"),expectedContent:nil,allowedRoot:cloud); try check(false,"A not-downloaded name is taken") }
        catch VaultCoreError.conflict { checks += 1 }
        var (app,_) = try await model(cloud)
        app.query = "Far"
        try check(app.matches.contains { $0.relativePath == "Far.md" },"Search keeps a page it cannot read yet")
        try await eventually("Search reads the pages it can") { app.searchedPageCount == 2 }
        try check(try String(contentsOf:cloud.appendingPathComponent(".Far.md.icloud"),encoding:.utf8) == "stub","Search leaves the placeholder alone")

        // Saves keep their temporary file out of the pages folder and still refuse a conflict.
        let saves = try vault("saves",["Page.md":text("old")])
        let page = saves.appendingPathComponent("Page.md")
        try VaultFileIO.saveMarkdown("new",at:page,expectedContent:"old",allowedRoot:saves)
        try check(try fm.contentsOfDirectory(atPath:saves.path) == ["Page.md"] && String(contentsOf:page,encoding:.utf8) == "new","A save leaves nothing else in the pages folder")
        try "theirs".write(to:page,atomically:true,encoding:.utf8)
        do { try VaultFileIO.saveMarkdown("mine",at:page,expectedContent:"new",allowedRoot:saves); try check(false,"A changed file is a conflict") }
        catch VaultCoreError.conflict { checks += 1 }
        try check(try String(contentsOf:page,encoding:.utf8) == "theirs","A conflict keeps the file")
        // A page moved with its comments still carries them.
        let moves = try vault("moves",["A.md":text("a"),".A.md.comments.json":text("{}"),"F/":Data()].filter { !$0.key.hasSuffix("/") })
        try fm.createDirectory(at:moves.appendingPathComponent("F"),withIntermediateDirectories:true)
        _ = try PageOrganizer(root:moves).move("A.md",to:PageDropTarget(folder:"F"))
        try check(fm.fileExists(atPath:moves.appendingPathComponent("F/A.md").path) && fm.fileExists(atPath:moves.appendingPathComponent("F/.A.md.comments.json").path),"Comments move with their page")

        // An attachment is not unused while any page cannot be read.
        for (name,blocker) in [("unreadable",Data([0xFF,0xFE,0x00,0xD8])),("in-icloud",text("stub"))] {
            let bad = name == "unreadable" ? "Bad.md" : ".Bad.md.icloud"
            let root = try vault("cleanup-\(name)",["P.md":text("![[Attachments/pic.png]]\n"),"Attachments/pic.png":text("png"),bad:blocker])
            let picture = root.appendingPathComponent("Attachments/pic.png")
            now = Date(timeIntervalSince1970:1_800_000_000)
            (app,_) = try await model(root)
            guard let file = app.index?.files.first(where: { $0.relativePath == "P.md" }) else { throw NSError(domain:"CloudSyncTest",code:3) }
            app.open(file,skipConfirmation:true,fromDisk:true)
            try await eventually("The page opens") { app.currentPagePath == "P.md" && !app.loading }
            app.text = "no picture now\n"
            try check(app.save(),"The page saves")
            await cleanup(app)
            try check(fm.fileExists(atPath:picture.path),"\(name): an unreadable page keeps the attachment")
            now = now.addingTimeInterval(31)
            await cleanup(app)
            try check(fm.fileExists(atPath:picture.path),"\(name): it keeps it on the next try too")
            try fm.removeItem(at:root.appendingPathComponent(bad))
            try text("readable").write(to:root.appendingPathComponent("Bad.md"))
            app.index = try VaultIndex(root:root)
            now = now.addingTimeInterval(31)
            await cleanup(app)
            try check(!fm.fileExists(atPath:picture.path) && app.trashEntries.contains { $0.name == "pic.png" },"\(name): once every page reads, the cleanup goes ahead")
        }

        // The trash waits for iCloud to finish with an expired item.
        let trashRoot = try vault("trash",["Old.md":text("old")])
        var settled = false
        var clock = Date(timeIntervalSince1970:1_800_000_000)
        let trash = try PageTrash(root:trashRoot,nowDate:{ clock },isSettled:{ _ in settled })
        let entry = try trash.moveToTrash(relativePath:"Old.md")
        clock = entry.expiresAt.addingTimeInterval(1)
        try check(try trash.purgeExpired().isEmpty && trash.entries().count == 1,"An expired item still syncing stays")
        settled = true
        try check(try trash.purgeExpired() == [entry.id] && trash.entries().isEmpty,"Once settled it is purged")

        // A page changed by sync while open behaves like any outside edit.
        let synced = try vault("synced",["Open.md":text("first")])
        (app,_) = try await model(synced)
        guard let opened = app.index?.files.first else { throw NSError(domain:"CloudSyncTest",code:4) }
        app.open(opened,skipConfirmation:true,fromDisk:true)
        try await eventually("The page opens") { app.currentPagePath == "Open.md" && !app.loading }
        await pause(0.05)
        func syncWrite(_ value: String) throws {
            let target = synced.appendingPathComponent("Open.md")
            try FileCoordination.writing(target,options:.forReplacing) { try value.write(to:target,atomically:true,encoding:.utf8) }
        }
        try syncWrite("second")
        app.checkOpenPageOnDisk()
        try await eventually("With no local edits the page reloads") { app.originalText == "second" }
        app.text = "my edit"
        try syncWrite("third")
        await pause(0.05)
        app.checkOpenPageOnDisk()
        await pause(0.2)
        try check(app.save() && app.error == nil && app.text.contains("my edit") && app.text.contains("third"),"With local edits the save merges both sides")
        try check(try String(contentsOf:synced.appendingPathComponent("Open.md"),encoding:.utf8) == app.text && app.text.contains("[!warning]"),"Overlapping edits are kept in callouts on disk")

        // Three-way merges.
        func merged(_ base: String, _ local: String, _ disk: String) -> PageMerge.Outcome { PageMerge.merge(base:base,local:local,disk:disk,localName:"Mac",diskName:"iPad") }
        let ten = (1...10).map { "line \($0)" }.joined(separator:"\n")
        func edit(_ number: Int, _ value: String) -> String { ten.replacingOccurrences(of:"line \(number)\n",with:value + "\n") }
        var result = merged(ten,edit(2,"two here"),edit(8,"eight there"))
        try check(result.clean && result.text.contains("two here") && result.text.contains("eight there") && !result.text.contains("line 2\n") && !result.text.contains("line 8\n"),"Edits on different lines merge silently")
        try check(merged(ten,ten,edit(3,"x")).text == edit(3,"x") && merged(ten,edit(3,"x"),ten).text == edit(3,"x") && merged(ten,edit(3,"x"),edit(3,"x")).clean,"One side unchanged, or both the same, needs no merge")
        result = merged(ten,edit(5,"mine"),edit(5,"theirs"))
        try check(!result.clean && result.text.contains("> [!warning] Merge conflict: Mac\n> mine") && result.text.contains("> [!warning] Merge conflict: iPad\n> theirs") && result.text.contains("line 4") && result.text.contains("line 6"),"Overlapping edits keep both sides in named callouts")
        result = merged(ten,ten + "\nend mine",edit(1,"start theirs"))
        try check(result.clean && result.text.hasPrefix("start theirs") && result.text.hasSuffix("end mine"),"Additions at both ends merge")
        result = merged(ten,ten.replacingOccurrences(of:"line 4\n",with:""),edit(9,"nine"))
        try check(result.clean && !result.text.contains("line 4") && result.text.contains("nine"),"A deleted line merges with an edit elsewhere")
        result = merged(ten,ten.replacingOccurrences(of:"line 4\n",with:""),edit(4,"changed"))
        try check(!result.clean && result.text.contains("changed"),"Deleted on one side and changed on the other keeps the change")
        try check(merged("","a","b").text.contains("> a") && merged("","a","b").text.contains("> b"),"Without a common ancestor both versions are kept")
        let held = try vault("merge-save",["M.md":text("a\nb\nc\n")])
        let heldPage = held.appendingPathComponent("M.md")
        try text("a\nB\nc\n").write(to:heldPage)
        let outcome = try VaultFileIO.saveMerging("A\nb\nc\n",at:heldPage,base:"a\nb\nc\n",allowedRoot:held)
        try check(outcome == .merged("A\nB\nc\n") && String(contentsOf:heldPage,encoding:.utf8) == "A\nB\nc\n","A save merges against the disk in one step")
        try check(try VaultFileIO.saveMerging("X\nB\nc\n",at:heldPage,base:"A\nB\nc\n",allowedRoot:held) == .saved,"An unchanged disk is simply saved")
        try fm.removeItem(at:heldPage)
        do { _ = try VaultFileIO.saveMerging("X",at:heldPage,base:"A",allowedRoot:held); try check(false,"A deleted file is not recreated") }
        catch VaultCoreError.conflict { checks += 1 }
        let bases = PageBases(directory:base.appendingPathComponent("bases",isDirectory:true))
        bases.store("kept",root:held,path:"M.md")
        try check(bases.read(root:held,path:"M.md") == "kept" && bases.read(root:held,path:"N.md") == nil,"A page's base is kept outside the folder")

        // Moving the pages to iCloud.
        let hidden: [String:Data] = ["Welcome.md":text("# Hi"),".Welcome.md.comments.json":text("{\"t\":1}"),".acdian-order.json":text("{}"),".acdian-modules.json":text("{\"modules\":[]}"),
                                     ".acdian-trash/A1/payload":text("gone"),".acdian-trash/A1/metadata.json":text("{}"),"Notes/粉色 示例.md":text("中文"),"Attachments/pic.png":Data([1,2,3,0,255])]
        let source = try vault("move-source",hidden)
        let before = try tree(source)
        let target = base.appendingPathComponent("move-target",isDirectory:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        let canonicalTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        var preferences: UserDefaults
        (app,preferences) = try await model(source)
        app.iCloudTarget = canonicalTarget
        try check(app.canMoveToICloud,"The move is offered once the iCloud folder exists")
        app.iCloudTarget = base.appendingPathComponent("no-such-folder")
        try check(!app.canMoveToICloud,"It is not offered without the iCloud folder")
        app.iCloudTarget = canonicalTarget
        var finished: Bool?
        app.movePagesToICloud { finished = $0 }
        try await eventually("The move finishes") { finished != nil && !app.loading && app.index?.root.path == target.standardizedFileURL.resolvingSymlinksInPath().path }
        try check(finished == true,"The move succeeds")
        try check(try tree(target) == before,"Every file arrives, hidden ones included, with the same hash")
        try check(try tree(source) == before,"The original folder is left exactly as it was")
        try check(preferences.string(forKey:"pagesPath") == canonicalTarget.path && app.pagesBackupPath == source.path,"The saved location switches and the backup's path is kept")
        try check(!app.canMoveToICloud,"It is not offered again once the pages are there")
        let located = try PagesStorage.resolve(preferences:preferences,adjacentRoot:base.appendingPathComponent("none"),fallbackRoot:base.appendingPathComponent("fallback"))
        try check(located.root.path == target.standardizedFileURL.resolvingSymlinksInPath().path,"The next launch opens the iCloud folder")

        let full = try vault("full-target",["Theirs.md":text("keep")])
        do { try PagesStorage.copyPages(from:source,to:full); try check(false,"A folder with files is refused") }
        catch PagesStorage.MoveError.targetNotEmpty { checks += 1 }
        try check(try tree(full).count == 1,"A refused move changes nothing")
        (app,preferences) = try await model(source)
        app.iCloudTarget = full; finished = nil
        app.movePagesToICloud { finished = $0 }
        try await eventually("The refusal arrives") { finished != nil }
        try check(finished == false && app.error != nil && preferences.string(forKey:"pagesPath") == nil && app.index?.root.path == source.path,"A refused move explains itself and does not switch")
        let stubbed = try vault("stubbed-source",[".Far.md.icloud":text("stub")])
        let empty = base.appendingPathComponent("empty-target",isDirectory:true)
        try fm.createDirectory(at:empty,withIntermediateDirectories:true)
        do { try PagesStorage.copyPages(from:stubbed,to:empty); try check(false,"A stub in the source is refused") }
        catch PagesStorage.MoveError.notDownloaded { checks += 1 }
        try check(try fm.contentsOfDirectory(atPath:empty.path).isEmpty,"Nothing is copied when a file is not downloaded")

        print("CloudSync: \(checks) checks passed for placeholders, coordinated saves, cleanup that waits, trash that waits, sync reloads and the move to iCloud")
    }
}
