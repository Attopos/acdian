import Foundation

// Checks that a saved iOS listing loses what was deleted since, including a
// whole deleted folder, and keeps pages that are only iCloud placeholders.
// Build as Mac Catalyst (VaultListing is iOS-only): swiftc -target arm64-apple-ios17.0-macabi -sdk $(xcrun --sdk macosx --show-sdk-path) -Fsystem <sdk>/System/iOSSupport/System/Library/Frameworks Sources/VaultCore.swift iOS/ReaderFiles.swift Tests/ReaderSnapshotTests.swift
@main struct ReaderSnapshotTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("reader-snapshot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:root) }
        for folder in ["CS/Terms","CS/Kept","Notes"] { try fm.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true) }
        for file in ["CS/Terms/AMX.md","CS/Terms/ASIC.md","CS/Kept/A.md","CS/Gone.md","Notes/Stay.md","CS/Dictionary.acdian"] { try Data("x".utf8).write(to:root.appendingPathComponent(file)) }
        try Data().write(to:root.appendingPathComponent("Notes/.Cloud.md.icloud"))
        var scan = ReaderFiles.Scan()
        for folder in ["CS","CS/Terms","CS/Kept","Notes"] { scan.listing.append(VaultListing(relativePath:folder,isDirectory:true,modified:nil,size:0)) }
        for file in ["CS/Terms/AMX.md","CS/Terms/ASIC.md","CS/Kept/A.md","CS/Gone.md","Notes/Stay.md","Notes/Cloud.md","CS/Dictionary.acdian"] { scan.listing.append(VaultListing(relativePath:file,isDirectory:false,modified:nil,size:1)) }
        scan.remote = ["Notes/Cloud.md","CS/Terms/AMX.md"]
        // Deleted on another device: a whole folder, a page and a Card Index.
        try fm.removeItem(at:root.appendingPathComponent("CS/Terms"))
        try fm.removeItem(at:root.appendingPathComponent("CS/Gone.md"))
        try fm.removeItem(at:root.appendingPathComponent("CS/Dictionary.acdian"))
        let checked = Set(ReaderFiles.withoutDeleted(scan,root:root).listing.map(\.relativePath))
        let expected: Set<String> = ["CS","CS/Kept","Notes","CS/Kept/A.md","Notes/Stay.md","Notes/Cloud.md"]
        guard checked == expected else { print("FAIL: got \(checked.sorted())"); exit(1) }
        guard ReaderFiles.withoutDeleted(scan,root:root).remote == ["Notes/Cloud.md"] else { print("FAIL: remote"); exit(1) }
        print("Reader snapshot: deleted folders, pages and Card Indexes drop out; placeholders stay")
    }
}
