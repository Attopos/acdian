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
    /// Worked out once: views filter the whole vault by it on every redraw,
    /// and reading it from the URL each time costs about 5 ms per 10,000 files.
    let ext: String

    init(relativePath: String, url: URL, name: String, isDirectory: Bool, children: [VaultEntry]?, modified: Date?, size: Int) {
        self.relativePath = relativePath; self.url = url; self.name = name; self.isDirectory = isDirectory
        self.children = children; self.modified = modified; self.size = size
        ext = url.pathExtension.lowercased()
    }
}

enum VaultCoreError: LocalizedError {
    case notDirectory(URL)
    case invalidUTF8(URL)
    case conflict(URL)
    case unsafeLocation(URL)
    case invalidMove(URL)
    case nameTaken(URL)

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
        case .nameTaken(let url):
            return "已经有名为“\(url.lastPathComponent)”的项目，请换一个名称。"
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
                at: directory, includingPropertiesForKeys: Array(keys), options: []
            )
            var result: [VaultEntry] = []
            for child in children {
                let name = child.lastPathComponent
                // A file iCloud has not downloaded is listed under its real name.
                if let logical = CloudFiles.logicalName(ofPlaceholder: name), !logical.hasPrefix(".") {
                    let real = directory.appendingPathComponent(logical)
                    guard !FileManager.default.fileExists(atPath: real.path), let info = try? child.resourceValues(forKeys: keys), info.isRegularFile == true else { continue }
                    let entry = VaultEntry(relativePath: prefix.isEmpty ? logical : "\(prefix)/\(logical)", url: real, name: logical,
                                           isDirectory: false, children: nil, modified: info.contentModificationDate, size: 0)
                    result.append(entry); collected.append(entry)
                    continue
                }
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

    private init(root: URL, entries: [VaultEntry], files: [VaultEntry], byPath: [String: VaultEntry],
                 byFoldedPath: [String: [VaultEntry]], byBasename: [String: [VaultEntry]]) {
        self.root = root; self.entries = entries; self.files = files
        self.byPath = byPath; self.byFoldedPath = byFoldedPath; self.byBasename = byBasename
    }

    /// The same index with a new tree, and with the files `gone` matches taken
    /// out and `added` put in. The sorted file list and the lookups are updated
    /// rather than rebuilt: rebuilding them takes about 40 ms per 10,000 files,
    /// which a sidebar drop or rename would otherwise spend on the main thread.
    private func updating(entries: [VaultEntry], removing gone: (VaultEntry) -> Bool = { _ in false }, adding added: [VaultEntry] = []) -> VaultIndex {
        var byPath = self.byPath, byFoldedPath = self.byFoldedPath, byBasename = self.byBasename
        func drop(_ file: VaultEntry, from table: inout [String: [VaultEntry]], key: String) {
            guard var list = table[key] else { return }
            list.removeAll { $0.relativePath == file.relativePath }
            table[key] = list.isEmpty ? nil : list
        }
        // A file added again at a path already listed replaces it. Paths are
        // compared as bytes: hashing or comparing 10,000 of them as Unicode
        // text would cost more than the rest of the update.
        let replaced = added.compactMap { byPath[Self.key($0.relativePath)]?.relativePath }
        var kept: [VaultEntry] = []
        kept.reserveCapacity(files.count + added.count)
        for file in files {
            guard gone(file) || (!replaced.isEmpty && replaced.contains { $0.utf8.elementsEqual(file.relativePath.utf8) }) else { kept.append(file); continue }
            let key = Self.key(file.relativePath)
            if byPath[key]?.relativePath == file.relativePath { byPath[key] = nil }
            drop(file, from: &byFoldedPath, key: Self.foldedKey(file.relativePath))
            drop(file, from: &byBasename, key: Self.foldedKey(file.name))
        }
        // Merged into the sorted list. Files moved together usually sit next to
        // each other in it, so most need one comparison, not a search.
        func before(_ a: VaultEntry, _ b: VaultEntry) -> Bool { a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending }
        var merged: [VaultEntry] = []
        merged.reserveCapacity(kept.count + added.count)
        var next = 0
        for file in added.sorted(by: before) {
            var low = next, high = kept.count
            if low < high, before(kept[low], file) {
                low += 1
                while low < high { let middle = (low + high) / 2; if before(kept[middle], file) { low = middle + 1 } else { high = middle } }
            }
            merged.append(contentsOf: kept[next..<low]); merged.append(file); next = low
            let key = Self.key(file.relativePath)
            if byPath[key] == nil { byPath[key] = file }
            byFoldedPath[Self.foldedKey(file.relativePath), default: []].append(file)
            byBasename[Self.foldedKey(file.name), default: []].append(file)
        }
        merged.append(contentsOf: kept[next...])
        return VaultIndex(root: root, entries: entries, files: merged, byPath: byPath, byFoldedPath: byFoldedPath, byBasename: byBasename)
    }

    /// The same index with one more top-level file, placed where a rescan would
    /// list it, so a page just created shows without walking the whole folder.
    func addingTopLevelFile(_ file: VaultEntry) -> VaultIndex { addingFile(file) }

    /// The same index with one more file in an existing folder, placed where a rescan would list it.
    func addingFile(_ file: VaultEntry) -> VaultIndex {
        let parentPath = (file.relativePath as NSString).deletingLastPathComponent
        let order = PageOrganizer.loadOrder(root: root)[parentPath]
        func place(_ list: [VaultEntry]) -> [VaultEntry] {
            PageOrganizer.arrange((list.filter { $0.relativePath != file.relativePath } + [file]).sorted(by: PageOrganizer.defaultOrder), names: order, name: \.name)
        }
        func insert(_ list: [VaultEntry]) -> [VaultEntry] {
            list.map { entry in
                guard entry.isDirectory, entry.relativePath == parentPath || parentPath.hasPrefix(entry.relativePath + "/") else { return entry }
                let children = entry.relativePath == parentPath ? place(entry.children ?? []) : insert(entry.children ?? [])
                return VaultEntry(relativePath: entry.relativePath, url: entry.url, name: entry.name, isDirectory: true,
                                  children: children, modified: entry.modified, size: entry.size)
            }
        }
        return updating(entries: parentPath.isEmpty ? place(entries) : insert(entries), adding: [file])
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
        return updating(entries: parentPath.isEmpty ? place(entries) : insert(entries))
    }

    /// The same index after moving an item, and everything inside it, from
    /// `old` to `new`, placed where a rescan would place it.
    func moving(_ old: String, to new: String) -> VaultIndex {
        guard old != new, let entry = Self.find(old, in: entries) else { return self }
        func remap(_ item: VaultEntry) -> VaultEntry {
            let path = new + item.relativePath.dropFirst(old.count)
            return VaultEntry(relativePath: path, url: root.appendingPathComponent(path, isDirectory: item.isDirectory),
                              name: (path as NSString).lastPathComponent, isDirectory: item.isDirectory,
                              children: item.children?.map(remap), modified: item.modified, size: item.size)
        }
        let moved = remap(entry)
        var movedFiles: [VaultEntry] = []
        func collect(_ item: VaultEntry) { if item.isDirectory { item.children?.forEach(collect) } else { movedFiles.append(item) } }
        collect(moved)
        let remaining = removing(old)
        let parentPath = (new as NSString).deletingLastPathComponent
        let order = PageOrganizer.loadOrder(root: root)
        func place(_ list: [VaultEntry]) -> [VaultEntry] {
            PageOrganizer.arrange((list.filter { $0.relativePath != new } + [moved]).sorted(by: PageOrganizer.defaultOrder), names: order[parentPath], name: \.name)
        }
        func insert(_ list: [VaultEntry]) -> [VaultEntry] {
            list.map { item in
                guard item.isDirectory, item.relativePath == parentPath || parentPath.hasPrefix(item.relativePath + "/") else { return item }
                let children = item.relativePath == parentPath ? place(item.children ?? []) : insert(item.children ?? [])
                return VaultEntry(relativePath: item.relativePath, url: item.url, name: item.name, isDirectory: true,
                                  children: children, modified: item.modified, size: item.size)
            }
        }
        return remaining.updating(entries: parentPath.isEmpty ? place(remaining.entries) : insert(remaining.entries), adding: movedFiles)
    }
    private static func find(_ path: String, in list: [VaultEntry]) -> VaultEntry? {
        for item in list {
            if item.relativePath == path { return item }
            if item.isDirectory, path.hasPrefix(item.relativePath + "/"), let found = find(path, in: item.children ?? []) { return found }
        }
        return nil
    }

    /// The same index after renaming an item in place: it and everything inside
    /// it get their new paths, and its folder is ordered as a rescan would order it.
    func renaming(_ old: String, to new: String) -> VaultIndex {
        guard old != new else { return self }
        func moved(_ path: String) -> String? { path == old ? new : path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : nil }
        func remap(_ entry: VaultEntry) -> VaultEntry {
            let path = moved(entry.relativePath) ?? entry.relativePath
            guard path != entry.relativePath || entry.isDirectory else { return entry }
            let inside = entry.relativePath == old || old.hasPrefix(entry.relativePath + "/") || moved(entry.relativePath) != nil
            return VaultEntry(relativePath: path, url: path == entry.relativePath ? entry.url : root.appendingPathComponent(path, isDirectory: entry.isDirectory),
                              name: (path as NSString).lastPathComponent, isDirectory: entry.isDirectory,
                              children: inside ? arranged(entry.children ?? [], folder: path) : entry.children, modified: entry.modified, size: entry.size)
        }
        let order = PageOrganizer.loadOrder(root: root)
        let parent = (new as NSString).deletingLastPathComponent
        func arranged(_ list: [VaultEntry], folder: String) -> [VaultEntry] {
            let mapped = list.map(remap)
            return folder == parent ? PageOrganizer.arrange(mapped.sorted(by: PageOrganizer.defaultOrder), names: order[folder], name: \.name) : mapped
        }
        let renamedFiles = files.compactMap { file -> VaultEntry? in
            guard let path = moved(file.relativePath) else { return nil }
            return VaultEntry(relativePath: path, url: root.appendingPathComponent(path), name: (path as NSString).lastPathComponent,
                              isDirectory: false, children: nil, modified: file.modified, size: file.size)
        }
        return updating(entries: arranged(entries, folder: ""), removing: { moved($0.relativePath) != nil }, adding: renamedFiles)
    }

    /// The same index without an item and, for a folder, everything inside it.
    func removing(_ path: String) -> VaultIndex {
        // A rescan spells names as the disk does, which can differ in Unicode
        // form from a name just typed, so the listed spelling is the one matched.
        let relativePath = Self.find(path, in: entries)?.relativePath ?? path
        // Compared as bytes, like the paths in `updating`.
        func gone(_ path: String) -> Bool { path.utf8.starts(with: relativePath.utf8) && (path.utf8.count == relativePath.utf8.count || path.utf8.dropFirst(relativePath.utf8.count).first == UInt8(ascii: "/")) }
        // Only the folders on the way to the item are rebuilt.
        func prune(_ list: [VaultEntry]) -> [VaultEntry] {
            list.filter { !gone($0.relativePath) }.map { entry in
                guard entry.isDirectory, relativePath.hasPrefix(entry.relativePath + "/") else { return entry }
                return VaultEntry(relativePath: entry.relativePath, url: entry.url, name: entry.name, isDirectory: true,
                                  children: prune(entry.children ?? []), modified: entry.modified, size: entry.size)
            }
        }
        return updating(entries: prune(entries), removing: { gone($0.relativePath) })
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
        // A listing-built index (iOS) names files iCloud may not have downloaded
        // yet, so nothing is on disk to check; its builder admits no links.
        #if !os(macOS)
        return entry.url
        #else
        if access(CloudFiles.placeholder(of: entry.url).path, F_OK) == 0, !FileManager.default.fileExists(atPath: entry.url.path) { return entry.url }
        let physical = entry.url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.contains(physical, in: root),
              (try? physical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return entry.url
        #endif
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

#if !os(macOS)
/// One item the platform lists in the pages folder, downloaded or not.
struct VaultListing {
    let relativePath: String
    let isDirectory: Bool
    let modified: Date?
    let size: Int
}

extension VaultIndex {
    /// Builds the index from a listing instead of walking the disk, so a page
    /// still in iCloud appears under its real name. Folders that hold listed
    /// items need no entry of their own; empty ones do.
    init(root: URL, listing: [VaultListing]) {
        final class Folder { var folders: [String: Folder] = [:]; var files: [VaultListing] = []; var modified: Date? }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let order = PageOrganizer.loadOrder(root: canonicalRoot)
        let top = Folder()
        func folder(_ parts: ArraySlice<String>) -> Folder {
            parts.reduce(top) { current, name in
                if let existing = current.folders[name] { return existing }
                let made = Folder(); current.folders[name] = made; return made
            }
        }
        for item in listing {
            let parts = item.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            if item.isDirectory { folder(parts[...]).modified = item.modified }
            else { folder(parts.dropLast()).files.append(item) }
        }
        var collected: [VaultEntry] = []
        func entries(of current: Folder, prefix: String) -> [VaultEntry] {
            var result = current.folders.map { name, child -> VaultEntry in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return VaultEntry(relativePath: path, url: canonicalRoot.appendingPathComponent(path, isDirectory: true), name: name,
                                  isDirectory: true, children: entries(of: child, prefix: path), modified: child.modified, size: 0)
            }
            for item in current.files {
                let entry = VaultEntry(relativePath: item.relativePath, url: canonicalRoot.appendingPathComponent(item.relativePath),
                                       name: (item.relativePath as NSString).lastPathComponent, isDirectory: false, children: nil,
                                       modified: item.modified, size: item.size)
                result.append(entry); collected.append(entry)
            }
            return PageOrganizer.arrange(result.sorted(by: PageOrganizer.defaultOrder), names: order[prefix], name: \.name)
        }
        let scanned = entries(of: top, prefix: "")
        self.init(canonicalRoot: canonicalRoot, entries: scanned, files: collected)
    }
}
#endif

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

/// What the pages folder looks like when iCloud holds a file's content instead
/// of this device: either a hidden `.Name.md.icloud` stub, or a "dataless" file
/// under the real name whose bytes arrive when something reads it.
enum CloudFiles {
    static func logicalName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }
    static func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }
    /// True when the file's content is not on this device yet. Cheap: it never
    /// opens the file, so asking does not start a download.
    static func isNotDownloaded(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return access(placeholder(of: url).path, F_OK) == 0 }
        let dataless: UInt32 = 0x40000000 // SF_DATALESS
        return info.st_flags & dataless != 0
    }
    static func requestDownload(_ url: URL) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }

    /// True when iCloud has finished with an item and everything inside it: all
    /// of it is here, nothing is moving, nothing is in conflict. Anything it
    /// cannot tell counts as not settled. Missing content is asked for, so a
    /// later check can succeed.
    static func isSettled(_ url: URL) -> Bool {
        func settled(_ item: URL) -> Bool {
            if logicalName(ofPlaceholder: item.lastPathComponent) != nil { return false }
            if isNotDownloaded(item) { requestDownload(item); return false }
            guard let values = try? item.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey]) else { return false }
            guard values.isUbiquitousItem == true else { return true }
            return values.ubiquitousItemIsDownloading != true && values.ubiquitousItemIsUploading != true
                && values.ubiquitousItemIsUploaded != false && values.ubiquitousItemHasUnresolvedConflicts != true
        }
        guard settled(url) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return true }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in false }) else { return false }
        for case let item as URL in walk where !settled(item) { return false }
        return true
    }

    private final class Outcome<T>: @unchecked Sendable { var value: Result<T, Error>? }
    enum ReadError: LocalizedError { case timedOut }

    /// Reads through NSFileCoordinator, which waits for iCloud to deliver the
    /// file. Blocks the caller, so never on the main thread; past the timeout
    /// the read is cancelled and throws.
    static func coordinatedRead<T>(_ url: URL, timeout: TimeInterval, _ body: @escaping (URL) throws -> T) throws -> T {
        if isNotDownloaded(url) { requestDownload(url) }
        let coordinator = NSFileCoordinator(filePresenter: nil), finished = DispatchSemaphore(value: 0), outcome = Outcome<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &failure) { actual in outcome.value = Result { try body(actual) } }
            if let failure { outcome.value = .failure(failure) }
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            coordinator.cancel()
            _ = finished.wait(timeout: .now() + 2)
            throw ReadError.timedOut
        }
        guard let value = outcome.value else { throw ReadError.timedOut }
        return try value.get()
    }
}

