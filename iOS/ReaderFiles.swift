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
        if let container = manager.url(forUbiquityContainerIdentifier:containerID) {
            let documents = container.appendingPathComponent("Documents",isDirectory:true)
            if !manager.fileExists(atPath:documents.path) { try? manager.createDirectory(at:documents,withIntermediateDirectories:true) }
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

    /// `.Name.md.icloud` is how iCloud stands in for a file it has not downloaded.
    static func logicalName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }
    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey]
    private static func notDownloaded(_ values: URLResourceValues) -> Bool { values.ubiquitousItemDownloadingStatus == .notDownloaded }

    /// Lists the pages folder from the disk and from the metadata query
    /// together: either may know of files the other has not heard about yet.
    /// Hidden items and the trash stay out, apart from root config files.
    static func scan(root: URL, query: [QueryItem]) -> Scan {
        let manager = FileManager.default
        var result = Scan()
        var seen = Set<String>()
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
        walk(root,prefix:"")
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

    private final class Outcome<T>: @unchecked Sendable { var value: Result<T,Error>? }

    /// Reads through NSFileCoordinator, asking iCloud for the file first. Blocks
    /// the caller, so never call it on the main thread. The coordinator waits
    /// for the download; past the timeout the read is cancelled and throws.
    static func coordinatedRead<T>(_ url: URL, timeout: TimeInterval, _ body: @escaping (URL) throws -> T) throws -> T {
        startDownloading(url)
        let coordinator = NSFileCoordinator(filePresenter:nil), finished = DispatchSemaphore(value:0), outcome = Outcome<T>()
        DispatchQueue.global(qos:.userInitiated).async {
            var failure: NSError?
            coordinator.coordinate(readingItemAt:url,options:[],error:&failure) { actual in outcome.value = Result { try body(actual) } }
            if let failure { outcome.value = .failure(failure) }
            finished.signal()
        }
        if finished.wait(timeout:.now() + timeout) == .timedOut {
            coordinator.cancel()
            _ = finished.wait(timeout:.now() + 2)
            throw ReadError.timedOut
        }
        guard let value = outcome.value else { throw ReadError.notAvailable }
        return try value.get()
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
