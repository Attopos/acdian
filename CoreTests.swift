import Foundation

@main
struct CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("acdian-core-\(UUID().uuidString)")
        let root = fixture.appendingPathComponent("Vault")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }

        func put(_ path: String, _ text: String = "fixture") throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw TestFailure(message) }
        }
        func relative(_ url: URL?) -> String? {
            guard let url else { return nil }
            return String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
        }

        try put("首页.md", "# 首页")
        try put("Notes/Current.md")
        try put("Notes/Local.md")
        try put("Local.md")
        try put("Notes/picture.png")
        try put("attachment/picture.png")
        try put("attachment/deep/独有 图片.png")
        try put("attachment/Manual.pdf")
        try put("One/Duplicate.md")
        try put("Two/Duplicate.md")
        try put("Spaces/Long note.md")
        try put("Spaces/Café.md")
        try put("attachment/hash#name.png")
        try put("attachment/percent%name.png")
        try put("attachment/ leading space.png")
        try put(".obsidian/config.json")
        try put(".trash/removed.md")
        let outside = fixture.appendingPathComponent("outside.md")
        try Data("private".utf8).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("inside.md"), withDestinationURL: root.appendingPathComponent("首页.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken.md"), withDestinationURL: root.appendingPathComponent("missing.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("external-folder"), withDestinationURL: fixture)

        let index = try VaultIndex(root: root)
        try check(index.entries.first?.isDirectory == true, "Folders should sort before files")
        try check(!index.files.contains { $0.relativePath.hasPrefix(".") }, "Hidden directories must be excluded")
        try check(!index.files.contains { $0.name == "escape.md" }, "Outside symlinks must be excluded")
        try check(index.files.contains { $0.name == "inside.md" }, "In-vault regular file symlinks should be included")
        try check(relative(index.resolve("[[Local#Heading|Label]]", from: "Notes/Current.md")) == "Notes/Local.md", "Exact relative path must win")
        try check(relative(index.resolve("/Local", from: "Notes/Current.md")) == "Local.md", "Vault-root paths should resolve")
        try check(relative(index.resolve("../Local.md", from: "Notes/Current.md")) == "Local.md", "Contained traversal should resolve")
        try check(index.resolve("../../outside.md", from: "Notes/Current.md") == nil, "Escaping traversal must fail")
        try check(index.resolve("/../outside.md", from: "Current.md") == nil, "Rooted traversal must fail")
        try check(index.resolve("%2E%2E/%2E%2E/outside.md", from: "Notes/Current.md") == nil, "Encoded traversal must fail")
        try check(index.resolve("Duplicate", from: "Notes/Current.md") == nil, "Duplicate basenames must remain ambiguous")
        try check(relative(index.resolve("![[独有%20图片.png|300]]", from: "Notes/Current.md")) == "attachment/deep/独有 图片.png", "Nested attachments and URL decoding should work")
        try check(relative(index.resolve("Spaces/Long%20note", from: "Notes/Current.md")) == "Spaces/Long note.md", "Extensionless vault paths should resolve")
        try check(index.resolve("Spaces/Cafe\u{0301}", from: "Notes/Current.md") != nil, "Canonically equivalent Unicode filenames should resolve")
        try check(relative(index.resolve("hash%23name.png", from: "Notes/Current.md")) == "attachment/hash#name.png", "Encoded fragment characters must stay in filenames")
        try check(relative(index.resolve("percent%25name.png", from: "Notes/Current.md")) == "attachment/percent%name.png", "Encoded percent characters must stay in filenames")
        try check(relative(index.resolve("%20leading%20space.png", from: "Notes/Current.md")) == "attachment/ leading space.png", "Encoded filename whitespace must be preserved")
        try check(relative(index.resolve(root.appendingPathComponent("attachment/hash#name.png").absoluteString, from: "Notes/Current.md")) == "attachment/hash#name.png", "Encoded file URLs must preserve hash characters")
        try check(relative(index.resolve("#^block", from: "首页.md")) == "首页.md", "Heading-only links should resolve to the current note")
        try check(relative(index.resolve("picture.png", from: "Notes/Current.md")) == "Notes/picture.png", "Relative attachment should win before basename search")
        try check(relative(index.resolve("attachment/Manual.pdf#page=2", from: "首页.md")) == "attachment/Manual.pdf", "PDF links should resolve without fragments")
        try check(index.resolve("https://example.com/Local.md", from: "首页.md") == nil, "External links must not fall back to local files")
        try check(index.resolve(outside.absoluteString, from: "首页.md") == nil, "Outside file URLs must not resolve")

        let alias = fixture.appendingPathComponent("Vault alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasedIndex = try VaultIndex(root: alias)
        try check(aliasedIndex.resolve("首页", from: "Notes/Current.md") != nil, "Symlinked vault roots should work")

        // A symlink changed after indexing must be rechecked before resolution.
        try fm.removeItem(at: root.appendingPathComponent("inside.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("inside.md"), withDestinationURL: outside)
        try check(index.resolve("inside.md", from: "首页.md") == nil, "Changed symlink targets must not escape the vault")

        let note = root.appendingPathComponent("首页.md")
        try check(try VaultFileIO.readMarkdown(at: note) == "# 首页", "UTF-8 text should decode")
        try VaultFileIO.saveMarkdown("# 已编辑", at: note, expectedContent: "# 首页")
        try check(try VaultFileIO.readMarkdown(at: note) == "# 已编辑", "Atomic edit should persist")
        do {
            try VaultFileIO.saveMarkdown("stale", at: note, expectedContent: "# 首页")
            throw TestFailure("Stale save must fail")
        } catch VaultCoreError.conflict { }
        try check(try VaultFileIO.readMarkdown(at: note) == "# 已编辑", "Conflict must preserve the current file")

        let editableAlias = root.appendingPathComponent("editable-alias.md")
        try fm.createSymbolicLink(at: editableAlias, withDestinationURL: note)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
        try VaultFileIO.saveMarkdown("# 别名编辑", at: editableAlias, expectedContent: "# 已编辑", allowedRoot: root)
        try check(try VaultFileIO.readMarkdown(at: note, allowedRoot: root) == "# 别名编辑", "Saving an alias must update its real target")
        try check(try editableAlias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true, "Atomic save must preserve a symbolic link")
        try check((try fm.attributesOfItem(atPath: note.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Atomic save should preserve existing file permissions")
        do {
            try VaultFileIO.saveMarkdown("overwrite", at: note, expectedContent: nil, allowedRoot: root)
            throw TestFailure("Create-only save must not overwrite an existing file")
        } catch VaultCoreError.conflict { }
        do {
            _ = try VaultFileIO.readMarkdown(at: root.appendingPathComponent("inside.md"), allowedRoot: root)
            throw TestFailure("Reading an alias repointed outside the vault must fail")
        } catch VaultCoreError.unsafeLocation { }
        do {
            try VaultFileIO.saveMarkdown("overwrite", at: root.appendingPathComponent("inside.md"), expectedContent: "private", allowedRoot: root)
            throw TestFailure("Saving an alias repointed outside the vault must fail")
        } catch VaultCoreError.unsafeLocation { }
        try check(try String(contentsOf: outside, encoding: .utf8) == "private", "A rejected unsafe save must preserve outside content")
        let created = root.appendingPathComponent("New.md")
        try VaultFileIO.saveMarkdown("# 新笔记", at: created, expectedContent: nil, allowedRoot: root)
        try check(try VaultFileIO.readMarkdown(at: created, allowedRoot: root) == "# 新笔记", "Create-only save should create new notes")
        try check(!fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".acdian-") }, "Save must clean temporary files")
        let bom = root.appendingPathComponent("BOM.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("正文".utf8)).write(to: bom)
        try check(try VaultFileIO.readMarkdown(at: bom) == "正文", "UTF-8 BOM should not appear in text")
        try VaultFileIO.saveMarkdown("修改", at: bom, expectedContent: "正文")
        try check(try Data(contentsOf: bom).starts(with: [0xEF, 0xBB, 0xBF]), "Existing BOM should be preserved")
        try check(try VaultFileIO.readMarkdown(at: bom) == "修改", "BOM save should round-trip")

        let invalid = root.appendingPathComponent("invalid.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: invalid)
        do {
            _ = try VaultFileIO.readMarkdown(at: invalid)
            throw TestFailure("Invalid UTF-8 must be rejected")
        } catch VaultCoreError.invalidUTF8 { }
        print("VaultCore: all index, link, attachment, safety, and save tests passed")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
