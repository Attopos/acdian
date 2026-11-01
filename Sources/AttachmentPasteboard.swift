import AppKit
import UniformTypeIdentifiers

/// Reads what a paste or a drop from another app offers as attachments.
enum AttachmentPasteboard {
    static let imageTypes: [(NSPasteboard.PasteboardType,String)] = [(.png,"png"),(NSPasteboard.PasteboardType(UTType.jpeg.identifier),"jpg"),(NSPasteboard.PasteboardType(UTType.gif.identifier),"gif"),
                                                                     (NSPasteboard.PasteboardType(UTType.webP.identifier),"webp"),(NSPasteboard.PasteboardType(UTType.heic.identifier),"heic")]
    static var dragTypes: [NSPasteboard.PasteboardType] { [.fileURL,.tiff] + imageTypes.map(\.0) + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } }
    /// Files, not folders, copied in Finder or dragged in.
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == false }
    }
    /// A picture on its own, such as a screenshot or an image copied in a
    /// browser. Text that an app copies along with a picture of itself, as
    /// office apps do, is not a picture: it stays text.
    static func image(_ pasteboard: NSPasteboard) -> (data: Data,ext: String)? {
        if let text = pasteboard.string(forType:.string)?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty,
           !["http","https","file"].contains(URL(string:text)?.scheme?.lowercased() ?? "") { return nil }
        for (type,ext) in imageTypes { if let data = pasteboard.data(forType:type), !data.isEmpty { return (data,ext) } }
        if let data = pasteboard.data(forType:.tiff), let png = NSBitmapImageRep(data:data)?.representation(using:.png,properties:[:]) { return (png,"png") }
        return nil
    }
    static func offersAttachments(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(pasteboard).isEmpty || pasteboard.canReadObject(forClasses:[NSFilePromiseReceiver.self],options:nil) || image(pasteboard) != nil
    }
}
