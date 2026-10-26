import Foundation

/// Image and video kinds the app shows and the Attachments module manages.
enum MediaKinds {
    static let images: Set<String> = ["png","jpg","jpeg","gif","webp","svg","heic","tiff","tif","bmp","avif"]
    static let videos: Set<String> = ["mp4","mov","m4v","webm","mkv","avi"]
    static func isMedia(_ ext: String) -> Bool { images.contains(ext) || videos.contains(ext) }
}

/// A module is a folder of pages shown as an app-like tile in the launcher.
/// Its sidebar, search and new pages stay inside that folder.
struct PageModule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case pages, attachments }
    var id: String { folder }
    var name: String
    var folder: String
    var icon: String
    var color: String
    var kind: Kind = .pages
    var hidden = false

    init(name: String, folder: String, icon: String, color: String, kind: Kind = .pages, hidden: Bool = false) {
        self.name = name; self.folder = folder; self.icon = icon; self.color = color; self.kind = kind; self.hidden = hidden
    }
    private enum CodingKeys: String, CodingKey { case name, folder, icon, color, kind, hidden }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        folder = try values.decode(String.self,forKey:.folder)
        name = try values.decodeIfPresent(String.self,forKey:.name) ?? folder
        icon = try values.decodeIfPresent(String.self,forKey:.icon) ?? "folder"
        color = try values.decodeIfPresent(String.self,forKey:.color) ?? "pink"
        kind = (try? values.decodeIfPresent(Kind.self,forKey:.kind)) ?? .pages
        hidden = try values.decodeIfPresent(Bool.self,forKey:.hidden) ?? false
    }
    /// Whether a vault path lies inside this module's folder.
    func contains(_ path: String) -> Bool { path.hasPrefix(folder + "/") }
}

/// The module list lives in a hidden `.acdian-modules.json` at the vault root.
/// Without one, every top-level folder becomes a module in sidebar order.
enum ModuleStore {
    static let fileName = ".acdian-modules.json"
    private struct File: Codable { var modules: [PageModule] }

    static let icons = [
        "point.topleft.down.to.point.bottomright.curvepath", "sparkles", "lightbulb", "brain.head.profile", "book.closed", "books.vertical",
        "character.bubble", "globe", "graduationcap", "function", "atom", "flask",
        "photo.on.rectangle.angled", "film", "music.note", "paintpalette", "camera", "map",
        "briefcase", "chart.line.uptrend.xyaxis", "hammer", "terminal", "cup.and.saucer", "leaf",
        "heart", "star", "airplane", "house", "calendar", "tray.full",
    ]
    static let colors = ["pink","black","rose","plum","amber","teal","sky","graphite"]

    static func load(root: URL) -> [PageModule] {
        if let data = try? Data(contentsOf:root.appendingPathComponent(fileName)),
           let file = try? JSONDecoder().decode(File.self,from:data) { return file.modules }
        // Nothing is written until the modules are changed, so opening a folder leaves it as it was.
        return discover(root:root)
    }
    static func save(_ modules: [PageModule], root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(File(modules:modules)).write(to:root.appendingPathComponent(fileName),options:.atomic)
    }
    static func discover(root: URL) -> [PageModule] {
        let folders = PageOrganizer(root:root).currentOrder(of:"",order:PageOrganizer.loadOrder(root:root)).filter { name in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path,isDirectory:&directory) && directory.boolValue
        }
        return folders.enumerated().map { suggested(for:$1,position:$0) }
    }
    /// A fitting icon and colour for a folder name, falling back to a plain folder.
    static func suggested(for folder: String, position: Int = 0) -> PageModule {
        let name = folder.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("attachment","assets","附件","media") { return PageModule(name:folder,folder:folder,icon:"photo.on.rectangle.angled",color:"plum",kind:.attachments) }
        if has("language","语言","lingua") { return PageModule(name:folder,folder:folder,icon:"character.bubble",color:"black") }
        if has("teach","教学","课","lesson","class") { return PageModule(name:folder,folder:folder,icon:"graduationcap",color:"rose") }
        if has("wander","wonder","mind","随笔","journal","essay") { return PageModule(name:folder,folder:folder,icon:"point.topleft.down.to.point.bottomright.curvepath",color:"pink") }
        if has("work","project","工作","项目") { return PageModule(name:folder,folder:folder,icon:"briefcase",color:"teal") }
        return PageModule(name:folder,folder:folder,icon:"folder",color:colors[position % colors.count])
    }
}

