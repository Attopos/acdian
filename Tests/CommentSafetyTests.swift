import Foundation

/// Page comments must never be lost: every change keeps the previous version,
/// damaged files are kept and replaced by the last good version, comments left
/// behind by a page moved in another app find it again, a restored page keeps
/// comments already waiting under its name, and earlier comments can be
/// brought back. Runs on temporary folders only.
@main
struct CommentSafetyTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("acdian-comment-safety-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"CommentSafetyTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func vault(_ name: String, _ files: [String:String]) throws -> URL {
            let root = base.appendingPathComponent(name,isDirectory:true)
            for (path,text) in files {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(text.utf8).write(to:url)
            }
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            return root.standardizedFileURL.resolvingSymlinksInPath()
        }
        func thread(_ id: String, quote: String? = nil, replies: [String]) -> [String:Any] {
            var item: [String:Any] = ["id":id,"created":1.0,"replies":replies.enumerated().map { ["id":"\(id)-\($0.offset)","text":$0.element,"created":Double($0.offset + 1)] }]
            if let quote { item["quote"] = quote; item["from"] = 0; item["to"] = quote.count } else { item["whole"] = true }
            return item
        }
        func file(_ threads: [String:Any]...) -> String {
            String(data:try! JSONSerialization.data(withJSONObject:["version":1,"threads":threads],options:[.sortedKeys]),encoding:.utf8)!
        }
        func ids(_ json: String?) -> Set<String> { Set(PageComments.threadIDs(json)) }
        let history = CommentHistory(directory:base.appendingPathComponent("history",isDirectory:true), limit:60, quiet:600)
        PageComments.history = history
        defer { PageComments.history = nil }

        // Every change keeps the version before it; moves of a comment alone are not kept twice.
        do {
            let root = try vault("history",["P.md":"一段文字"])
            try PageComments.write(file(thread("A",replies:["a"])),page:"P.md",root:root,merging:false)
            try check(history.versions(root:root,path:"P.md").isEmpty,"Nothing earlier to keep the first time")
            try PageComments.write(file(thread("A",replies:["a"]),thread("B",replies:["b"])),page:"P.md",root:root,merging:false)
            try check(history.versions(root:root,path:"P.md").count == 1 && ids(history.versions(root:root,path:"P.md").first) == ["A"],"Adding a comment keeps the version before it")
            var moved = thread("A",quote:"一段",replies:["a"]); moved["from"] = 2
            try PageComments.write(file(moved,thread("B",replies:["b"])),page:"P.md",root:root,merging:false)
            var again = moved; again["from"] = 3
            try PageComments.write(file(again,thread("B",replies:["b"])),page:"P.md",root:root,merging:false)
            let kept = history.versions(root:root,path:"P.md").count
            var third = moved; third["from"] = 4
            try PageComments.write(file(third,thread("B",replies:["b"])),page:"P.md",root:root,merging:false)
            try check(history.versions(root:root,path:"P.md").count == kept,"A comment only moving in the text is not kept again and again")
            try PageComments.write(nil,page:"P.md",root:root,merging:false)
            try check(PageComments.read(page:"P.md",root:root) == nil,"Deleting the last comment still removes the file")
            try check(ids(history.versions(root:root,path:"P.md").first) == ["A","B"],"Deleting every comment keeps them in the history")
            // ...and they can be brought back.
            try check(try PageComments.restoreEarlier(page:"P.md",root:root) == 2 && ids(PageComments.read(page:"P.md",root:root)) == ["A","B"],"Earlier comments can be restored")
            try check(try PageComments.restoreEarlier(page:"P.md",root:root) == 0,"Restoring twice brings nothing more")
            var limited = CommentHistory(directory:base.appendingPathComponent("limited",isDirectory:true)); limited.limit = 3
            for n in 0..<6 { limited.keep(file(thread("T\(n)",replies:["x"])),root:root,path:"Q.md") }
            try check(limited.versions(root:root,path:"Q.md").count == 3 && ids(limited.versions(root:root,path:"Q.md").first) == ["T5"],"Only the newest versions are kept, newest first")
        }

        // A damaged file is never silently replaced.
        do {
            let root = try vault("damaged",["P.md":"文字"])
            try PageComments.write(file(thread("A",replies:["keep me"])),page:"P.md",root:root,merging:false)
            try PageComments.write(file(thread("A",replies:["keep me"]),thread("B",replies:["b"])),page:"P.md",root:root,merging:false)
            let sidecar = root.appendingPathComponent(".P.md.comments.json")
            try Data("{\"version\":1,\"threads\":[{\"id\":\"A\"".utf8).write(to:sidecar)
            let shown = PageComments.read(page:"P.md",root:root)
            try check(ids(shown) == ["A"],"A damaged file reads as the newest good version")
            try check(history.versions(root:root,path:"P.md").contains { $0.hasPrefix("{\"version\":1,\"threads\":[{\"id\":\"A\"") && !PageComments.isValid($0) },"The damaged file itself is kept")
            var refused = false
            do { try PageComments.write("{not json",page:"P.md",root:root,merging:false) } catch { refused = true }
            try check(refused,"Text that is not a comments file is never written")
        }

        // In a synced folder a save with nothing from the editor cannot wipe another device's comments.
        do {
            let root = try vault("merge",["P.md":"文字"])
            let bases = PageBases(directory:base.appendingPathComponent("bases",isDirectory:true))
            PageComments.baseStore = bases
            defer { PageComments.baseStore = nil }
            try Data(file(thread("Theirs",replies:["from the iPad"])).utf8).write(to:root.appendingPathComponent(".P.md.comments.json"))
            try PageComments.write(file(thread("Mine",replies:["from the Mac"])),page:"P.md",root:root,merging:true)
            try check(ids(PageComments.read(page:"P.md",root:root)) == ["Mine","Theirs"],"Comments added on two devices are both kept")
        }

        // Comments left behind when another app renames or moves a page find it again.
        do {
            let root = try vault("orphans",[
                "Notes/Renamed.md":"这一页里有一句被评论的话，还有别的内容。",
                "Other/Moved.md":"整页评论的页面",
                "Notes/Unrelated.md":"毫不相关",
                "Notes/Inode.md":"没有引文的页面"])
            try Data(file(thread("Q",quote:"一句被评论的话",replies:["quote match"])).utf8).write(to:root.appendingPathComponent("Notes/.Old name.md.comments.json"))
            try Data(file(thread("W",replies:["same name"])).utf8).write(to:root.appendingPathComponent("Notes/.Moved.md.comments.json"))
            // A page's own file number, written while it had its old name.
            try Data(file(thread("I",replies:["same file"])).utf8).write(to:root.appendingPathComponent("Notes/.Before.md.comments.json"))
            let stamped = PageComments.stamped(file(thread("I",replies:["same file"])),page:root.appendingPathComponent("Notes/Inode.md"))
            try Data(stamped.utf8).write(to:root.appendingPathComponent("Notes/.Before.md.comments.json"))
            try Data(file(thread("X",quote:"哪里都找不到的文字",replies:["no match"])).utf8).write(to:root.appendingPathComponent("Notes/.Lost.md.comments.json"))
            let index = try VaultIndex(root:root)
            let orphans = PageComments.orphans(root:root,folders:["","Notes","Other"])
            try check(orphans == ["Notes/.Before.md.comments.json","Notes/.Lost.md.comments.json","Notes/.Moved.md.comments.json","Notes/.Old name.md.comments.json"],"Comments without their page are found: \(orphans)")
            let adopted = PageComments.adoptOrphans(root:root,orphans:orphans,pages:index.files.map(\.relativePath))
            try check(Set(adopted) == ["Notes/Renamed.md","Other/Moved.md","Notes/Inode.md"],"Each finds its page: \(adopted)")
            try check(ids(PageComments.read(page:"Notes/Renamed.md",root:root)) == ["Q"],"A renamed page is found by the words its comments are on")
            try check(ids(PageComments.read(page:"Other/Moved.md",root:root)) == ["W"],"A moved page is found by its name")
            try check(ids(PageComments.read(page:"Notes/Inode.md",root:root)) == ["I"],"A renamed page is found by its file")
            try check(fm.fileExists(atPath:root.appendingPathComponent("Notes/.Lost.md.comments.json").path),"Comments with no clear page stay where they are")
            try check(PageComments.read(page:"Notes/Unrelated.md",root:root) == nil,"No page gets comments that are not its own")
            try check(PageComments.orphans(root:root,folders:["","Notes","Other"]) == ["Notes/.Lost.md.comments.json"],"Only the unmatched one is left")
        }

        // Renaming onto a name that has comments waiting keeps both.
        do {
            let root = try vault("rename",["A.md":"a","B.md":"b"])
            try PageComments.write(file(thread("A",replies:["a"])),page:"A.md",root:root,merging:false)
            try Data(file(thread("Left",replies:["left behind"])).utf8).write(to:root.appendingPathComponent(".C.md.comments.json"))
            let renamed = try PageOrganizer(root:root).rename("A.md",to:"C.md")
            try check(ids(PageComments.read(page:renamed,root:root)) == ["A","Left"],"Comments already under the new name are not overwritten")
        }

        // A restored page keeps comments already waiting under its name.
        do {
            let root = try vault("trash",["Page.md":"文字"])
            try PageComments.write(file(thread("T",replies:["trashed"])),page:"Page.md",root:root,merging:false)
            let trash = try PageTrash(root:root)
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try Data(file(thread("W",replies:["waiting"])).utf8).write(to:root.appendingPathComponent(".Page.md.comments.json"))
            let restored = try trash.restore(entry.id)
            try check(ids(PageComments.read(page:restored.lastPathComponent,root:root)) == ["T","W"],"Restoring keeps both the page's and the waiting comments")
        }

        print("CommentSafetyTests: \(checks) checks passed")
    }
}
