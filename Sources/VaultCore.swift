import Foundation

struct VaultEntry: Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [VaultEntry]?
    let modified: Date?
    let size: Int

    var ext: String { url.pathExtension.lowercased() }
}

enum VaultCoreError: LocalizedError {
    case notDirectory(URL)
    case invalidUTF8(URL)
    case conflict(URL)
    case unsafeLocation(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "无法打开文件夹：\(url.lastPathComponent)"
        case .invalidUTF8(let url):
            return "“\(url.lastPathComponent)”不是 UTF-8 文本，无法安全编辑。"
        case .conflict(let url):
            return "“\(url.lastPathComponent)”已被其他应用修改。请重新载入后再保存，避免覆盖外部修改。"
        case .unsafeLocation(let url):
            return "“\(url.lastPathComponent)”指向页面存储位置以外，已停止读取或保存。"
        }
    }
}

/// A snapshot of a local vault. File links are resolved only against indexed,
/// regular files whose current physical location remains inside the vault.
struct VaultIndex {
    let root: URL
    let entries: [VaultEntry]
    let files: [VaultEntry]

    private let byPath: [String: VaultEntry]
    private let byFoldedPath: [String: [VaultEntry]]
    private let byBasename: [String: [VaultEntry]]

    init(root: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard canonicalRoot.isFileURL,
              FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VaultCoreError.notDirectory(root)
        }
        self.root = canonicalRoot

