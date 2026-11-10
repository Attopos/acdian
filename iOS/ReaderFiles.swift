import Foundation

/// Everything the reader knows about iCloud. Reading only: nothing here writes,
/// moves or deletes inside the pages folder, except creating the empty root of
/// a brand-new iCloud container so it can appear in iCloud Drive.
enum ReaderFiles {
    static let containerID = "iCloud.com.acdian.reader"
    enum ReadError: LocalizedError {
        case timedOut, notAvailable
        var errorDescription: String? { "The file is not on this device yet." }
    }

    /// The pages root and whether it is the iCloud one. Call off the main
    /// thread: the first ubiquity lookup can take a while.
    static func pagesRoot() -> (root: URL, iCloud: Bool) {
        let manager = FileManager.default
        #if DEBUG
        // The UI tour reads a copy of the test fixtures, never the real pages.
        if CommandLine.arguments.contains("--local-pages") { return (manager.urls(for:.documentDirectory,in:.userDomainMask)[0],false) }
        #endif
        if let container = manager.url(forUbiquityContainerIdentifier:containerID) {
            let documents = container.appendingPathComponent("Documents",isDirectory:true)
            if !manager.fileExists(atPath:documents.path) { try? manager.createDirectory(at:documents,withIntermediateDirectories:true) }
            // Until something asks for it, iOS leaves a container's folder empty on
            // this device and the metadata query finds nothing. Asking once fixes both.
            try? manager.startDownloadingUbiquitousItem(at:documents)
            var failure: NSError?
            NSFileCoordinator(filePresenter:nil).coordinate(readingItemAt:documents,options:[],error:&failure) { _ in }
            return (documents,true)
        }
        return (manager.urls(for:.documentDirectory,in:.userDomainMask)[0],false)
    }

    /// What NSMetadataQuery reported for one item.
    struct QueryItem {
        let path: String
        let isDirectory: Bool
        let modified: Date?
        let size: Int
        let downloaded: Bool
    }
    struct Scan {
        var listing: [VaultListing] = []
        /// Paths whose content is not on this device yet.
        var remote: Set<String> = []
        /// Hidden files at the root, such as `.acdian-order.json`, known under their real names.
        var rootConfig: Set<String> = []
    }

