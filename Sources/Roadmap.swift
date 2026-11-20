import Foundation

struct RoadmapDomain: Codable, Equatable {
    var id: String
    var title: String
    var color: String
    var glyph: String?
    var order: Int
    var subtitle: String? = nil
}
struct RoadmapPoint: Codable, Equatable {
    var text: String
    var page: String
    var heading: String
}
struct RoadmapNode: Codable, Equatable {
    var id: String
    var title: String
    var domain: String
    var level: Int
    var pages: [String]
    var summary: String
    var keyPoints: [RoadmapPoint]
    var x: Double?
    var y: Double?
    var status: String
    var updated: Double
    var draft: Bool?
    /// Where a node without a page got its summary from.
    var note: String?
    var subtitle: String? = nil
}
struct RoadmapEdge: Codable, Equatable {
    var id: String
    var from: String
    var to: String
    var kind: String
    var why: String
    var updated: Double
    var directed: Bool { kind == "requires" || kind == "applies" }
}
struct RoadmapViewport: Codable, Equatable { var x: Double; var y: Double; var k: Double }

/// A knowledge roadmap, stored whole in one `.acdian` file. Pages carry no
/// roadmap fields; nodes point at pages by their path inside `source`.
struct RoadmapDocument: Codable, Equatable {
    static let statuses = ["new","learning","learned"], kinds = ["requires","applies","related"]
    static let maxBytes = 2_000_000, tombstoneLife: Double = 90 * 86400
    var component = ComponentKind.roadmap.rawValue
    var source = ""
    var version = 1
    var title: String?
    var domains: [RoadmapDomain] = []
    var nodes: [RoadmapNode] = []
    var edges: [RoadmapEdge] = []
    /// Deleted nodes and edges ("node:id", "edge:id") with when, so a sync cannot bring them back.
    var removed: [String: Double] = [:]
    var view: RoadmapViewport?
    var exclude: [String] = []

