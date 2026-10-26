import SwiftUI
import AppKit

// Times scanning, reading and searching a pages folder with thousands of pages.
// Usage: vault-benchmark <pages folder>
@main
struct VaultBenchmark {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath:args[1])
        func ms(_ start: Date) -> String { String(format:"%.0f ms",Date().timeIntervalSince(start) * 1000) }
        var start = Date()
        let index = try VaultIndex(root:root)
        print("scan \(index.files.count) files:",ms(start))
        start = Date()
        let texts = index.files.filter { $0.ext == "md" }.compactMap { try? VaultFileIO.readMarkdown(at:$0.url,allowedRoot:root) }
        print("read \(texts.count) pages for search:",ms(start))

        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "acdian-cards-benchmark-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = .english
        LiveEditorHost.shared.model = model
        for _ in 0..<1000 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        for _ in 0..<1000 where model.searchedPageCount < texts.count { try await Task.sleep(nanoseconds:10_000_000) }
        for query in ["ab","relinquish","less strong"] {
            start = Date(); model.query = query; let count = model.matches.count
            print("sidebar search \"\(query)\" (\(count) results):",ms(start))
        }
        exit(0)
    }
}