/// Writes in the pages folder go through NSFileCoordinator, so the iCloud sync
/// daemon never sees or replaces a file halfway through a change.
enum FileCoordination {
    /// Runs `body` while holding coordinated write access to every item. Several
    /// items are taken together, so no other process gets in between them.
    @discardableResult
    static func writing<T>(_ items: [(url: URL, options: NSFileCoordinator.WritingOptions)], _ body: (NSFileCoordinator) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        return try withoutActuallyEscaping(body) { body in
            var outcome: Result<T, Error>?
            var failure: NSError?
            func hold(_ index: Int) {
                guard index < items.count else { outcome = Result { try body(coordinator) }; return }
                var error: NSError?
                coordinator.coordinate(writingItemAt: items[index].url, options: items[index].options, error: &error) { _ in hold(index + 1) }
                if let error, outcome == nil { failure = error }
            }
            if items.count > 1 {
                coordinator.prepare(forReadingItemsAt: [], options: [], writingItemsAt: items.map(\.url), options: [], error: &failure) { done in hold(0); done() }
            } else { hold(0) }
            if let outcome { return try outcome.get() }
            throw failure ?? CocoaError(.fileWriteUnknown)
        }
    }
    @discardableResult
    static func writing<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: () throws -> T) throws -> T {
        try writing([(url, options)]) { _ in try body() }
    }
    /// Moves items as one coordinated operation; `body` does the renames.
    static func moving(_ pairs: [(from: URL, to: URL)], _ body: () throws -> Void) throws {
        try writing(pairs.flatMap { [($0.from, NSFileCoordinator.WritingOptions.forMoving), ($0.to, NSFileCoordinator.WritingOptions.forReplacing)] }) { coordinator in
            try body()
            for pair in pairs where FileManager.default.fileExists(atPath: pair.to.path) { coordinator.item(at: pair.from, didMoveTo: pair.to) }
        }
    }
    static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) throws {
        try writing(url, options: .forReplacing) { try data.write(to: url, options: options) }
    }
}