    static func read(_ url: URL) -> RoadmapDocument? {
        guard let data = try? Data(contentsOf:url) else { return nil }
        return decode(data)
    }
    static func decode(_ data: Data) -> RoadmapDocument? {
        guard data.count < maxBytes, let document = try? JSONDecoder().decode(RoadmapDocument.self,from:data), document.component == ComponentKind.roadmap.rawValue else { return nil }
        return document
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func empty(source: String, title: String) -> RoadmapDocument {
        RoadmapDocument(source:source,title:title,domains:[RoadmapDomain(id:"general",title:title,color:"graphite",glyph:nil,order:0)])
    }
    /// Page keys follow a page or folder that was renamed or moved inside the source folder.
    mutating func movePages(from old: String, to new: String, at time: Double) {
        func moved(_ key: String) -> String? { key == old ? new : key.hasPrefix(old + "/") ? new + key.dropFirst(old.count) : nil }
        for i in nodes.indices {
            var changed = false
            for j in nodes[i].pages.indices { if let key = moved(nodes[i].pages[j]) { nodes[i].pages[j] = key; changed = true } }
            for j in nodes[i].keyPoints.indices { if let key = moved(nodes[i].keyPoints[j].page) { nodes[i].keyPoints[j].page = key; changed = true } }
            if changed { nodes[i].updated = max(nodes[i].updated,time) }
        }
        exclude = exclude.map { moved($0) ?? $0 }
    }
}

private struct RoadmapKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
private extension KeyedDecodingContainer where Key == RoadmapKey {
    func string(_ key: String, _ fallback: String = "") -> String { (try? decodeIfPresent(String.self,forKey:RoadmapKey(key))) ?? fallback }
    func number(_ key: String) -> Double? { (try? decodeIfPresent(Double.self,forKey:RoadmapKey(key))) ?? nil }
    func list<T: Decodable>(_ key: String, of type: T.Type) -> [T] {
        guard var values = try? nestedUnkeyedContainer(forKey:RoadmapKey(key)) else { return [] }
        var result: [T] = []
        while !values.isAtEnd { if let value = try? values.decode(T.self) { result.append(value) } else if (try? values.decode(RoadmapSkipped.self)) == nil { break } }
        return result
    }
}
private struct RoadmapSkipped: Decodable { init(from decoder: Decoder) throws {} }

extension RoadmapDomain {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:RoadmapKey.self)
        id = try values.decode(String.self,forKey:RoadmapKey("id"))
        title = values.string("title",id)
        let named = values.string("color","graphite")
        color = ModuleStore.colors.contains(named) ? named : "graphite"
        glyph = (try? values.decodeIfPresent(String.self,forKey:RoadmapKey("glyph"))) ?? nil
        order = Int(values.number("order") ?? 0)
        subtitle = (try? values.decodeIfPresent(String.self,forKey:RoadmapKey("subtitle"))) ?? nil
    }
}
extension RoadmapPoint {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:RoadmapKey.self)
        text = try values.decode(String.self,forKey:RoadmapKey("text"))
        page = values.string("page"); heading = values.string("heading")
    }
}
extension RoadmapNode {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:RoadmapKey.self)
        id = try values.decode(String.self,forKey:RoadmapKey("id"))
        guard !id.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"empty id")) }
        title = values.string("title",id); domain = values.string("domain")
        level = min(3,max(0,Int(values.number("level") ?? 0)))
        pages = values.list("pages",of:String.self); summary = values.string("summary")
        keyPoints = values.list("keyPoints",of:RoadmapPoint.self)
        x = values.number("x"); y = values.number("y")
        let named = values.string("status","new")
        status = RoadmapDocument.statuses.contains(named) ? named : "new"
        updated = values.number("updated") ?? 0
        draft = (try? values.decodeIfPresent(Bool.self,forKey:RoadmapKey("draft"))) ?? nil
        note = (try? values.decodeIfPresent(String.self,forKey:RoadmapKey("note"))) ?? nil
        subtitle = (try? values.decodeIfPresent(String.self,forKey:RoadmapKey("subtitle"))) ?? nil
    }
}
extension RoadmapEdge {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:RoadmapKey.self)
        from = try values.decode(String.self,forKey:RoadmapKey("from")); to = try values.decode(String.self,forKey:RoadmapKey("to"))
        let named = values.string("kind","related")
        kind = RoadmapDocument.kinds.contains(named) ? named : "related"
        id = values.string("id",from + (kind == "related" ? "~" : ">") + to)
        why = values.string("why"); updated = values.number("updated") ?? 0
    }
}
extension RoadmapDocument {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:RoadmapKey.self)
        component = try values.decode(String.self,forKey:RoadmapKey("component"))
        source = values.string("source"); version = Int(values.number("version") ?? 1)
        title = (try? values.decodeIfPresent(String.self,forKey:RoadmapKey("title"))) ?? nil
        domains = values.list("domains",of:RoadmapDomain.self); nodes = values.list("nodes",of:RoadmapNode.self); edges = values.list("edges",of:RoadmapEdge.self)
        removed = (try? values.decodeIfPresent([String:Double].self,forKey:RoadmapKey("removed"))) ?? [:]
        view = (try? values.decodeIfPresent(RoadmapViewport.self,forKey:RoadmapKey("view"))) ?? nil
        exclude = values.list("exclude",of:String.self)
    }
}

enum RoadmapGraph {
    /// Whether `to` can already be reached from `from` along directed edges.
    static func reaches(_ from: String, _ to: String, in edges: [RoadmapEdge]) -> Bool {
        var next: [String: [String]] = [:]
        for edge in edges where edge.directed { next[edge.from,default:[]].append(edge.to) }
        var seen: Set<String> = [from], stack = [from]
        while let at = stack.popLast() {
            if at == to { return true }
            for other in next[at] ?? [] where seen.insert(other).inserted { stack.append(other) }
        }
        return false
    }
    /// The directed edges that close a loop, newest first to go: older edges are kept.
    static func cycleEdges(_ edges: [RoadmapEdge]) -> [String] {
        var kept: [RoadmapEdge] = [], dropped: [String] = []
        for edge in edges.enumerated().sorted(by: { ($0.element.updated,$0.offset) < ($1.element.updated,$1.offset) }).map(\.element) where edge.directed {
            if edge.from == edge.to || reaches(edge.to,edge.from,in:kept) { dropped.append(edge.id) } else { kept.append(edge) }
        }
        return dropped
    }
    static func isAcyclic(_ edges: [RoadmapEdge]) -> Bool { cycleEdges(edges).isEmpty }
}