/// Finds which pages embed or link which attachments.
enum AttachmentReferences {
    private static let wiki = try! NSRegularExpression(pattern:#"!?\[\[([^\]\n]+)\]\]"#)
    private static let markdown = try! NSRegularExpression(pattern:#"!?\[[^\]\n]*\]\(([^)\n]+)\)"#)

    /// Link targets written in a page, as typed: `![[x.png|300]]` gives `x.png|300`.
    static func targets(in text: String) -> Set<String> {
        guard text.contains("[") else { return [] }
        let range = NSRange(text.startIndex...,in:text)
        var result = Set<String>()
        for match in wiki.matches(in:text,range:range) {
            if let r = Range(match.range(at:1),in:text) { result.insert(String(text[r])) }
        }
        for match in markdown.matches(in:text,range:range) {
            guard let r = Range(match.range(at:1),in:text) else { continue }
            var target = text[r].trimmingCharacters(in:.whitespaces)
            if target.hasPrefix("<"), let end = target.firstIndex(of:">") { target = String(target[target.index(after:target.startIndex)..<end]) }
            else if let space = target.firstIndex(where: { $0.isWhitespace }) { target = String(target[..<space]) }
            if !target.isEmpty { result.insert(target) }
        }
        return result
    }
    /// The vault path of a resolved link target, if it is an image or video inside `folder`.
    static func media(_ target: String, from page: String, index: VaultIndex, folder: String) -> String? {
        guard let url = index.resolve(target,from:page), let path = relativePath(url,root:index.root),
              path.hasPrefix(folder + "/"), MediaKinds.isMedia(url.pathExtension.lowercased()) else { return nil }
        return path
    }
    /// A URL's path inside the vault. Both sides are compared in the same
    /// canonical form, since macOS reports some locations with and without /private.
    static func relativePath(_ url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }
    static func media(in targets: Set<String>, from page: String, index: VaultIndex, folder: String) -> Set<String> {
        Set(targets.compactMap { media($0,from:page,index:index,folder:folder) })
    }
    /// The bare file name a target names, without folders, label or heading.
    static func fileName(_ target: String) -> String {
        var value = target.split(separator:"|",maxSplits:1,omittingEmptySubsequences:false).first.map(String.init) ?? target
        value = value.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false).first.map(String.init) ?? value
        value = value.removingPercentEncoding ?? value
        return (value.trimmingCharacters(in:.whitespaces) as NSString).lastPathComponent
    }
    /// For each attachment, the pages that link to it.
    static func usage(pages: [(path: String, text: String)], index: VaultIndex, folder: String) -> [String:[String]] {
        var result: [String:[String]] = [:]
        for page in pages {
            for media in media(in:targets(in:page.text),from:page.path,index:index,folder:folder) { result[media,default:[]].append(page.path) }
        }
        return result
    }
    /// Whether any page links to the attachment. Pages that never mention its
    /// file name are skipped without parsing.
    static func isReferenced(_ mediaPath: String, pages: [(path: String, text: String)], index: VaultIndex, folder: String) -> Bool {
        let name = (mediaPath as NSString).lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? name
        for page in pages where page.text.localizedCaseInsensitiveContains(name) || page.text.localizedCaseInsensitiveContains(encoded) {
            if targets(in:page.text).contains(where: { media($0,from:page.path,index:index,folder:folder) == mediaPath }) { return true }
        }
        return false
    }
    /// The text of every page and canvas in the vault, read from disk.
    static func pagesOnDisk(_ index: VaultIndex) -> [(path: String, text: String)] {
        index.files.filter { ["md","markdown","canvas"].contains($0.ext) }.compactMap { file in
            (try? VaultFileIO.readMarkdown(at:file.url,allowedRoot:index.root)).map { (file.relativePath,$0) }
        }
    }
}
