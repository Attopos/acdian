import Foundation
import AppKit

@main
struct AttachmentInsertTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-attachment-insert-tests-\(UUID().uuidString)",isDirectory:true)
        let suite = "acdian-attachment-insert-tests-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated test preferences") }
        defer { try? fm.removeItem(at:root); preferences.removePersistentDomain(forName:suite) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"AttachmentInsertTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        let vault = root.appendingPathComponent("vault",isDirectory:true), outside = root.appendingPathComponent("outside",isDirectory:true)
        try fm.createDirectory(at:vault,withIntermediateDirectories:true); try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("# Page\n".utf8).write(to:vault.appendingPathComponent("Page.md"))
        let model = AppModel(loadInitialVault:false,preferences:preferences)
        model.index = try VaultIndex(root:vault)
        try check(!model.acceptsAttachments && !model.insertImage(Data([1]),ext:"png"),"Nothing is stored while no page is open")
        model.selected = model.index?.files.first { $0.relativePath == "Page.md" }
        try check(model.acceptsAttachments,"An open page accepts attachments")

        // A pasted picture gets a timestamped name in a new Attachments folder.
        let png = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
        try check(model.insertImage(png,ext:"png"),"A pasted picture is stored")
        let pasted = try fm.contentsOfDirectory(atPath:vault.appendingPathComponent("Attachments").path)
        try check(pasted.count == 1 && pasted[0].hasPrefix("Pasted image ") && pasted[0].hasSuffix(".png"),"The picture is saved in Attachments as Pasted image <time>.png: \(pasted)")
        try check(model.insertion?.text == "![[Attachments/\(pasted[0])]]" && model.insertion?.block == true,"The picture is embedded at the caret on a line of its own")
        try check(try Data(contentsOf:vault.appendingPathComponent("Attachments/\(pasted[0])")) == png,"The stored bytes are the pasted picture")
        try check(model.index?.files.contains { $0.relativePath == "Attachments/\(pasted[0])" } == true && model.index?.resolve("Attachments/\(pasted[0])",from:"Page.md") != nil,"The new file is in the index and its link resolves without a rescan")
        try check(!model.loading,"Storing a picture does not lock the editor for a rescan")

        // Dropped files keep their names, never overwrite, and only images embed.
        let photo = outside.appendingPathComponent("photo #1 [a].JPG"), notes = outside.appendingPathComponent("notes.txt")
        try png.write(to:photo); try Data("hi".utf8).write(to:notes)
        try check(model.insertAttachments([photo,notes]),"Dropped files are stored")
        try check(model.insertion?.text == "![[Attachments/photo -1 -a-.JPG]]\n[[Attachments/notes.txt]]","Images embed, other files link, and link-breaking characters become dashes: \(model.insertion?.text ?? "nil")")
        try check(model.insertAttachments([photo]) && model.insertion?.text == "![[Attachments/photo -1 -a--2.JPG]]","A second copy gets a number instead of overwriting")
        try check(fm.fileExists(atPath:photo.path),"Dropping copies; the original stays")
        try check(try String(contentsOf:vault.appendingPathComponent("Attachments/notes.txt"),encoding:.utf8) == "hi","Files are copied byte for byte")

        // The pasteboard reader tells a picture from text that brings a picture of itself.
        let pasteboard = NSPasteboard(name:NSPasteboard.Name("acdian-test-\(UUID().uuidString)"))
        pasteboard.declareTypes([.png],owner:nil); pasteboard.setData(png,forType:.png)
        try check(AttachmentPasteboard.image(pasteboard)?.ext == "png","A picture on its own is an image")
        pasteboard.declareTypes([.png,.string],owner:nil); pasteboard.setData(png,forType:.png); pasteboard.setString("A table row",forType:.string)
        try check(AttachmentPasteboard.image(pasteboard) == nil,"Text with a picture of itself stays text")
        pasteboard.declareTypes([.tiff,.string],owner:nil); pasteboard.setData(NSImage(data:png)!.tiffRepresentation!,forType:.tiff); pasteboard.setString("https://example.com/a.png",forType:.string)
        try check(AttachmentPasteboard.image(pasteboard)?.ext == "png","A browser image with its address is an image, converted from TIFF to PNG")
        pasteboard.clearContents(); pasteboard.writeObjects([photo as NSURL,outside as NSURL])
        try check(AttachmentPasteboard.fileURLs(pasteboard).map(\.lastPathComponent) == [photo.lastPathComponent],"Copied files are read, folders are skipped")
        pasteboard.releaseGlobally()
        print("Attachment insert tests passed: \(checks) checks")
    }
}