extension MetadataMerge {
    /// Joins two copies of a roadmap item by item: the newer `updated` wins, a
    /// deletion beats an edit made before it, and deletions are forgotten after 90 days.
    static func roadmap(local: RoadmapDocument, disk: RoadmapDocument?, now: Double) -> RoadmapDocument {
        var result = local
        guard let disk else { return cleaned(result,now:now) }
        result.removed = local.removed.merging(disk.removed) { max($0,$1) }
        var nodes = disk.nodes, nodeAt = Dictionary(disk.nodes.enumerated().map { ($0.element.id,$0.offset) },uniquingKeysWith: { first,_ in first })
        for node in local.nodes {
            if let i = nodeAt[node.id] { if node.updated >= nodes[i].updated { nodes[i] = node } } else { nodeAt[node.id] = nodes.count; nodes.append(node) }
        }
        var edges = disk.edges, edgeAt = Dictionary(disk.edges.enumerated().map { ($0.element.id,$0.offset) },uniquingKeysWith: { first,_ in first })
        for edge in local.edges {
            if let i = edgeAt[edge.id] { if edge.updated >= edges[i].updated { edges[i] = edge } } else { edgeAt[edge.id] = edges.count; edges.append(edge) }
        }
        result.nodes = nodes; result.edges = edges
        if local.domains.isEmpty { result.domains = disk.domains }
        if local.title == nil { result.title = disk.title }
        if local.source.isEmpty { result.source = disk.source }
        if local.exclude.isEmpty { result.exclude = disk.exclude }
        return cleaned(result,now:now)
    }
    private static func cleaned(_ document: RoadmapDocument, now: Double) -> RoadmapDocument {
        var result = document
        result.removed = result.removed.filter { now - $0.value < RoadmapDocument.tombstoneLife }
        let removed = result.removed
        result.nodes = document.nodes.filter { node in removed["node:" + node.id].map { $0 < node.updated } ?? true }
        let ids = Set(result.nodes.map(\.id))
        result.edges = document.edges.filter { edge in ids.contains(edge.from) && ids.contains(edge.to) && (removed["edge:" + edge.id].map { $0 < edge.updated } ?? true) }
        let loops = Set(RoadmapGraph.cycleEdges(result.edges))
        if !loops.isEmpty { result.edges.removeAll { loops.contains($0.id) }; for id in loops { result.removed["edge:" + id] = now } }
        return result
    }
}