    static func logicalName(ofPlaceholder name: String) -> String? { CloudFiles.logicalName(ofPlaceholder:name) }
    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey]
    private static func notDownloaded(_ values: URLResourceValues) -> Bool { values.ubiquitousItemDownloadingStatus == .notDownloaded }

    /// Lists the pages folder from the disk and from the metadata query
    /// together: either may know of files the other has not heard about yet.
    /// Hidden items and the trash stay out, apart from root config files.
    /// Drops what has been deleted since a saved listing was made: an item stays
    /// if it, or its iCloud placeholder, is still there. Folders are checked first,
    /// so a deleted folder takes everything in it without a check per file.
    static func withoutDeleted(_ scan: Scan, root: URL) -> Scan {
        let manager = FileManager.default
        func exists(_ path: String) -> Bool {
            let url = root.appendingPathComponent(path)
            if manager.fileExists(atPath:url.path) { return true }
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            return manager.fileExists(atPath:placeholder.path)
        }
        var gone = Set<String>()
        for item in scan.listing where item.isDirectory {
            let parent = (item.relativePath as NSString).deletingLastPathComponent
            if !parent.isEmpty, gone.contains(parent) || !exists(item.relativePath) { gone.insert(item.relativePath) }
            else if parent.isEmpty, !exists(item.relativePath) { gone.insert(item.relativePath) }
        }
        var result = scan
        result.listing = scan.listing.filter { item in
            let parent = (item.relativePath as NSString).deletingLastPathComponent
            if gone.contains(item.relativePath) || gone.contains(parent) { return false }
            return item.isDirectory || exists(item.relativePath)
        }
        let kept = Set(result.listing.map(\.relativePath))
        result.remote = scan.remote.filter { kept.contains($0) }
        return result
    }
    /// Just the folders and settings files at the top, for a first launcher.
    static func scanTopLevel(root: URL) -> Scan {
        var result = Scan()
        for child in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[])) ?? [] {
            let name = logicalName(ofPlaceholder:child.lastPathComponent) ?? child.lastPathComponent
            if name.hasPrefix(".") { result.rootConfig.insert(name); continue }
            if (try? child.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true { result.listing.append(VaultListing(relativePath:name,isDirectory:true,modified:nil,size:0)) }
        }
        return result
    }
    /// The query alone is enough once it has gathered: walking a large iCloud
    /// folder on iOS takes far longer than asking the query.
    /// The whole folder in one pass of a directory enumerator, its attributes
    /// prefetched, rather than one request per item. Hidden items stay out,
    /// except iCloud stubs and the settings files at the root.
    static func enumerate(root: URL) -> Scan {
        var result = Scan(), seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey]
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walk = FileManager.default.enumerator(at:root,includingPropertiesForKeys:keys,options:[],errorHandler:{ _,_ in true }) else { return result }
        for case let url as URL in walk {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let relative = String(full.dropFirst(base.count)), name = url.lastPathComponent
            let parent = (relative as NSString).deletingLastPathComponent
            if name.hasPrefix(".") {
                if let logical = logicalName(ofPlaceholder:name), !logical.hasPrefix(".") {
                    let path = parent.isEmpty ? logical : parent + "/" + logical
                    if seen.insert(path).inserted { result.listing.append(VaultListing(relativePath:path,isDirectory:false,modified:nil,size:0)); result.remote.insert(path) }
                } else if parent.isEmpty { result.rootConfig.insert(logicalName(ofPlaceholder:name) ?? name) }
                walk.skipDescendants(); continue
            }
            guard let values = try? url.resourceValues(forKeys:Set(keys)), values.isSymbolicLink != true else { continue }
            guard seen.insert(relative).inserted else { continue }
            if values.isDirectory == true { result.listing.append(VaultListing(relativePath:relative,isDirectory:true,modified:values.contentModificationDate,size:0)) }
            else if values.isRegularFile == true {
                result.listing.append(VaultListing(relativePath:relative,isDirectory:false,modified:values.contentModificationDate,size:values.fileSize ?? 0))
                if notDownloaded(values) { result.remote.insert(relative) }
            }
        }
        return result
    }
    static func scan(root: URL, query: [QueryItem], walkDisk: Bool = true, base: Scan? = nil) -> Scan {
        let manager = FileManager.default
        var result = base ?? Scan()
        var seen = Set(result.listing.map { $0.relativePath.precomposedStringWithCanonicalMapping })
        func add(_ path: String, isDirectory: Bool, modified: Date?, size: Int, remote: Bool) {
            guard seen.insert(path.precomposedStringWithCanonicalMapping).inserted else { return }
            result.listing.append(VaultListing(relativePath:path,isDirectory:isDirectory,modified:modified,size:size))
            if remote { result.remote.insert(path) }
        }
        func walk(_ directory: URL, prefix: String) {
            let children = (try? manager.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(resourceKeys),options:[])) ?? []
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") {
                    let logical = logicalName(ofPlaceholder:name) ?? name
                    if logical.hasPrefix(".") { if prefix.isEmpty { result.rootConfig.insert(logical) } }
                    else if logicalName(ofPlaceholder:name) != nil { add(prefix.isEmpty ? logical : prefix + "/" + logical,isDirectory:false,modified:nil,size:0,remote:true) }
                    continue
                }
                guard let values = try? child.resourceValues(forKeys:resourceKeys), values.isSymbolicLink != true else { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if values.isDirectory == true {
                    add(path,isDirectory:true,modified:values.contentModificationDate,size:0,remote:false)
                    walk(child,prefix:path)
                } else if values.isRegularFile == true {
                    add(path,isDirectory:false,modified:values.contentModificationDate,size:values.fileSize ?? 0,remote:notDownloaded(values))
                }
            }
        }
        if walkDisk { walk(root,prefix:"") }
        for item in query {
            guard let relative = relativePath(item.path,root:root) else { continue }
            var parts = relative.split(separator:"/").map(String.init)
            guard let last = parts.popLast(), !parts.contains(where:{ $0.hasPrefix(".") }) else { continue }
            let name = logicalName(ofPlaceholder:last) ?? last
            if name.hasPrefix(".") { if parts.isEmpty { result.rootConfig.insert(name) }; continue }
            let path = (parts + [name]).joined(separator:"/")
            add(path,isDirectory:item.isDirectory,modified:item.modified,size:item.size,remote:!item.isDirectory && !item.downloaded)
        }
        return result
    }

    /// A path inside the root, however the system spelled the /private prefix.
    static func relativePath(_ path: String, root: URL) -> String? {
        func bare(_ value: String) -> String { value.hasPrefix("/private/") ? String(value.dropFirst(8)) : value }
        let base = bare(root.standardizedFileURL.path) + "/", full = bare(URL(fileURLWithPath:path).standardizedFileURL.path)
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }

    /// True when the file's content is on this device.
    static func isLocal(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:[.ubiquitousItemDownloadingStatusKey]) else { return false }
        return !notDownloaded(values)
    }
    /// True when a newer version of the file is waiting in iCloud.
    static func isOutdated(_ url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys:[.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }
    static func startDownloading(_ url: URL) { try? FileManager.default.startDownloadingUbiquitousItem(at:url) }

    /// Reads through NSFileCoordinator after asking iCloud for the file, which also
    /// fetches a newer version. Never on the main thread.
    static func coordinatedRead<T>(_ url: URL, timeout: TimeInterval, _ body: @escaping (URL) throws -> T) throws -> T {
        startDownloading(url)
        return try CloudFiles.coordinatedRead(url,timeout:timeout,body)
    }

    static func data(_ url: URL, timeout: TimeInterval = 90) async throws -> Data {
        try await detached { try coordinatedRead(url,timeout:timeout) { try Data(contentsOf:$0) } }
    }
    /// Downloads the file without reading it, for what the system opens itself.
    static func materialize(_ url: URL, timeout: TimeInterval = 300) async throws {
        try await detached { try coordinatedRead(url,timeout:timeout) { actual in
            guard FileManager.default.fileExists(atPath:actual.path) else { throw ReadError.notAvailable }
        } }
    }
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async { continuation.resume(with:Result { try work() }) }
        }
    }
}