enum VaultFileIO {
    static func readMarkdown(at url: URL, allowedRoot: URL? = nil) throws -> String {
        let target = try checkedURL(url, allowedRoot: allowedRoot)
        return try decode(Data(contentsOf: target), at: url)
    }

    /// Reads a page that iCloud may still be delivering or updating. Off the main thread only.
    static func readMarkdownSynced(at url: URL, allowedRoot: URL? = nil, timeout: TimeInterval = 120) throws -> String {
        try CloudFiles.coordinatedRead(url, timeout: timeout) { try readMarkdown(at: $0, allowedRoot: allowedRoot) }
    }

    /// expectedContent is the original decoded text. nil permits creating a new
    /// file only. Existing UTF-8 BOMs are preserved on save.
    static func saveMarkdown(_ text: String, at url: URL, expectedContent: String?, allowedRoot: URL? = nil) throws {
        // Write to the physical file so atomic replacement preserves an in-vault
        // symbolic link rather than replacing the link itself with a plain file.
        let target = try checkedURL(url, allowedRoot: allowedRoot)
        // The read, compare and replace share one coordinated write, so the
        // compare also holds against the sync daemon.
        try FileCoordination.writing(target, options: .forReplacing) {
            try replaceMarkdown(text, target: target, url: url, expectedContent: expectedContent, allowedRoot: allowedRoot)
        }
    }