enum RoadmapSummary {
    /// One sentence for a page: the paragraph under its "一句话" heading, otherwise its first paragraph of prose.
    static func extract(_ text: String, limit: Int = 80) -> String {
        let lines = text.components(separatedBy:.newlines)
        var start = 0
        if let i = lines.firstIndex(where: { $0.hasPrefix("#") && $0.contains("一句话") }) { start = i + 1 }
        var fenced = false, paragraph: [String] = []
        for raw in lines[start...] {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); if !paragraph.isEmpty { break }; continue }
            if fenced { continue }
            if line.isEmpty { if !paragraph.isEmpty { break }; continue }
            let skipped = line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("![") || line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("<") || isByline(line)
            if skipped { if !paragraph.isEmpty { break }; continue }
            paragraph.append(line)
        }
        return shortened(plain(paragraph.joined(separator:" ")),limit:limit)
    }
    private static func isByline(_ line: String) -> Bool { line.count > 2 && line.hasPrefix("*") && !line.hasPrefix("**") && line.hasSuffix("*") && !line.dropFirst().dropLast().contains("*") }
    static func plain(_ markdown: String) -> String {
        var text = markdown
        for (pattern,template) in [("!\\[\\[[^\\]]*\\]\\]",""),("!\\[[^\\]]*\\]\\([^)]*\\)",""),("\\[\\[([^\\]|]*)\\|([^\\]]*)\\]\\]","$2"),("\\[\\[([^\\]]*)\\]\\]","$1"),("\\[([^\\]]*)\\]\\([^)]*\\)","$1"),("\\*\\*|__|`|~~",""),("(?<![\\w*])\\*(?=\\S)|(?<=\\S)\\*(?![\\w*])",""),("^[-*+]\\s+|^\\d+\\.\\s+",""),("\\s+"," ")] {
            text = text.replacingOccurrences(of:pattern,with:template,options:.regularExpression)
        }
        return text.trimmingCharacters(in:.whitespaces)
    }
    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { "。！？!?".contains($0) }), head.distance(from:head.startIndex,to:end) >= limit / 2 { return String(head[...end]) }
        if let end = head.lastIndex(where: { "；;，,：:".contains($0) }), head.distance(from:head.startIndex,to:end) >= limit / 2 { return String(head[..<end]) + "…" }
        return String(text.prefix(limit - 1)) + "…"
    }
    /// Image targets embedded in a page, diagrams (SVG) first.
    static func figures(_ text: String) -> [String] {
        var found: [String] = [], fenced = false
        for raw in text.components(separatedBy:.newlines) {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || !line.contains("![") { continue }
            for pattern in ["!\\[\\[([^\\]|#]+)[^\\]]*\\]\\]","!\\[[^\\]]*\\]\\(<?([^)>\\s]+)>?[^)]*\\)"] {
                guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
                let whole = NSRange(line.startIndex...,in:line)
                for match in regex.matches(in:line,range:whole) { if let range = Range(match.range(at:1),in:line) { found.append(String(line[range]).trimmingCharacters(in:.whitespaces)) } }
            }
        }
        let images: Set<String> = ["svg","png","jpg","jpeg","gif","webp","heic"]
        let kept = found.filter { images.contains(($0 as NSString).pathExtension.lowercased()) && !$0.lowercased().hasPrefix("http") }
        return kept.filter { $0.lowercased().hasSuffix(".svg") } + kept.filter { !$0.lowercased().hasSuffix(".svg") }
    }
    /// Wiki and Markdown link targets in a page, for the page-link overlay.
    static func links(_ text: String) -> [String] {
        var found: [String] = []
        for pattern in ["(?<!!)\\[\\[([^\\]|#]+)[^\\]]*\\]\\]","(?<!!)\\[[^\\]]*\\]\\(<?([^)>#\\s]+\\.md)>?[^)]*\\)"] {
            guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) { if let range = Range(match.range(at:1),in:text) { found.append(String(text[range])) } }
        }
        return found
    }
}

/// What a roadmap needs to know about the pages in its folder, read once per version of each page.
enum RoadmapPages {
    struct Info { var summary = ""; var figures: [String] = []; var links: [String] = [] }
    private static var cache: [String: (modified: Date?, size: Int, info: Info)] = [:]
    static func info(_ page: VaultEntry) -> Info {
        if let kept = cache[page.url.path], kept.modified == page.modified, kept.size == page.size { return kept.info }
        var info = Info()
        if !CloudFiles.isNotDownloaded(page.url), page.size < 2_000_000, let data = try? Data(contentsOf:page.url) {
            let text = String(decoding:data,as:UTF8.self)
            info = Info(summary:RoadmapSummary.extract(text),figures:RoadmapSummary.figures(text),links:RoadmapSummary.links(text))
        }
        cache[page.url.path] = (page.modified,page.size,info)
        return info
    }
    static func resource(_ target: String, from page: String) -> String? {
        var components = URLComponents()
        components.scheme = "acdian-resource"; components.host = "vault"; components.path = "/" + target
        components.queryItems = [URLQueryItem(name:"from",value:page)]
        return components.url?.absoluteString
    }
}

