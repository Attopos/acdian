import Foundation

@main
struct EditorSnapshotTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("acdian-editor-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at:fixture,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:fixture) }
        let url = fixture.appendingPathComponent("Test.md")
        try Data("# Initial".utf8).write(to:url)
        let model = AppModel(loadInitialVault:false)
        model.index = try VaultIndex(root:fixture)
        model.selected = model.index?.files.first
        model.text = "# Initial"; model.originalText = "# Initial"
        var callback: ((Result<EditorSnapshot, Error>) -> Void)?
        model.editorSnapshot = { callback = $0 }
        func check(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !ok() { throw NSError(domain:"SnapshotTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        func settle() async { try? await Task.sleep(nanoseconds:50_000_000) }
        model.saveFromEditor()
        try check(try String(contentsOf:url,encoding:.utf8) == "# Initial", "Save should wait for editor snapshot")
        callback?(.success(EditorSnapshot(text:"# Final keystroke",currentPath:"Test.md")))
        await settle()
        try check(try String(contentsOf:url,encoding:.utf8) == "# Final keystroke", "Native save must persist the newest editor text")
        try check(model.originalText == "# Final keystroke", "Successful save updates original text")

        model.saveFromEditor()
        var savedBeforeNextMessage = false
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                callback?(.success(EditorSnapshot(text:"# Snapshot revision",currentPath:"Test.md")))
                savedBeforeNextMessage = (try? String(contentsOf:url,encoding:.utf8)) == "# Snapshot revision"
                model.text = "# Newer bridge revision"
                continuation.resume()
            }
        }
        await settle()
        try check(savedBeforeNextMessage && model.text == "# Newer bridge revision", "Main-thread snapshot must save immediately and preserve a later bridge update")
        model.text = model.originalText

        model.error = nil
        var executed = false; var cancelled = false
        model.withEditorSnapshot({ executed = true },onFailure:{ cancelled = true })
        let textBefore = model.text
        model.editorDocumentID = UUID()
        callback?(.success(EditorSnapshot(text:"stale same-file payload",currentPath:"Test.md")))
        await settle()
        try check(!executed && cancelled && model.text == textBefore && model.error == nil, "A stale same-file generation must cancel without overwriting text or showing an error")

        executed = false; cancelled = false
        model.withEditorSnapshot({ executed = true },onFailure:{ cancelled = true })
        callback?(.success(EditorSnapshot(text:"wrong file",currentPath:"Other.md")))
        await settle()
        try check(!executed && cancelled && model.error != nil && model.text == textBefore, "Wrong-path snapshots must not mutate the active document")

        model.error = nil; executed = false; cancelled = false
        model.withEditorSnapshot({ executed = true },onFailure:{ cancelled = true })
        callback?(.failure(URLError(.cannotParseResponse)))
        await settle()
        try check(!executed && cancelled && model.error != nil, "Bridge errors must cancel native actions")

        model.error = nil
        let generation = model.editorDocumentID
        model.goHome()
        let latestBeforeHome = "# Latest before Home 中文🌸\r\n"
        callback?(.success(EditorSnapshot(text:latestBeforeHome,currentPath:"Test.md")))
        await settle()
        try check(model.selected == nil && model.text.isEmpty && model.editorDocumentID != generation, "Home navigation must wait for snapshot and rotate the editor generation")
        try check(try String(contentsOf:url,encoding:.utf8) == latestBeforeHome, "Home navigation automatically writes the newest editor snapshot before clearing the page")

        model.editorSnapshot = nil
        var created = false
        model.newNoteFromEditor("Created") { created = $0 }
        await settle()
        try check(created && fm.fileExists(atPath:fixture.appendingPathComponent("Created.md").path), "New-note completion should report creation")
        try check(model.selected?.name == "Created.md" && model.text == "# Created\n\n", "New notes should open directly in the unified editor")
        model.text = "# Created\n\nFallback state"
        model.saveFromEditor()
        try check(try String(contentsOf:fixture.appendingPathComponent("Created.md"),encoding:.utf8) == model.text, "No-editor fallback should save current native state")
        print("EditorSnapshot: latest-text save, stale-generation rejection, path validation, bridge-error cancellation, home/new-note navigation, and fallback passed")
    }
}
