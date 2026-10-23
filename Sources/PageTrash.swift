import Foundation
import Darwin

/// Page deletion is an in-place rename into an app-owned, hidden directory.
/// All paths below the page root are accessed through no-follow directory
/// descriptors. In particular, recursive expiry never follows a stored link.
final class PageTrash {
    static let retentionInterval: TimeInterval = 15 * 24 * 60 * 60

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let originalRelativePath: String
        let name: String
        let isDirectory: Bool
        let deletedAt: Date
        let expiresAt: Date
    }

    enum TrashError: LocalizedError {
        case unsafeStorage, invalidEntry, missingEntry, expiredEntry, recoveryRequired

        var errorDescription: String? {
            switch self {
            case .unsafeStorage: return "无法安全访问垃圾桶。"
            case .invalidEntry: return "垃圾桶项目无效或已损坏。"
            case .missingEntry: return "找不到垃圾桶项目。"
            case .expiredEntry: return "此项目已超过 15 天保留期限，无法恢复。"
            case .recoveryRequired: return "删除尚未完成，文件已保留在垃圾桶中。"
            }
        }
    }

    private struct Pending: Codable {
        let id: UUID
        let originalRelativePath: String
        let name: String
        let isDirectory: Bool
    }

    private final class Directory {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }

    private let root: URL
    private let rootDirectory: Directory
    private let nowDate: () -> Date
    private let lock = NSRecursiveLock()
    private let storageName = ".acdian-trash"
    private let metadataName = "metadata.json"
    private let pendingName = "pending.json"
    private let payloadName = "payload"

    init(root: URL, nowDate: @escaping () -> Date = Date.init) throws {
        guard root.isFileURL else { throw VaultCoreError.notDirectory(root) }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.systemError(path: canonical.path) }
        self.root = canonical
        self.rootDirectory = Directory(descriptor)
        self.nowDate = nowDate
    }

    @discardableResult func moveToTrash(relativePath: String) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        let components = try checkedComponents(relativePath)
        let parent = try sourceParent(components, create: false)
        let name = components.last!
        guard let source = try node(parent.fd, name), Self.isDirectory(source) || Self.isRegular(source) else {
            throw VaultCoreError.unsafeLocation(root.appendingPathComponent(relativePath))
        }
        let storage = try trashDirectory(create: true)!
        let id = UUID(), directoryName = id.uuidString
        guard mkdirat(storage.fd, directoryName, 0o700) == 0 else { throw Self.systemError() }
        let directory = try openDirectory(storage.fd, directoryName)
        let pending = Pending(id: id, originalRelativePath: relativePath, name: name, isDirectory: Self.isDirectory(source))
        do {
            try writeJSON(pending, to: pendingName, in: directory.fd)
            // EXDEV is deliberately not converted to copy/delete. A failed
            // same-volume rename leaves the original bytes at their old path.
            try move(parent.fd, name, directory.fd, payloadName)
        } catch {
            removeRecords(in: directory.fd)
            _ = unlinkat(storage.fd, directoryName, AT_REMOVEDIR)
            throw error
        }

        // The retention clock starts only after the payload has moved.
        let deletedAt = nowDate()
        let entry = Entry(id: id, originalRelativePath: relativePath, name: name,
                          isDirectory: pending.isDirectory, deletedAt: deletedAt,
                          expiresAt: deletedAt.addingTimeInterval(Self.retentionInterval))
        do {
            guard valid(entry), let stored = try node(directory.fd, payloadName),
                  stored.st_dev == source.st_dev, stored.st_ino == source.st_ino,
                  try validPayload(directory.fd, isDirectory: entry.isDirectory) else { throw TrashError.invalidEntry }
            try writeJSON(entry, to: metadataName, in: directory.fd)
            _ = unlinkat(directory.fd, pendingName, 0)
            _ = fsync(parent.fd)
            _ = fsync(storage.fd)
            return entry
        } catch {
            // Never overwrite a file that appeared at the original location
            // while the metadata was being committed. If rollback cannot run,
            // the pending record lets listing recover the retained payload.
            do {
                try move(directory.fd, payloadName, parent.fd, name)
                removeRecords(in: directory.fd)
                _ = unlinkat(storage.fd, directoryName, AT_REMOVEDIR)
            } catch { throw TrashError.recoveryRequired }
            throw error
        }
    }

    func entries() throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let storage = try trashDirectory(create: false) else { return [] }
        var result: [Entry] = []
        for name in try names(in: storage.fd) {
            guard let id = UUID(uuidString: name), name == id.uuidString,
                  let directory = try? openDirectory(storage.fd, name),
                  let entry = try? validatedEntry(id, in: directory.fd) else { continue }
            result.append(entry)
        }
        return result.sorted {
            if $0.deletedAt != $1.deletedAt { return $0.deletedAt > $1.deletedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Restores the original path, adding a numeric suffix to its filename if
    /// occupied. Missing parents are recreated without traversing symlinks.
    @discardableResult func restore(_ id: UUID) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let storage = try trashDirectory(create: false) else { throw TrashError.missingEntry }
        guard let item = try node(storage.fd, id.uuidString) else { throw TrashError.missingEntry }
        guard Self.isDirectory(item) else { throw TrashError.invalidEntry }
        let directory = try openDirectory(storage.fd, id.uuidString)
        let entry = try validatedEntry(id, in: directory.fd)
        guard entry.expiresAt > nowDate() else { throw TrashError.expiredEntry }
        let components = try checkedComponents(entry.originalRelativePath)
        let parent = try sourceParent(components, create: true)
        var number = 1
        while true {
            let name = restoredName(entry.name, isDirectory: entry.isDirectory, number: number)
            do {
                try move(directory.fd, payloadName, parent.fd, name)
                // The data is restored already. Cleanup cannot turn this into
                // a failed restore or cause a second copy on a later retry.
                removeRecords(in: directory.fd)
                _ = unlinkat(storage.fd, id.uuidString, AT_REMOVEDIR)
                _ = fsync(parent.fd)
                _ = fsync(storage.fd)
                let path = (components.dropLast() + [name]).joined(separator: "/")
                return root.appendingPathComponent(path)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                number += 1
            }
        }
    }

    /// Malformed or incomplete entries are retained. Only a validated record
    /// with its exact 15-day deadline may authorize permanent payload removal.
    @discardableResult func purgeExpired() throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        guard let storage = try trashDirectory(create: false) else { return [] }
        let now = nowDate()
        var removed: [UUID] = []
        for name in try names(in: storage.fd) {
            guard let id = UUID(uuidString: name), name == id.uuidString,
                  let directory = try? openDirectory(storage.fd, name),
                  let entry = try? validatedEntry(id, in: directory.fd),
                  entry.expiresAt <= now else { continue }
            try removeNode(directory.fd, payloadName)
            removeRecords(in: directory.fd)
            // Unexpected files in an entry directory are left untouched.
            _ = unlinkat(storage.fd, name, AT_REMOVEDIR)
            removed.append(id)
        }
        if !removed.isEmpty { _ = fsync(storage.fd) }
        return removed
    }

    private func checkedComponents(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              parts.first?.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(storageName) != .orderedSame else {
            throw VaultCoreError.unsafeLocation(root.appendingPathComponent(path))
        }
        return parts
    }

    private func sourceParent(_ components: [String], create: Bool) throws -> Directory {
        let copy = dup(rootDirectory.fd)
        guard copy >= 0 else { throw Self.systemError() }
        var current = Directory(copy)
        for component in components.dropLast() {
            if try node(current.fd, component) == nil, create {
                if mkdirat(current.fd, component, 0o755) != 0, errno != EEXIST { throw Self.systemError() }
            }
            do { current = try openDirectory(current.fd, component) }
            catch { throw VaultCoreError.unsafeLocation(root.appendingPathComponent(components.joined(separator: "/"))) }
        }
        return current
    }

    private func trashDirectory(create: Bool) throws -> Directory? {
        if try node(rootDirectory.fd, storageName) == nil {
            guard create else { return nil }
            if mkdirat(rootDirectory.fd, storageName, 0o700) != 0, errno != EEXIST { throw Self.systemError() }
        }
        do { return try openDirectory(rootDirectory.fd, storageName) }
        catch { throw TrashError.unsafeStorage }
    }

    private func validatedEntry(_ id: UUID, in directory: Int32) throws -> Entry {
        let entry: Entry
        if try node(directory, metadataName) != nil {
            entry = try readJSON(Entry.self, from: metadataName, in: directory)
        } else {
            // A crash after moving the payload, but before committing its
            // timestamp, gives it a full retention period when recovered.
            let pending = try readJSON(Pending.self, from: pendingName, in: directory)
            guard pending.id == id, validPath(pending.originalRelativePath, name: pending.name),
                  try validPayload(directory, isDirectory: pending.isDirectory) else { throw TrashError.invalidEntry }
            let now = nowDate()
            entry = Entry(id: id, originalRelativePath: pending.originalRelativePath, name: pending.name,
                          isDirectory: pending.isDirectory, deletedAt: now,
                          expiresAt: now.addingTimeInterval(Self.retentionInterval))
            guard valid(entry) else { throw TrashError.invalidEntry }
            try writeJSON(entry, to: metadataName, in: directory)
            _ = unlinkat(directory, pendingName, 0)
        }
        guard entry.id == id, valid(entry), try validPayload(directory, isDirectory: entry.isDirectory) else {
            throw TrashError.invalidEntry
        }
        return entry
    }

    private func valid(_ entry: Entry) -> Bool {
        let deleted = entry.deletedAt.timeIntervalSince1970, expires = entry.expiresAt.timeIntervalSince1970
        return deleted.isFinite && expires.isFinite
            && expires > deleted
            && entry.expiresAt == entry.deletedAt.addingTimeInterval(Self.retentionInterval)
            && validPath(entry.originalRelativePath, name: entry.name)
    }

    private func validPath(_ path: String, name: String) -> Bool {
        guard let components = try? checkedComponents(path) else { return false }
        return components.last == name
    }

    private func validPayload(_ directory: Int32, isDirectory: Bool) throws -> Bool {
        guard let info = try node(directory, payloadName) else { return false }
        return isDirectory ? Self.isDirectory(info) : Self.isRegular(info)
    }

    private func restoredName(_ name: String, isDirectory: Bool, number: Int) -> String {
        guard number > 1 else { return name }
        let original = name as NSString
        let ext = isDirectory ? "" : original.pathExtension
        var stem = ext.isEmpty ? name : original.deletingPathExtension
        var ending = " \(number)" + (ext.isEmpty ? "" : "." + ext)
        // Keep a maximal-length filename restorable even when its original
        // name is occupied. If its extension is exceptionally long, treat the
        // complete name as a stem instead of dropping most of the basename.
        if ending.utf8.count >= Int(MAXNAMLEN) {
            stem = name; ending = " \(number)"
        }
        while (stem + ending).utf8.count > Int(MAXNAMLEN), !stem.isEmpty { stem.removeLast() }
        return stem + ending
    }

    private func openDirectory(_ parent: Int32, _ name: String) throws -> Directory {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.systemError() }
        return Directory(fd)
    }

    private func node(_ directory: Int32, _ name: String) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw Self.systemError()
    }

    private static func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    private static func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }

    private func move(_ sourceDirectory: Int32, _ source: String, _ destinationDirectory: Int32, _ destination: String) throws {
        guard renameatx_np(sourceDirectory, source, destinationDirectory, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.systemError()
        }
    }

    private func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Self.systemError() }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Self.systemError() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw Self.systemError() }
                return result
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from name: String, in directory: Int32) throws -> T {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TrashError.invalidEntry }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.isRegular(info), info.st_size > 0, info.st_size <= 65_536 else {
            throw TrashError.invalidEntry
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TrashError.invalidEntry }
                offset += count
            }
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TrashError.invalidEntry }
    }

    private func writeJSON<T: Encodable>(_ value: T, to name: String, in directory: Int32) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = ".record-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.systemError() }
        defer { Darwin.close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.systemError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Self.systemError() }
        try move(directory, temporary, directory, name)
        _ = fsync(directory)
    }

    private func removeRecords(in directory: Int32) {
        _ = unlinkat(directory, metadataName, 0)
        _ = unlinkat(directory, pendingName, 0)
    }

    private func removeNode(_ parent: Int32, _ name: String) throws {
        guard let info = try node(parent, name) else { return }
        if Self.isDirectory(info) {
            let directory = try openDirectory(parent, name)
            for child in try names(in: directory.fd) { try removeNode(directory.fd, child) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Self.systemError() }
        } else {
            // Includes symlinks: unlinkat removes the link itself.
            guard unlinkat(parent, name, 0) == 0 else { throw Self.systemError() }
        }
    }

    private static func systemError(path: String? = nil) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: path.map { [NSFilePathErrorKey: $0] })
    }
}