extension AppModel {
    func roadmapPage(_ key: String, in file: VaultEntry) -> VaultEntry? {
        guard let source = RoadmapDocument.read(file.url)?.source else { return nil }
        let path = (source.isEmpty ? "" : source + "/") + key + ".md"
        return index?.files.first { $0.relativePath == path }
    }
    /// Everything the roadmap canvas draws, as the `load` message without its type.
    func roadmapPayload(_ file: VaultEntry, appearance: String, platform: String) -> [String: Any]? {
        guard let index, let document = RoadmapDocument.read(file.url), let data = try? document.encoded(),
              let roadmap = try? JSONSerialization.jsonObject(with:data) else { return nil }
        let prefix = document.source.isEmpty ? "" : document.source + "/"
        let files = index.files.filter { $0.ext == "md" && $0.relativePath.hasPrefix(prefix) }
        var pages: [[String: Any]] = [], keys: [String: String] = [:], infos: [(key: String, path: String, links: [String])] = []
        for page in files {
            let key = String(page.relativePath.dropFirst(prefix.count).dropLast(3)), info = RoadmapPages.info(page)
            keys[page.url.standardizedFileURL.path] = key
            infos.append((key,page.relativePath,info.links))
            pages.append(["key":key,"title":(page.name as NSString).deletingPathExtension,"summary":info.summary,"modified":page.modified?.timeIntervalSince1970 ?? 0,"exists":true,
                          "figures":info.figures.compactMap { RoadmapPages.resource($0,from:page.relativePath) }])
        }
        let known = Set(keys.values)
        var nodeOf: [String: String] = [:]
        for node in document.nodes { for key in node.pages { if nodeOf[key] == nil { nodeOf[key] = node.id } } }
        for key in nodeOf.keys.sorted() where !known.contains(key) {
            pages.append(["key":key,"title":(key as NSString).lastPathComponent,"summary":"","modified":0,"exists":false,"figures":[String]()])
        }
        var mentions: [[String]] = [], seen: Set<String> = []
        for item in infos {
            guard let from = nodeOf[item.key] else { continue }
            for link in item.links {
                guard let url = index.resolve(link,from:item.path), let key = keys[url.standardizedFileURL.path], let to = nodeOf[key], to != from,
                      seen.insert(from < to ? from + "|" + to : to + "|" + from).inserted else { continue }
                mentions.append([from,to])
            }
        }
        return ["roadmap":roadmap,"title":document.title ?? (file.name as NSString).deletingPathExtension,"pages":pages,"mentions":mentions,"theme":appearance,
                "language":language.rawValue,"editable":!isReadOnly(file.relativePath),"platform":platform]
    }
    /// Handles what the canvas posts, the same on Mac and iOS. Returns whether the roadmap file was written.
    @discardableResult func roadmapMessage(_ value: [String: Any], file: VaultEntry) -> Bool {
        guard let type = value["type"] as? String else { return false }
        if type == "openPage", let key = value["key"] as? String {
            guard let page = roadmapPage(key,in:file) else { error = localized("找不到链接的文件：%@\n请检查文件路径；同名文件请使用完整路径。",key); return false }
            open(page,fragment:value["heading"] as? String ?? "")
        }
        if type == "save" {
            var object: [String: Any] = ["component":ComponentKind.roadmap.rawValue]
            object["nodes"] = value["nodes"] as? [Any] ?? []; object["edges"] = value["edges"] as? [Any] ?? []; object["removed"] = value["removed"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject:object), let change = RoadmapDocument.decode(data) else { return false }
            return saveRoadmap(file,nodes:change.nodes,edges:change.edges,removed:change.removed) != nil
        }
        if type == "newPage", let id = value["id"] as? String { return newRoadmapPage(file,node:id,title:value["title"] as? String ?? "") != nil }
        if type == "viewChanged", let x = value["x"] as? Double, let y = value["y"] as? Double, let k = value["k"] as? Double {
            UserDefaults.standard.set([x,y,k],forKey:"roadmapView:" + file.relativePath)
        }
        return false
    }
    func roadmapView(_ file: VaultEntry) -> [String: Double]? {
        guard let saved = UserDefaults.standard.array(forKey:"roadmapView:" + file.relativePath) as? [Double], saved.count == 3 else { return nil }
        return ["x":saved[0],"y":saved[1],"k":saved[2]]
    }
}
