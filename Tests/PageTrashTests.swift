import Foundation

@main
struct PageTrashTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-page-trash-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let epoch = Date(timeIntervalSince1970:1_800_000_000)
        var now = epoch
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"PageTrashTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func reject(_ message: String, _ action: () throws -> Void) throws {
            var failed = false
            do { try action() } catch { failed = true }
            try check(failed,message)
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:url,withIntermediateDirectories:true)
            return url
        }
        func fixture(_ name: String) throws -> (PageTrash,URL) {
            now = epoch
            let pages = try directory(name)
            return (try PageTrash(root:pages,nowDate:{ now }),pages)
        }
        func write(_ bytes: Data, _ pages: URL, _ relativePath: String) throws {
            let url = pages.appendingPathComponent(relativePath)
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try bytes.write(to:url)
        }
        func entryDirectory(_ pages: URL, _ id: UUID) -> URL {
            pages.appendingPathComponent(".acdian-trash",isDirectory:true).appendingPathComponent(id.uuidString,isDirectory:true)
        }
        func payload(_ pages: URL, _ id: UUID) -> URL { entryDirectory(pages,id).appendingPathComponent("payload") }
        func metadata(_ pages: URL, _ id: UUID) -> URL { entryDirectory(pages,id).appendingPathComponent("metadata.json") }
        func patchMetadata(_ pages: URL, _ id: UUID, key: String, value: Any) throws {
            let url = metadata(pages,id)
            guard var json = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else { fatalError("Expected JSON metadata object") }
            json[key] = value
            try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]).write(to:url)
        }
        let text = Data("# Keep exact bytes 中文🌸\r\n\r\nBody\u{0000}\n".utf8)
        let binary = Data((0...255).map { UInt8($0) })

        do {
            let (trash,pages) = try fixture("file-round-trip")
            try write(text,pages,"研究 🌸.md")
            let entry = try trash.moveToTrash(relativePath:"研究 🌸.md")
            try check(entry.originalRelativePath == "研究 🌸.md" && entry.name == "研究 🌸.md" && !entry.isDirectory, "Deleted-file metadata must preserve the original Unicode filename and kind")
            try check(entry.deletedAt == epoch && entry.expiresAt == epoch.addingTimeInterval(15*24*60*60), "Every deletion must retain the exact deletion time and a 15-day expiry")
            try check(!fm.fileExists(atPath:pages.appendingPathComponent("研究 🌸.md").path) && (try Data(contentsOf:payload(pages,entry.id))) == text, "Deleting a page must move its exact bytes into recoverable app trash")
            try check(try trash.entries() == [entry], "A deleted page must be listed with stable metadata")
            let reopened = try PageTrash(root:pages,nowDate:{ now })
            try check(try reopened.entries() == [entry], "Trash contents and timestamps must survive reopening the store")
            let restored = try reopened.restore(entry.id)
            try check(restored.standardizedFileURL.resolvingSymlinksInPath() == pages.appendingPathComponent("研究 🌸.md").standardizedFileURL.resolvingSymlinksInPath() && (try Data(contentsOf:restored)) == text, "Restore must return the original location with all bytes intact")
            try check(try reopened.entries().isEmpty && !fm.fileExists(atPath:entryDirectory(pages,entry.id).path), "Successful restore must remove its trash record")
        }

        do {
            let (trash,pages) = try fixture("folder-round-trip")
            try write(text,pages,"Folder/Nested/Page.md")
            try write(binary,pages,"Folder/Attachments/reference.bin")
            try write(Data("hidden config".utf8),pages,"Folder/.settings.json")
            try fm.createDirectory(at:pages.appendingPathComponent("Folder/Empty"),withIntermediateDirectories:true)
            let entry = try trash.moveToTrash(relativePath:"Folder")
            try check(entry.isDirectory && entry.originalRelativePath == "Folder", "A deleted folder must retain its folder metadata")
            try check(!fm.fileExists(atPath:pages.appendingPathComponent("Folder").path) && (try Data(contentsOf:payload(pages,entry.id).appendingPathComponent("Nested/Page.md"))) == text, "Folder deletion must move the whole nested page tree")
            _ = try trash.restore(entry.id)
            try check(try Data(contentsOf:pages.appendingPathComponent("Folder/Nested/Page.md")) == text && Data(contentsOf:pages.appendingPathComponent("Folder/Attachments/reference.bin")) == binary && String(contentsOf:pages.appendingPathComponent("Folder/.settings.json"),encoding:.utf8) == "hidden config", "Folder restore must preserve nested Markdown, binary assets and hidden files")
            var isDirectory: ObjCBool = false
            try check(fm.fileExists(atPath:pages.appendingPathComponent("Folder/Empty").path,isDirectory:&isDirectory) && isDirectory.boolValue, "Folder restore must preserve empty subdirectories")
        }

        do {
            let (trash,pages) = try fixture("expiry-boundary")
            try write(text,pages,"Expire.md")
            try write(binary,pages,"Keep.bin")
            let entry = try trash.moveToTrash(relativePath:"Expire.md")
            now = entry.expiresAt.addingTimeInterval(-0.001)
            try check(try trash.purgeExpired().isEmpty && trash.entries() == [entry] && Data(contentsOf:payload(pages,entry.id)) == text, "An item must remain recoverable until just before the exact 15-day boundary")
            now = entry.expiresAt
            try check(try trash.purgeExpired() == [entry.id], "An item must expire at, not after, its exact 15-day boundary")
            try check(!fm.fileExists(atPath:entryDirectory(pages,entry.id).path) && (try trash.entries()).isEmpty, "Expired items must be permanently removed from app trash")
            try check(try Data(contentsOf:pages.appendingPathComponent("Keep.bin")) == binary && trash.purgeExpired().isEmpty, "Automatic purge must preserve active pages and be safe to repeat")
            try reject("A purged item must never be restorable") { _ = try trash.restore(entry.id) }
        }

        do {
            let (trash,pages) = try fixture("expired-restore")
            try write(text,pages,"Expired.md")
            let entry = try trash.moveToTrash(relativePath:"Expired.md")
            now = entry.expiresAt
            try reject("Restore must refuse an expired item even before a separate cleanup pass") { _ = try trash.restore(entry.id) }
            try check(!fm.fileExists(atPath:pages.appendingPathComponent("Expired.md").path), "A stale restore request must not revive an expired page")
            try check(try trash.purgeExpired() == [entry.id] && !fm.fileExists(atPath:payload(pages,entry.id).path), "The refused expired item must still be eligible for permanent cleanup")
        }

        do {
            let (trash,pages) = try fixture("duplicate-names")
            try write(text,pages,"Same.md")
            let first = try trash.moveToTrash(relativePath:"Same.md")
            now = epoch.addingTimeInterval(1)
            try write(binary,pages,"Same.md")
            let second = try trash.moveToTrash(relativePath:"Same.md")
            try check(first.id != second.id && Set(try trash.entries().map(\.id)) == Set([first.id,second.id]), "Repeated deletions of the same name must keep separate recoverable payloads")
            _ = try trash.restore(first.id)
            try write(Data("Existing suffix".utf8),pages,"Same 2.md")
            let restored = try trash.restore(second.id)
            try check(restored.lastPathComponent == "Same 3.md", "Restore must choose the next unused filename when the original and first suffix already exist")
            try check(try Data(contentsOf:pages.appendingPathComponent("Same.md")) == text && Data(contentsOf:pages.appendingPathComponent("Same 2.md")) == Data("Existing suffix".utf8) && Data(contentsOf:restored) == binary && trash.entries().isEmpty, "Conflict restore must preserve every active version and recover the trashed payload separately")
        }

        do {
            let (trash,pages) = try fixture("folder-conflict")
            try write(text,pages,"Folder/Nested/Page.md")
            let entry = try trash.moveToTrash(relativePath:"Folder")
            try write(binary,pages,"Folder/Existing.bin")
            let restored = try trash.restore(entry.id)
            try check(restored.lastPathComponent == "Folder 2" && (try Data(contentsOf:restored.appendingPathComponent("Nested/Page.md"))) == text, "A restored folder must use an unused sibling name when its original name is occupied")
            try check(try Data(contentsOf:pages.appendingPathComponent("Folder/Existing.bin")) == binary, "Folder restore must never merge into or replace an existing folder")
        }

        do {
            let (trash,pages) = try fixture("long-name-conflict")
            let name = String(repeating:"界",count:84) + ".md"
            try write(text,pages,name)
            let entry = try trash.moveToTrash(relativePath:name)
            try write(binary,pages,name)
            let restored = try trash.restore(entry.id)
            try check(restored.lastPathComponent != name && restored.pathExtension == "md" && restored.lastPathComponent.utf8.count <= 255, "Conflict suffixes must remain valid for long Unicode filenames")
            try check(try Data(contentsOf:pages.appendingPathComponent(name)) == binary && Data(contentsOf:restored) == text, "Long-name conflict restore must preserve both versions exactly")
        }

        do {
            let (trash,pages) = try fixture("missing-parent")
            try write(text,pages,"Nested/Page.md")
            let entry = try trash.moveToTrash(relativePath:"Nested/Page.md")
            try fm.removeItem(at:pages.appendingPathComponent("Nested"))
            _ = try trash.restore(entry.id)
            try check(try Data(contentsOf:pages.appendingPathComponent("Nested/Page.md")) == text, "Restore must recreate missing original parent folders")
            let again = try trash.moveToTrash(relativePath:"Nested/Page.md")
            try fm.removeItem(at:pages.appendingPathComponent("Nested"))
            try write(binary,pages,"Nested")
            try reject("Restore must fail safely when an original parent path is now a file") { _ = try trash.restore(again.id) }
            try check(try Data(contentsOf:pages.appendingPathComponent("Nested")) == binary && Data(contentsOf:payload(pages,again.id)) == text && trash.entries().map(\.id) == [again.id], "A blocked-parent restore must preserve the blocker and complete recovery payload")
        }

        do {
            let (trash,pages) = try fixture("invalid-inputs")
            let outside = try directory("invalid-outside")
            try write(binary,outside,"Keep.bin")
            for candidate in ["", ".", "..", "../invalid-outside/Keep.bin", "/absolute/path", ".acdian-trash", ".acdian-trash/entry/payload"] {
                try reject("Unsafe or reserved source path must be rejected: \(candidate)") { _ = try trash.moveToTrash(relativePath:candidate) }
            }
            try reject("Deleting a missing file must report failure") { _ = try trash.moveToTrash(relativePath:"Missing.md") }
            try check(try trash.entries().isEmpty && Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary && fm.fileExists(atPath:pages.path), "Rejected deletes must preserve all external bytes and the pages root")
        }

        do {
            let pages = try directory("blocked-trash")
            try write(text,pages,"Page.md")
            try write(binary,pages,".acdian-trash")
            try reject("An occupied app-trash path must reject deletion") {
                let trash = try PageTrash(root:pages,nowDate:{ now })
                _ = try trash.moveToTrash(relativePath:"Page.md")
            }
            try check(try Data(contentsOf:pages.appendingPathComponent("Page.md")) == text && Data(contentsOf:pages.appendingPathComponent(".acdian-trash")) == binary, "A failed trash setup must preserve the original page and blocking file")
        }

        do {
            let (trash,pages) = try fixture("source-symlinks")
            let outside = try directory("source-symlink-outside")
            try write(binary,outside,"Keep.bin")
            try fm.createSymbolicLink(at:pages.appendingPathComponent("Alias.bin"),withDestinationURL:outside.appendingPathComponent("Keep.bin"))
            try fm.createSymbolicLink(at:pages.appendingPathComponent("AliasFolder"),withDestinationURL:outside)
            try reject("A source-file symlink must not delete its target") { _ = try trash.moveToTrash(relativePath:"Alias.bin") }
            try reject("A source-folder symlink must not delete its target") { _ = try trash.moveToTrash(relativePath:"AliasFolder") }
            try reject("A symlink source ancestor must not permit external traversal") { _ = try trash.moveToTrash(relativePath:"AliasFolder/Keep.bin") }
            try check(try Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary && fm.destinationOfSymbolicLink(atPath:pages.appendingPathComponent("Alias.bin").path) == outside.appendingPathComponent("Keep.bin").path && trash.entries().isEmpty, "Rejected symlink deletes must preserve outside bytes, source links and trash contents")
        }

        do {
            let pages = try directory("trash-symlink")
            let outside = try directory("trash-symlink-outside")
            try write(text,pages,"Page.md")
            try write(binary,outside,"Keep.bin")
            try fm.createSymbolicLink(at:pages.appendingPathComponent(".acdian-trash"),withDestinationURL:outside)
            try reject("A symlink-owned trash root must reject deletion") {
                let trash = try PageTrash(root:pages,nowDate:{ now })
                _ = try trash.moveToTrash(relativePath:"Page.md")
            }
            try check(try Data(contentsOf:pages.appendingPathComponent("Page.md")) == text && Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary && fm.contentsOfDirectory(atPath:outside.path) == ["Keep.bin"], "A symlink trash root must not redirect any deletion into an outside directory")
        }

        do {
            let (trash,pages) = try fixture("nested-symlink-restore")
            let outside = try directory("nested-symlink-outside")
            try write(binary,outside,"Keep.bin")
            try write(text,pages,"Folder/Page.md")
            try fm.createSymbolicLink(at:pages.appendingPathComponent("Folder/External"),withDestinationURL:outside)
            let entry = try trash.moveToTrash(relativePath:"Folder")
            _ = try trash.restore(entry.id)
            try check(try fm.destinationOfSymbolicLink(atPath:pages.appendingPathComponent("Folder/External").path) == outside.path && Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary, "Moving and restoring a folder must preserve nested links as links without touching their targets")
            let again = try trash.moveToTrash(relativePath:"Folder")
            now = again.expiresAt
            _ = try trash.purgeExpired()
            try check(!fm.fileExists(atPath:entryDirectory(pages,again.id).path) && (try Data(contentsOf:outside.appendingPathComponent("Keep.bin"))) == binary, "Expired-folder purge must delete nested links without following them outside storage")
        }

        do {
            let (trash,pages) = try fixture("restore-symlink-parent")
            let outside = try directory("restore-symlink-outside")
            try write(binary,outside,"Keep.bin")
            try write(text,pages,"Folder/Page.md")
            let entry = try trash.moveToTrash(relativePath:"Folder/Page.md")
            try fm.removeItem(at:pages.appendingPathComponent("Folder"))
            try fm.createSymbolicLink(at:pages.appendingPathComponent("Folder"),withDestinationURL:outside)
            try reject("Restore must not write through a substituted symlink parent") { _ = try trash.restore(entry.id) }
            try check(try Data(contentsOf:payload(pages,entry.id)) == text && Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary && fm.contentsOfDirectory(atPath:outside.path) == ["Keep.bin"], "A rejected symlink-parent restore must retain its payload and leave the outside directory unchanged")
        }

        do {
            let (trash,pages) = try fixture("corrupt-json")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try Data("{broken JSON".utf8).write(to:metadata(pages,entry.id))
            now = entry.expiresAt.addingTimeInterval(1)
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,entry.id)) == text, "Invalid metadata must be ignored without automatically deleting recoverable bytes")
            try reject("Invalid metadata must not be restorable using guessed paths") { _ = try trash.restore(entry.id) }
        }

        do {
            let (trash,pages) = try fixture("corrupt-expiry")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try patchMetadata(pages,entry.id,key:"expiresAt",value:epoch.timeIntervalSinceReferenceDate)
            now = entry.expiresAt.addingTimeInterval(1)
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,entry.id)) == text, "A corrupt shorter retention period must never authorize premature or later automatic deletion")
        }

        do {
            let (trash,pages) = try fixture("corrupt-path")
            let outside = try directory("corrupt-path-outside")
            try write(binary,outside,"Keep.bin")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try patchMetadata(pages,entry.id,key:"originalRelativePath",value:"../corrupt-path-outside/Keep.bin")
            now = entry.expiresAt.addingTimeInterval(1)
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty, "Traversal paths in metadata must invalidate an entry for listing and automatic purge")
            try reject("A malicious manifest path must not restore outside page storage") { _ = try trash.restore(entry.id) }
            try check(try Data(contentsOf:payload(pages,entry.id)) == text && Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary, "Invalid-path metadata must preserve the payload and outside files")
        }

        do {
            let (trash,pages) = try fixture("corrupt-identity")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try patchMetadata(pages,entry.id,key:"id",value:UUID().uuidString)
            now = entry.expiresAt
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,entry.id)) == text, "Mismatched metadata and directory identities must never authorize auto-deletion")
        }

        do {
            let (trash,pages) = try fixture("metadata-symlink")
            let outside = try directory("metadata-symlink-outside")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            let bytes = try Data(contentsOf:metadata(pages,entry.id))
            try write(bytes,outside,"metadata.json")
            try fm.removeItem(at:metadata(pages,entry.id))
            try fm.createSymbolicLink(at:metadata(pages,entry.id),withDestinationURL:outside.appendingPathComponent("metadata.json"))
            now = entry.expiresAt
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,entry.id)) == text, "Symlinked metadata must not grant authority to purge payloads")
            try reject("Restore must reject symlinked metadata") { _ = try trash.restore(entry.id) }
            try check(try Data(contentsOf:outside.appendingPathComponent("metadata.json")) == bytes, "Trash inspection must never modify symlinked outside metadata")
        }

        do {
            let (trash,pages) = try fixture("entry-symlink")
            let outside = try directory("entry-symlink-outside")
            try write(binary,outside,"Keep.bin")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            let held = root.appendingPathComponent("held-original-trash-entry")
            try fm.moveItem(at:entryDirectory(pages,entry.id),to:held)
            try fm.createSymbolicLink(at:entryDirectory(pages,entry.id),withDestinationURL:outside)
            now = entry.expiresAt
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty, "A symlinked trash-entry directory must be ignored for automatic purge")
            try reject("Restore must reject a symlinked trash-entry directory") { _ = try trash.restore(entry.id) }
            try check(try Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary && Data(contentsOf:held.appendingPathComponent("payload")) == text, "Rejected entry-directory symlinks must preserve both external files and the held original payload")
        }

        do {
            let (trash,pages) = try fixture("payload-symlink")
            let outside = try directory("payload-symlink-outside")
            try write(binary,outside,"Keep.bin")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try fm.removeItem(at:payload(pages,entry.id))
            try fm.createSymbolicLink(at:payload(pages,entry.id),withDestinationURL:outside.appendingPathComponent("Keep.bin"))
            now = entry.expiresAt
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty, "A substituted top-level payload link must invalidate the entry")
            try reject("Restore must refuse a substituted top-level payload symlink") { _ = try trash.restore(entry.id) }
            try check(try Data(contentsOf:outside.appendingPathComponent("Keep.bin")) == binary, "Invalid-payload inspection must never modify the external symlink target")
        }

        do {
            let (trash,pages) = try fixture("pending-recovery")
            try write(text,pages,"Nested/Page.md")
            let original = try trash.moveToTrash(relativePath:"Nested/Page.md")
            guard var pending = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata(pages,original.id))) as? [String:Any] else { fatalError("Expected metadata object") }
            pending.removeValue(forKey:"deletedAt"); pending.removeValue(forKey:"expiresAt")
            try JSONSerialization.data(withJSONObject:pending).write(to:entryDirectory(pages,original.id).appendingPathComponent("pending.json"))
            try fm.removeItem(at:metadata(pages,original.id))
            now = original.expiresAt.addingTimeInterval(60)
            let recovered = try trash.entries()
            try check(recovered.count == 1 && recovered[0].id == original.id && recovered[0].deletedAt == now && recovered[0].expiresAt == now.addingTimeInterval(PageTrash.retentionInterval), "A crash after payload movement must recover the pending record with a full new 15-day retention period")
            try check(try trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,original.id)) == text, "Pending recovery must retain original bytes instead of applying the incomplete transaction's old deadline")
            _ = try trash.restore(original.id)
            try check(try Data(contentsOf:pages.appendingPathComponent("Nested/Page.md")) == text, "A recovered pending deletion must remain fully restorable")
        }

        do {
            let (trash,pages) = try fixture("incomplete-entry")
            try write(text,pages,"Page.md")
            let entry = try trash.moveToTrash(relativePath:"Page.md")
            try fm.removeItem(at:metadata(pages,entry.id))
            now = entry.expiresAt.addingTimeInterval(1)
            try check(try trash.entries().isEmpty && trash.purgeExpired().isEmpty && Data(contentsOf:payload(pages,entry.id)) == text, "An unidentified incomplete payload must be kept safely without guessed metadata or automatic purge")
            try reject("An unidentified incomplete payload must not be restored using guessed paths") { _ = try trash.restore(entry.id) }
        }

        do {
            let pages = try directory("commit-rollback")
            try write(text,pages,"Page.md")
            // An invalid injected timestamp exercises the post-move commit
            // failure path without depending on filesystem permissions.
            let trash = try PageTrash(root:pages,nowDate:{ Date(timeIntervalSince1970:.infinity) })
            try reject("A failed metadata commit must report failure") { _ = try trash.moveToTrash(relativePath:"Page.md") }
            try check(try Data(contentsOf:pages.appendingPathComponent("Page.md")) == text && trash.entries().isEmpty, "A failed commit must roll back the original payload when its path is still free")
        }

        do {
            let pages = try directory("rollback-conflict")
            try write(text,pages,"Page.md")
            var firstClock = true
            let trash = try PageTrash(root:pages,nowDate:{
                if firstClock {
                    firstClock = false
                    try! binary.write(to:pages.appendingPathComponent("Page.md"))
                    return Date(timeIntervalSince1970:.infinity)
                }
                return epoch
            })
            var recoveryRequired = false
            do { _ = try trash.moveToTrash(relativePath:"Page.md") }
            catch PageTrash.TrashError.recoveryRequired { recoveryRequired = true }
            try check(recoveryRequired && (try Data(contentsOf:pages.appendingPathComponent("Page.md"))) == binary, "Rollback must not overwrite a replacement file created during commit failure")
            let recovered = try trash.entries()
            try check(recovered.count == 1 && (try Data(contentsOf:payload(pages,recovered[0].id))) == text, "A failed rollback must retain and recover the original payload through its pending record")
            let restored = try trash.restore(recovered[0].id)
            try check(restored.lastPathComponent == "Page 2.md" && (try Data(contentsOf:restored)) == text && (try Data(contentsOf:pages.appendingPathComponent("Page.md"))) == binary, "Recovery after rollback conflict must restore beside the replacement without overwriting either version")
        }

        print("PageTrash: \(checks) checks passed for exact-byte recovery, nested folders, 15-day expiry, conflicts, failed operations, corrupt metadata and symlink safety")
    }
}
