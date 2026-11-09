import Foundation
import CryptoKit

/// Resolves one page location automatically. Existing folders are adopted in
/// place; their files are never copied, renamed, or removed during adoption.
enum PagesStorage {
    struct Location {
        let root: URL
        /// Ownership of an opened security scope passes to the caller.
        let securityScopedURL: URL?
    }
    // Security-scoped bookmarks exist only on macOS.
    #if os(macOS)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    private static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    private static var homeDirectory: URL { URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true) }
    #endif

    static func resolve(preferences: UserDefaults = .standard, override: URL? = nil, adjacentRoot: URL? = nil, fallbackRoot: URL? = nil) throws -> Location {
        if let override {
            // An explicit test/launch location must not replace saved settings.
            return Location(root:try createRoot(override),securityScopedURL:nil)
        }
        func remember(_ location: Location, originalBookmark: Data? = nil) -> Location {
            preferences.set(location.root.path,forKey:"pagesPath")
            let bookmarkURL = location.securityScopedURL ?? location.root
            if let bookmark = try? bookmarkURL.bookmarkData(options:bookmarkCreation,includingResourceValuesForKeys:nil,relativeTo:nil) {
                preferences.set(bookmark,forKey:"pagesBookmark")
            } else if let originalBookmark { preferences.set(originalBookmark,forKey:"pagesBookmark") }
            else { preferences.removeObject(forKey:"pagesBookmark") }
            return location
        }
        if let data = preferences.data(forKey:"pagesBookmark"), let location = bookmarkedRoot(data) {
            return remember(location,originalBookmark:data)
        }
        if let path = preferences.string(forKey:"pagesPath"), let root = existingRoot(URL(fileURLWithPath:path)) {
            return remember(Location(root:root,securityScopedURL:nil))
        }
        let adjacent = adjacentRoot ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("资料库",isDirectory:true)
        if let root = existingRoot(adjacent) {
            // A legacy bookmark can retain access to a folder beside the app.
            if let data = preferences.data(forKey:"vaultBookmark"), let location = bookmarkedRoot(data) {
                if location.root == root { return remember(location,originalBookmark:data) }
                location.securityScopedURL?.stopAccessingSecurityScopedResource()
            }
            return remember(Location(root:root,securityScopedURL:nil))
        }
        if let data = preferences.data(forKey:"vaultBookmark"), let location = bookmarkedRoot(data) {
            return remember(location,originalBookmark:data)
        }
        if let path = preferences.string(forKey:"vaultPath"), let root = existingRoot(URL(fileURLWithPath:path)) {
            return remember(Location(root:root,securityScopedURL:nil))
        }
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support",isDirectory:true)
        let fallback = fallbackRoot ?? support.appendingPathComponent("acdian/Pages",isDirectory:true)
        return remember(Location(root:try createRoot(fallback),securityScopedURL:nil))
    }

    // MARK: Moving the pages to iCloud

    /// The Documents folder of ACdian's iCloud container, as macOS shows it.
    static var iCloudDocuments: URL {
        homeDirectory.appendingPathComponent("Library/Mobile Documents/iCloud~com~acdian~reader/Documents",isDirectory:true)
    }
    enum MoveError: LocalizedError {
        case targetNotEmpty, notDownloaded, verificationFailed
        var errorDescription: String? {
            switch self {
            case .targetNotEmpty: return "iCloud 的 ACdian 文件夹里已经有内容，为避免覆盖，没有移动。"
            case .notDownloaded: return "有文件还没有从 iCloud 下载到本机，没有移动。"
            case .verificationFailed: return "复制后的文件校验不一致，没有切换，也没有留下副本。"
            }
        }
    }
    /// Copies everything in `source`, hidden files included, into the empty
    /// folder `target` and checks every file's SHA-256 against its original.
    /// `source` is only read. On failure nothing copied stays behind. Returns
    /// the number of files copied.
    @discardableResult static func copyPages(from source: URL, to target: URL) throws -> Int {
        let manager = FileManager.default
        let existing = (try manager.contentsOfDirectory(at:target,includingPropertiesForKeys:nil,options:[])).filter { $0.lastPathComponent != ".DS_Store" }
        guard existing.isEmpty else { throw MoveError.targetNotEmpty }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path + "/", targetPath = target.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard !sourcePath.hasPrefix(targetPath), !targetPath.hasPrefix(sourcePath) else { throw VaultCoreError.invalidMove(target) }
        let items = try listing(of:source)
        guard !items.contains(where:{ CloudFiles.logicalName(ofPlaceholder:($0 as NSString).lastPathComponent) != nil }) else { throw MoveError.notDownloaded }
        let top = try manager.contentsOfDirectory(at:source,includingPropertiesForKeys:nil,options:[])
        var copied: [URL] = []
        do {
            for item in top {
                let destination = target.appendingPathComponent(item.lastPathComponent)
                try FileCoordination.writing(destination,options:.forReplacing) { try manager.copyItem(at:item,to:destination) }
                copied.append(destination)
            }
            guard try Set(listing(of:target)) == Set(items) else { throw MoveError.verificationFailed }
            var files = 0
            for path in items {
                let original = source.appendingPathComponent(path), copy = target.appendingPathComponent(path)
                let values = try original.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    guard try manager.destinationOfSymbolicLink(atPath:original.path) == manager.destinationOfSymbolicLink(atPath:copy.path) else { throw MoveError.verificationFailed }
                } else if values.isDirectory != true {
                    guard try hash(original) == hash(copy) else { throw MoveError.verificationFailed }
                    files += 1
                }
            }
            return files
        } catch {
            for item in copied { try? manager.removeItem(at:item) }
            throw error
        }
    }
    /// Every item below `root`, hidden ones included, as relative paths.
    private static func listing(of root: URL) throws -> [String] {
        var result: [String] = []
        func walk(_ directory: URL, _ prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[]) {
                let path = prefix + child.lastPathComponent, values = try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                result.append(path.precomposedStringWithCanonicalMapping)
                if values.isDirectory == true, values.isSymbolicLink != true { try walk(child,path + "/") }
            }
        }
        try walk(root,"")
        return result
    }
    private static func hash(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom:url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount:1 << 20), !chunk.isEmpty { hasher.update(data:chunk) }
        return hasher.finalize()
    }
    /// Makes `root` the saved pages location.
    static func adopt(_ root: URL, preferences: UserDefaults = .standard) {
        preferences.set(root.path,forKey:"pagesPath")
        if let bookmark = try? root.bookmarkData(options:bookmarkCreation,includingResourceValuesForKeys:nil,relativeTo:nil) { preferences.set(bookmark,forKey:"pagesBookmark") }
        else { preferences.removeObject(forKey:"pagesBookmark") }
    }

    private static func bookmarkedRoot(_ data: Data) -> Location? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData:data,options:bookmarkResolution,relativeTo:nil,bookmarkDataIsStale:&stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        guard let root = existingRoot(url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        return Location(root:root,securityScopedURL:scoped ? url : nil)
    }

    private static func existingRoot(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:root.path,isDirectory:&directory),directory.boolValue else { return nil }
        return root
    }

    private static func createRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw VaultCoreError.notDirectory(url) }
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        guard let root = existingRoot(url) else { throw VaultCoreError.notDirectory(url) }
        return root
    }
}