    private static func replaceMarkdown(_ text: String, target: URL, url: URL, expectedContent: String?, allowedRoot: URL?) throws {
        let fm = FileManager.default
        // A name iCloud has not downloaded yet is still taken.
        let exists = fm.fileExists(atPath: target.path) || fm.fileExists(atPath: CloudFiles.placeholder(of: target).path)
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
            // Prepared outside the pages folder, so sync never picks it up, but
            // on the target's own volume, so the replacement stays atomic.
            let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? fm.removeItem(at: folder) }
            let temporary = folder.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary, options: .withoutOverwriting)
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

    /// Replaces a small data file inside the pages folder in one step.
    static func checkedWrite(_ data: Data, to url: URL, allowedRoot: URL) throws {
        try FileCoordination.write(data, to: try checkedURL(url, allowedRoot: allowedRoot))
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
        try FileCoordination.write(encoder.encode(order), to: root.appendingPathComponent(Self.orderFileName))
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
                    do {
                        try PageComments.movingPage(from: source, to: candidate, isDirectory: isDirectory.boolValue) {
                            try FileManager.default.moveItem(at: source, to: candidate)
                        }
                        break
                    }
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
    /// Creates a folder inside `folder`, numbering the name if it is taken, and
    /// places it right after `anchor`, or first in the folder without one.
    /// Returns the new relative path.
    @discardableResult func createFolder(_ name: String, in folder: String, after anchor: String? = nil) throws -> String {
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
                let folderURL = parent.appendingPathComponent(candidate)
                try FileCoordination.writing(folderURL) { try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false) }
                var order = Self.loadOrder(root: root)
                var names = currentOrder(of: folder, order: order).filter { $0 != candidate }
                if let anchor, let index = names.firstIndex(of: anchor) { names.insert(candidate, at: index + 1) }
                else { names.insert(candidate, at: 0) }
                order[folder] = names
                try saveOrder(order)
                return folder.isEmpty ? candidate : folder + "/" + candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists { number += 1 }
        }
    }
    /// Renames an item where it is and keeps its place in the sidebar.
    /// Returns the new relative path.
    @discardableResult func rename(_ path: String, to name: String) throws -> String {
        let components = try Self.components(path)
        let folder = components.dropLast().joined(separator: "/")
        let source = root.appendingPathComponent(path)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              FileManager.default.fileExists(atPath: source.path), inside(source.deletingLastPathComponent()) else {
            throw VaultCoreError.unsafeLocation(source)
        }
        let newPath = folder.isEmpty ? name : folder + "/" + name
        guard newPath != path else { return path }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        // A case-only change on a case-insensitive disk names the same item.
        func inode(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int }
        let sameItem = inode(destination) != nil && inode(destination) == inode(source)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        try PageComments.movingPage(from: source, to: destination, isDirectory: isDirectory.boolValue) {
            let result = sameItem ? Darwin.rename(source.path, destination.path) : renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
            if result != 0 {
                if errno == EEXIST { throw VaultCoreError.nameTaken(destination) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
            }
        }
        let saved = Self.loadOrder(root: root)
        var order = saved
        if let index = order[folder]?.firstIndex(of: components.last!) { order[folder]![index] = name }
        for key in order.keys where key == path || key.hasPrefix(path + "/") {
            order[newPath + key.dropFirst(path.count)] = order.removeValue(forKey: key)
        }
        if order != saved { try saveOrder(order) }
        return newPath
    }
    /// The vault root itself, or a real (non-alias) location inside it.
    private func inside(_ url: URL) -> Bool {
        let physical = url.standardizedFileURL.resolvingSymlinksInPath()
        return physical.pathComponents == root.pathComponents || VaultIndex.contains(physical, in: root)
    }
    /// The names in a folder as the sidebar shows them.
    func currentOrder(of folder: String, order: [String: [String]]) -> [String] {
        let url = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        var names = Set<String>()
        var entries: [VaultEntry] = []
        for child in children {
            let name = CloudFiles.logicalName(ofPlaceholder: child.lastPathComponent) ?? child.lastPathComponent
            guard !name.hasPrefix("."), names.insert(name).inserted else { continue }
            entries.append(VaultEntry(relativePath: name, url: child, name: name,
                                      isDirectory: (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, children: nil, modified: nil, size: 0))
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

/// Comments on a page live in a hidden file beside it, `.<page name>.comments.json`,
/// so the page's own Markdown is never changed. The editor writes and reads
/// its contents; here it is only stored, and kept with the page when the page
/// is renamed, moved, sent to the trash or restored.
enum PageComments {
    static let maximumSize = 4_000_000
    static func sidecarName(_ pageName: String) -> String { "." + pageName + ".comments.json" }
    static func sidecar(of page: URL) -> URL { page.deletingLastPathComponent().appendingPathComponent(sidecarName(page.lastPathComponent)) }
    /// The page at `path`, or nil when the path is not a Markdown page inside the vault.
    private static func page(_ path: String, root: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }),
              parts.last!.lowercased().hasSuffix(".md") else { return nil }
        let url = root.appendingPathComponent(path)
        guard VaultIndex.contains(url.standardizedFileURL, in: root.standardizedFileURL) else { return nil }
        return url
    }
    static func read(page path: String, root: URL) -> String? {
        guard let url = page(path, root: root).map(sidecar(of:)),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Stores the comments of the page at `path`; nil or empty removes the file.
    /// Nothing is written for a page that is no longer there, so a late save
    /// for a renamed page cannot leave comments under its old name.
    static func write(_ json: String?, page path: String, root: URL) throws {
        guard let pageURL = page(path, root: root) else { throw VaultCoreError.unsafeLocation(root.appendingPathComponent(path)) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pageURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        let url = sidecar(of: pageURL)
        if let link = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, link { throw VaultCoreError.unsafeLocation(url) }
        guard let json, !json.isEmpty else {
            try FileCoordination.writing(url, options: .forDeleting) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            return
        }
        let data = Data(json.utf8)
        guard data.count <= maximumSize else { throw VaultCoreError.unsafeLocation(url) }
        try FileCoordination.write(data, to: url)
    }
    /// Runs `move`, which moves a page, and takes the page's comments along,
    /// all in one coordinated operation.
    static func movingPage(from old: URL, to new: URL, isDirectory: Bool, _ move: () throws -> Void) throws {
        let pairs: [(from: URL, to: URL)] = isDirectory ? [(old, new)] : [(old, new), (sidecar(of: old), sidecar(of: new))]
        try FileCoordination.moving(pairs) {
            try move()
            if !isDirectory { follow(from: old, to: new) }
        }
    }
    /// Moves a page's comments after the page itself moved from `old` to `new`.
    /// A comments file already at the new name belongs to no page, as the page
    /// could only move to a free name, so it is replaced.
    private static func follow(from old: URL, to new: URL) {
        let source = sidecar(of: old), destination = sidecar(of: new)
        guard source.path != destination.path, FileManager.default.fileExists(atPath: source.path) else { return }
        _ = Darwin.rename(source.path, destination.path)
    }
}
