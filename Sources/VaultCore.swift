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
    case invalidMove(URL)

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
        case .invalidMove(let url):
            return "无法把“\(url.lastPathComponent)”移动到它自己里面。"
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
        var collected: [VaultEntry] = []
        let order = PageOrganizer.loadOrder(root: canonicalRoot)
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
            return PageOrganizer.arrange(result.sorted(by: PageOrganizer.defaultOrder), names: order[prefix], name: \.name)
        }

        let scanned = try scan(canonicalRoot, prefix: "")
        self.init(canonicalRoot: canonicalRoot, entries: scanned, files: collected)
    }

    private init(canonicalRoot: URL, entries: [VaultEntry], files collected: [VaultEntry]) {
        root = canonicalRoot
        self.entries = entries
        files = collected.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        // Canonically equivalent Unicode paths are the same filesystem name on
        // macOS. Keep the exact spelling separately from case-insensitive lookup.
        byPath = Dictionary(files.map { (Self.key($0.relativePath), $0) }, uniquingKeysWith: { first, _ in first })
        byFoldedPath = Dictionary(grouping: files, by: { Self.foldedKey($0.relativePath) })
        byBasename = Dictionary(grouping: files, by: { Self.foldedKey($0.name) })
    }

    /// The same index with one more top-level file, placed where a rescan would
    /// list it, so a page just created shows without walking the whole folder.
    func addingTopLevelFile(_ file: VaultEntry) -> VaultIndex {
        let siblings = entries.filter { $0.relativePath != file.relativePath } + [file]
        let arranged = PageOrganizer.arrange(siblings.sorted(by: PageOrganizer.defaultOrder), names: PageOrganizer.loadOrder(root: root)[""], name: \.name)
        return VaultIndex(canonicalRoot: root, entries: arranged, files: files.filter { $0.relativePath != file.relativePath } + [file])
    }

    /// The same index with one more empty folder, placed where a rescan would list it.
    func addingFolder(_ relativePath: String) -> VaultIndex {
        let parentPath = (relativePath as NSString).deletingLastPathComponent
        let order = PageOrganizer.loadOrder(root: root)[parentPath]
        let folder = VaultEntry(relativePath: relativePath, url: root.appendingPathComponent(relativePath, isDirectory: true),
                                name: (relativePath as NSString).lastPathComponent, isDirectory: true, children: [], modified: Date(), size: 0)
        func place(_ list: [VaultEntry]) -> [VaultEntry] {
            PageOrganizer.arrange((list.filter { $0.relativePath != relativePath } + [folder]).sorted(by: PageOrganizer.defaultOrder), names: order, name: \.name)
        }
        func insert(_ list: [VaultEntry]) -> [VaultEntry] {
            list.map { entry in
                guard entry.isDirectory, entry.relativePath == parentPath || parentPath.hasPrefix(entry.relativePath + "/") else { return entry }
                let children = entry.relativePath == parentPath ? place(entry.children ?? []) : insert(entry.children ?? [])
                return VaultEntry(relativePath: entry.relativePath, url: entry.url, name: entry.name, isDirectory: true,
                                  children: children, modified: entry.modified, size: entry.size)
            }
        }
        return VaultIndex(canonicalRoot: root, entries: parentPath.isEmpty ? place(entries) : insert(entries), files: files)
    }

    /// The same index without an item and, for a folder, everything inside it.
    func removing(_ relativePath: String) -> VaultIndex {
        func gone(_ path: String) -> Bool { path == relativePath || path.hasPrefix(relativePath + "/") }
        func prune(_ list: [VaultEntry]) -> [VaultEntry] {
            list.filter { !gone($0.relativePath) }.map { entry in
                guard entry.isDirectory else { return entry }
                return VaultEntry(relativePath: entry.relativePath, url: entry.url, name: entry.name, isDirectory: true,
                                  children: prune(entry.children ?? []), modified: entry.modified, size: entry.size)
            }
        }
        return VaultIndex(canonicalRoot: root, entries: prune(entries), files: files.filter { !gone($0.relativePath) })
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

    static func contains(_ url: URL, in root: URL) -> Bool {
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

/// A file's modification date and size, read without opening it: a cheap way
/// to tell whether text read earlier may no longer be what is on disk.
struct FileStamp: Equatable {
    let modified: Date?
    let size: Int

    init(modified: Date?, size: Int) {
        self.modified = modified
        self.size = size
    }

    /// The stamp a directory scan recorded for a file.
    init(_ entry: VaultEntry) {
        self.init(modified: entry.modified, size: entry.size)
    }

    /// The file's current stamp. URL resource values are cached per URL
    /// object, so the file system is asked directly.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.resolvingSymlinksInPath().path) else { return nil }
        self.init(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
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

/// Where a dragged page lands: inside `folder` ("" is the vault root), before
/// or after the sibling named `anchor`, or at the end when there is none.
struct PageDropTarget: Equatable {
    let folder: String
    var anchor: String? = nil
    var after = false
}

/// Sidebar order and moves. A custom order per folder is kept in a hidden
/// `.acdian-order.json` at the vault root; names it does not list keep the
/// default order after the listed ones. Moves never overwrite: an occupied
/// name gets a number suffix, as restoring from the trash does.
struct PageOrganizer {
    static let orderFileName = ".acdian-order.json"
    let root: URL

    static func defaultOrder(_ a: VaultEntry, _ b: VaultEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    static func arrange<T>(_ items: [T], names: [String]?, name: (T) -> String) -> [T] {
        guard let names, !names.isEmpty else { return items }
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = items.filter { rank[name($0)] != nil }.sorted { rank[name($0)]! < rank[name($1)]! }
        return listed + items.filter { rank[name($0)] == nil }
    }
    static func loadOrder(root: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(orderFileName)),
              let order = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return order
    }
    func saveOrder(_ order: [String: [String]]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(order).write(to: root.appendingPathComponent(Self.orderFileName), options: .atomic)
    }

    /// Moves `path` to `target` and records its place. Returns the new relative path.
    @discardableResult func move(_ path: String, to target: PageDropTarget) throws -> String {
        let components = try Self.components(path)
        let folderComponents = target.folder.isEmpty ? [] : try Self.components(target.folder)
        let source = root.appendingPathComponent(path)
        let destination = folderComponents.isEmpty ? root : root.appendingPathComponent(target.folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw VaultCoreError.unsafeLocation(source) }
        var destinationIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory), destinationIsDirectory.boolValue,
              inside(destination), inside(source.deletingLastPathComponent()) else {
            throw VaultCoreError.unsafeLocation(destination)
        }
        // A folder cannot be moved into itself or anything inside it.
        if isDirectory.boolValue, folderComponents.count >= components.count, Array(folderComponents.prefix(components.count)) == components {
            throw VaultCoreError.invalidMove(source)
        }
        let sourceFolder = components.dropLast().joined(separator: "/")
        var name = components.last!
        if sourceFolder != target.folder {
            var number = 1
            while true {
                name = Self.numberedName(components.last!, isDirectory: isDirectory.boolValue, number: number)
                let candidate = destination.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    do { try FileManager.default.moveItem(at: source, to: candidate); break }
                    catch let error as CocoaError where error.code == .fileWriteFileExists { }
                }
                number += 1
            }
        }
        let newPath = target.folder.isEmpty ? name : target.folder + "/" + name
        var order = Self.loadOrder(root: root)
        if sourceFolder != target.folder {
            order[sourceFolder]?.removeAll { $0 == components.last! }
            // Folder orders inside a moved folder follow it to its new path.
            for key in order.keys where key == path || key.hasPrefix(path + "/") {
                order[newPath + key.dropFirst(path.count)] = order.removeValue(forKey: key)
            }
        }
        var names = currentOrder(of: target.folder, order: order).filter { $0 != name }
        if let anchor = target.anchor, let index = names.firstIndex(of: anchor) { names.insert(name, at: target.after ? index + 1 : index) }
        else { names.append(name) }
        order[target.folder] = names
        try saveOrder(order)
        return newPath
    }
    /// Creates a folder inside `folder`, numbering the name if it is taken.
    /// Returns the new relative path.
    @discardableResult func createFolder(_ name: String, in folder: String) throws -> String {
        if !folder.isEmpty { _ = try Self.components(folder) }
        let parent = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue, inside(parent) else {
            throw VaultCoreError.unsafeLocation(parent)
        }
        var number = 1
        while true {
            let candidate = Self.numberedName(name, isDirectory: true, number: number)
            do {
                try FileManager.default.createDirectory(at: parent.appendingPathComponent(candidate), withIntermediateDirectories: false)
                return folder.isEmpty ? candidate : folder + "/" + candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists { number += 1 }
        }
    }
    /// The vault root itself, or a real (non-alias) location inside it.
    private func inside(_ url: URL) -> Bool {
        let physical = url.standardizedFileURL.resolvingSymlinksInPath()
        return physical.pathComponents == root.pathComponents || VaultIndex.contains(physical, in: root)
    }
    /// The names in a folder as the sidebar shows them.
    func currentOrder(of folder: String, order: [String: [String]]) -> [String] {
        let url = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let entries = children.filter { !$0.lastPathComponent.hasPrefix(".") }.map {
            VaultEntry(relativePath: $0.lastPathComponent, url: $0, name: $0.lastPathComponent,
                       isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, children: nil, modified: nil, size: 0)
        }
        return Self.arrange(entries.sorted(by: Self.defaultOrder), names: order[folder], name: \.name).map(\.name)
    }
    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw VaultCoreError.unsafeLocation(URL(fileURLWithPath: path)) }
        return parts
    }
    static func numberedName(_ name: String, isDirectory: Bool, number: Int) -> String {
        guard number > 1 else { return name }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)
    }
}
