import Foundation

/// Resolves one page location automatically. Existing folders are adopted in
/// place; their files are never copied, renamed, or removed during adoption.
enum PagesStorage {
    struct Location {
        let root: URL
        /// Ownership of an opened security scope passes to the caller.
        let securityScopedURL: URL?
    }

    static func resolve(preferences: UserDefaults = .standard, override: URL? = nil, adjacentRoot: URL? = nil, fallbackRoot: URL? = nil) throws -> Location {
        if let override {
            // An explicit test/launch location must not replace saved settings.
            return Location(root:try createRoot(override),securityScopedURL:nil)
        }
        func remember(_ location: Location, originalBookmark: Data? = nil) -> Location {
            preferences.set(location.root.path,forKey:"pagesPath")
            let bookmarkURL = location.securityScopedURL ?? location.root
            if let bookmark = try? bookmarkURL.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) {
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
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        let fallback = fallbackRoot ?? support.appendingPathComponent("acdian/Pages",isDirectory:true)
        return remember(Location(root:try createRoot(fallback),securityScopedURL:nil))
    }

    private static func bookmarkedRoot(_ data: Data) -> Location? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData:data,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale) else { return nil }
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
