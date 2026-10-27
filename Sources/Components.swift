import Foundation

/// A component is a piece of app UI placed in the pages folder like a page:
/// a small `.acdian` file says which component it is and which folder it
/// shows. Opening it draws the component natively, never as page text.
enum ComponentKind: String, CaseIterable, Identifiable, Codable {
    case cardIndex = "card-index"
    var id: String { rawValue }
    /// Chinese source strings, translated through AppLanguage like the rest of the UI.
    var title: String {
        switch self { case .cardIndex: return "卡片索引" }
    }
    var summary: String {
        switch self {
        case .cardIndex: return "把文件夹里的每个页面显示成卡片，带字母栏和搜索，适合单词表和术语表。"
        }
    }
    var icon: String {
        switch self { case .cardIndex: return "rectangle.grid.2x2" }
    }
    var color: String {
        switch self { case .cardIndex: return "pink" }
    }
    /// Whether hiding the source folder from the sidebar is offered, and its default.
    var hidesSourceByDefault: Bool { self == .cardIndex }
}

struct ComponentInstance: Codable, Equatable {
    var component: ComponentKind
    /// The folder it shows, as a path inside the pages folder.
    var source: String
    /// Leave the source folder out of the sidebar; its pages stay searchable.
    var hideSource = false
    /// Cards per row in a Card Index; the cards stay square.
    var columns = ComponentInstance.defaultColumns
    static let defaultColumns = 6, columnRange = 2...10

    private enum CodingKeys: String, CodingKey { case component, source, hideSource, columns }
    init(component: ComponentKind, source: String, hideSource: Bool = false, columns: Int = ComponentInstance.defaultColumns) {
        self.component = component; self.source = source; self.hideSource = hideSource; self.columns = columns
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        component = try values.decode(ComponentKind.self,forKey:.component)
        source = try values.decodeIfPresent(String.self,forKey:.source) ?? ""
        hideSource = try values.decodeIfPresent(Bool.self,forKey:.hideSource) ?? false
        columns = min(max(try values.decodeIfPresent(Int.self,forKey:.columns) ?? Self.defaultColumns,Self.columnRange.lowerBound),Self.columnRange.upperBound)
    }
}

enum ComponentStore {
    static let fileExtension = "acdian"
    static func read(_ url: URL) -> ComponentInstance? {
        guard let data = try? Data(contentsOf:url), data.count < 100_000 else { return nil }
        return try? JSONDecoder().decode(ComponentInstance.self,from:data)
    }
    static func encode(_ instance: ComponentInstance) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(instance)
    }
    /// A one-line summary of a page for its card: the first definition under
    /// "## Definitions" if there is one, otherwise its first line of text.
    static func cardNote(_ text: String) -> String {
        var inDefinitions = false, fallback = ""
        for raw in text.split(separator:"\n",omittingEmptySubsequences:true) {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("#") { inDefinitions = line.lowercased().hasPrefix("## definition"); continue }
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("![") { continue }
            let plain = clean(line)
            if inDefinitions, line.hasPrefix("- "), !plain.isEmpty { return plain }
            if fallback.isEmpty, !plain.isEmpty, !line.hasPrefix(">"), !line.hasPrefix("UK /"), !line.hasPrefix("US /") { fallback = plain }
        }
        return fallback
    }
    private static func clean(_ line: String) -> String {
        var text = line
        if text.hasPrefix("- ") { text.removeFirst(2) }
        // A leading italic part of speech, as in "*noun* a frame…".
        if text.hasPrefix("*"), let end = text.dropFirst().firstIndex(of:"*") { text = String(text[text.index(after:end)...]) }
        text = text.replacingOccurrences(of:"\\",with:"").replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"==",with:"")
        text = text.trimmingCharacters(in:.whitespaces)
        return text.count > 140 ? String(text.prefix(137)) + "…" : text
    }
}