        var collected: [VaultEntry] = []
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey
        ]

        func scan(_ directory: URL, prefix: String) throws -> [VaultEntry] {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
            var result: [VaultEntry] = []
            for child in children {
                let name = child.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let physical = child.standardizedFileURL.resolvingSymlinksInPath()
                guard Self.contains(physical, in: canonicalRoot) else { continue }
                // Do not descend through directory aliases: this prevents cycles
                // and duplicate trees while permitting in-vault file symlinks.
                // A file can disappear while another application updates the
                // vault. A broken alias should not prevent opening other notes.
                guard let info = try? child.resourceValues(forKeys: keys),
                      let targetInfo = try? physical.resourceValues(forKeys: keys) else { continue }
                let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if targetInfo.isDirectory == true {
                    guard info.isSymbolicLink != true else { continue }
                    let descendants = (try? scan(child, prefix: relativePath)) ?? []
                    result.append(VaultEntry(
                        relativePath: relativePath, url: child, name: name,
                        isDirectory: true, children: descendants,
                        modified: targetInfo.contentModificationDate, size: 0
                    ))
                } else if targetInfo.isRegularFile == true {
                    let entry = VaultEntry(
                        relativePath: relativePath, url: child, name: name,
                        isDirectory: false, children: nil,
                        modified: targetInfo.contentModificationDate, size: targetInfo.fileSize ?? 0
                    )
                    result.append(entry)
                    collected.append(entry)
                }
            }
            return result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        entries = try scan(canonicalRoot, prefix: "")
        files = collected.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        // Canonically equivalent Unicode paths are the same filesystem name on
        // macOS. Keep the exact spelling separately from case-insensitive lookup.
        byPath = Dictionary(files.map { (Self.key($0.relativePath), $0) }, uniquingKeysWith: { first, _ in first })
        byFoldedPath = Dictionary(grouping: files, by: { Self.foldedKey($0.relativePath) })
        byBasename = Dictionary(grouping: files, by: { Self.foldedKey($0.name) })
    }

    /// Resolves Obsidian wiki targets and ordinary local Markdown links.
    /// The containing note's relative path supplies the relative-link base.
    /// Ambiguous bare names deliberately return nil instead of opening a guess.
    func resolve(_ rawTarget: String, from currentPath: String) -> URL? {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("![["), target.hasSuffix("]]") {
            target = String(target.dropFirst(3).dropLast(2))
        } else if target.hasPrefix("[["), target.hasSuffix("]]") {
            target = String(target.dropFirst(2).dropLast(2))
        }
        if target.hasPrefix("<"), target.hasSuffix(">") {
            target = String(target.dropFirst().dropLast())
        }
        // Split syntax before decoding, so an encoded # or | in a filename is
        // not mistaken for a heading or wiki display label.
        target = String(target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0])
        target = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let encodedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = encodedTarget.removingPercentEncoding else { return nil }
        target = decoded
        guard !target.contains("\0") else { return nil }

        if target.isEmpty {
            guard let current = Self.normalizedPath(currentPath, base: []) else { return nil }
            return lookup(current)
        }
        if target.lowercased().hasPrefix("file:") {
            guard let url = URL(string: encodedTarget), url.isFileURL,
                  Self.contains(url.standardizedFileURL.resolvingSymlinksInPath(), in: root),
                  let file = files.first(where: {
                      $0.url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
                  }) else { return nil }
            return secureURL(file)
        }
        // Schemes, protocol-relative URLs, and external links never become a
        // local basename fallback.
        guard !target.hasPrefix("//"),
              target.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }

        guard let current = Self.normalizedPath(currentPath, base: []) else { return nil }
        let currentDirectory = current.split(separator: "/").dropLast().map(String.init)
        let isRooted = target.hasPrefix("/")
        let usesTraversal = target.split(separator: "/").contains("..")
        let base = isRooted ? [] : currentDirectory
        guard let relative = Self.normalizedPath(target, base: base) else { return nil }
        var paths = [relative]
        // Explicit ../ traversal has exactly one meaning; do not reinterpret it
        // as a vault-root path if its first candidate does not exist.
        if !isRooted && !usesTraversal,
           let rooted = Self.normalizedPath(target, base: []), !paths.contains(rooted) {
            paths.append(rooted)
        }
        for path in paths {
            if let url = lookupWithMarkdownExtension(path) { return url }
        }

        // Bare attachment and note names can live anywhere in an Obsidian vault.
        guard !target.contains("/") else { return nil }
        for name in [target, target + ".md", target + ".markdown"] {
            if let candidates = byBasename[Self.foldedKey(name)] {
                guard candidates.count == 1 else { return nil }
                return secureURL(candidates[0])
            }
        }
        return nil
    }

    private func lookupWithMarkdownExtension(_ path: String) -> URL? {
        for candidate in [path, path + ".md", path + ".markdown"] {
            if let url = lookup(candidate) { return url }
        }
        return nil
    }

    private func lookup(_ path: String) -> URL? {
        if let exact = byPath[Self.key(path)] { return secureURL(exact) }
        if let matches = byFoldedPath[Self.foldedKey(path)], matches.count == 1 {
            return secureURL(matches[0])
        }
        return nil
    }

    private func secureURL(_ entry: VaultEntry) -> URL? {
        let physical = entry.url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.contains(physical, in: root),
              (try? physical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return entry.url
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let rootParts = root.pathComponents.map(key)
        let fileParts = url.pathComponents.map(key)
        return fileParts.count > rootParts.count && Array(fileParts.prefix(rootParts.count)) == rootParts
    }

    private static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private static func foldedKey(_ value: String) -> String {
        key(value).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedPath(_ value: String, base: [String]) -> String? {
        var parts = value.hasPrefix("/") ? [] : base
        for part in value.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}

enum VaultFileIO {
    static func readMarkdown(at url: URL, allowedRoot: URL? = nil) throws -> String {
        let target = try checkedURL(url, allowedRoot: allowedRoot)
        return try decode(Data(contentsOf: target), at: url)
    }

    /// expectedContent is the original decoded text. nil permits creating a new
    /// file only. Existing UTF-8 BOMs are preserved on save.
    static func saveMarkdown(_ text: String, at url: URL, expectedContent: String?, allowedRoot: URL? = nil) throws {
        // Write to the physical file so atomic replacement preserves an in-vault
        // symbolic link rather than replacing the link itself with a plain file.
        let target = try checkedURL(url, allowedRoot: allowedRoot)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.path)
        let originalData: Data?
        if let expectedContent {
            guard exists else { throw VaultCoreError.conflict(url) }
            let existing = try Data(contentsOf: target)
            guard try decode(existing, at: url) == expectedContent else {
                throw VaultCoreError.conflict(url)
            }
            originalData = existing
        } else {
            guard !exists else { throw VaultCoreError.conflict(url) }
            originalData = nil
        }
        var data = Data()
        if originalData?.starts(with: [0xEF, 0xBB, 0xBF]) == true {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: text.utf8)
        if let originalData {
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".acdian-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .withoutOverwriting)
            defer { try? fm.removeItem(at: temporary) }
            // Recheck after preparing the replacement, immediately before the
            // atomic operation. Other editors do not share a compare-and-swap
            // protocol, so callers should still avoid simultaneous editing.
            guard try checkedURL(url, allowedRoot: allowedRoot) == target,
                  try Data(contentsOf: target) == originalData else {
                throw VaultCoreError.conflict(url)
            }
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } else {
            // Unlike an existence check followed by an overwrite, this also
            // refuses a file created by another app in the meantime.
            guard try checkedURL(url, allowedRoot: allowedRoot) == target else {
                throw VaultCoreError.conflict(url)
            }
            try data.write(to: target, options: .withoutOverwriting)
        }
    }

    private static func checkedURL(_ url: URL, allowedRoot: URL?) throws -> URL {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard target.isFileURL else { throw VaultCoreError.unsafeLocation(url) }
        if let allowedRoot {
            let canonicalRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
            let rootParts = canonicalRoot.pathComponents.map { $0.precomposedStringWithCanonicalMapping }
            let fileParts = target.pathComponents.map { $0.precomposedStringWithCanonicalMapping }
            guard fileParts.count > rootParts.count,
                  Array(fileParts.prefix(rootParts.count)) == rootParts else {
                throw VaultCoreError.unsafeLocation(url)
            }
        }
        return target
    }

    private static func decode(_ data: Data, at url: URL) throws -> String {
        let content = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: content, encoding: .utf8) else {
            throw VaultCoreError.invalidUTF8(url)
        }
        return text
    }
}
