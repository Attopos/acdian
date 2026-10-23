import Foundation
import AppKit

@main
struct NewPageTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-new-page-tests-\(UUID().uuidString)", isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "acdian-new-page-tests-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated test preferences") }
        defer { try? fm.removeItem(at:root); preferences.removePersistentDomain(forName:suite) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"NewPageTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func settle() async { try? await Task.sleep(nanoseconds:50_000_000) }
        func fixture(_ name: String) throws -> (AppModel, URL) {
            let directory = root.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            let model = AppModel(loadInitialVault:false,preferences:preferences)
            model.index = try VaultIndex(root:directory)
            return (model,directory)
        }
        func installExisting(_ model: AppModel, _ directory: URL, name: String = "Existing.md", source: String = "# Existing\n\nSaved body\n") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(source.utf8).write(to:url)
            model.index = try VaultIndex(root:directory)
            model.selected = model.index?.files.first(where: { $0.relativePath == name })
            model.text = source; model.originalText = source
            return url
        }
        func diskText(_ url: URL) throws -> String { try String(contentsOf:url,encoding:.utf8) }
        func entries(_ directory: URL) throws -> [String] { try fm.contentsOfDirectory(atPath:directory.path).sorted() }

        do {
            let (model,directory) = try fixture("blank-drafts")
            let previousGeneration = model.editorDocumentID
            let pending = EditorInsertion(text:"![[Attachments/old.png]]")
            model.insertion = pending
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            await settle()
            try check(model.isDraft && model.selected?.ext == "md", "New Page must immediately install an editable draft")
            try check(model.draftTitle.isEmpty && model.text.isEmpty && model.originalText.isEmpty && !model.dirty, "A fresh draft has an empty title and body without unsaved content")
            try check(model.editorDocumentID != previousGeneration && model.insertion == nil, "A new draft rotates editor identity and clears old attachment insertion")
            try check(completions == 1 && entries(directory).isEmpty, "Opening a new page completes once without creating a disk file")
            guard let firstDraft = model.selected else { fatalError("Draft identity missing") }
            try check(!fm.fileExists(atPath:firstDraft.url.path), "The draft's editor identity must not refer to a created file")
            model.draftTitle = "A title"
            try check(model.dirty, "A title edit alone must mark the draft dirty")
            model.draftTitle = ""
            try check(!model.dirty, "Reverting an empty draft title restores its clean state")
            model.text = "Body 中文🌸"
            try check(model.dirty, "A body edit alone must mark the draft dirty")
            model.text = ""
            let firstGeneration = model.editorDocumentID
            model.newPageFromEditor { completions += 1 }
            await settle()
            try check(model.selected?.relativePath != firstDraft.relativePath && model.editorDocumentID != firstGeneration, "Separate drafts must have distinct stable editor identities")
            try check(completions == 2 && entries(directory).isEmpty, "Leaving an untouched draft requires no disk write")
        }

        do {
            let directory = root.appendingPathComponent("automatic-pages",isDirectory:true)
            let model = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:directory)
            let generation = model.editorDocumentID
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            await settle()
            try check(model.isDraft && model.selected?.ext == "md" && model.editorDocumentID != generation && completions == 1, "New Page must immediately install a draft without prior storage setup")
            try check(model.index?.root == directory.standardizedFileURL.resolvingSymlinksInPath() && entries(directory).isEmpty, "New Page creates automatic local storage without materializing the draft")
        }

        do {
            let (model,directory) = try fixture("snapshot-before-new")
            let url = try installExisting(model,directory)
            let saved = model.text, generation = model.editorDocumentID
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            try check(!model.isDraft && model.selected?.relativePath == "Existing.md" && model.editorDocumentID == generation && completions == 0, "New Page must wait for the current editor snapshot")
            callback?(.success(EditorSnapshot(text:saved,currentPath:"Existing.md")))
            await settle()
            try check(model.isDraft && model.text.isEmpty && completions == 1, "A current clean snapshot permits direct draft installation")
            let installedGeneration = model.editorDocumentID
            callback?(.success(EditorSnapshot(text:"duplicate callback",currentPath:"Existing.md")))
            await settle()
            try check(model.isDraft && model.text.isEmpty && model.editorDocumentID == installedGeneration && completions == 1, "Duplicate old snapshot callbacks must not reinstall a draft or overwrite it")
            try check(diskText(url) == saved && entries(directory) == ["Existing.md"], "Draft installation preserves existing Markdown and creates no extra files")
        }

        do {
            let (model,directory) = try fixture("snapshot-save-conflict")
            let url = try installExisting(model,directory)
            let saved = model.text, generation = model.editorDocumentID
            let pending = EditorInsertion(text:"![[Attachments/pending.png]]")
            model.insertion = pending
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            let finalText = saved + "Last keystroke 中文🌸"
            try Data("Externally changed body".utf8).write(to:url)
            callback?(.success(EditorSnapshot(text:finalText,currentPath:"Existing.md")))
            await settle()
            try check(completions == 0 && !model.isDraft && model.error != nil, "A save conflict must abort New Page without a leave-decision dialog")
            try check(model.text == finalText && model.dirty && model.editorDocumentID == generation && model.insertion == pending, "A failed automatic save retains newest text, identity and pending insertion")
            try check(diskText(url) == "Externally changed body", "A save conflict must not overwrite external edits")
            try Data(saved.utf8).write(to:url)
            model.error = nil
            model.newPageFromEditor { completions += 1 }
            callback?(.success(EditorSnapshot(text:finalText,currentPath:"Existing.md")))
            await settle()
            try check(completions == 1 && model.isDraft && model.text.isEmpty && model.insertion == nil, "A successful retry saves before installing one clean new page")
            try check(diskText(url) == finalText, "Navigation automatically saves the newest editor snapshot")
        }

        do {
            let (model,directory) = try fixture("snapshot-save-before-new")
            let url = try installExisting(model,directory)
            let finalText = model.text + "Final committed body"
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            callback?(.success(EditorSnapshot(text:finalText,currentPath:"Existing.md")))
            await settle()
            try check(diskText(url) == finalText && model.isDraft && model.text.isEmpty && completions == 1, "New Page automatically persists the newest snapshot before installing the new page")
        }

        do {
            let (model,directory) = try fixture("snapshot-guards")
            _ = try installExisting(model,directory)
            let original = model.text
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            model.editorDocumentID = UUID()
            callback?(.success(EditorSnapshot(text:"stale generation",currentPath:"Existing.md")))
            await settle()
            try check(!model.isDraft && model.text == original && model.error == nil && completions == 0, "Stale same-file snapshots must silently cancel New Page")
            model.newPageFromEditor { completions += 1 }
            callback?(.success(EditorSnapshot(text:"wrong path",currentPath:"Other.md")))
            await settle()
            try check(!model.isDraft && model.text == original && model.error != nil && completions == 0, "Wrong-path snapshots must report an error and preserve the active document")
            model.error = nil
            model.newPageFromEditor { completions += 1 }
            callback?(.failure(URLError(.cannotParseResponse)))
            await settle()
            try check(!model.isDraft && model.text == original && model.error != nil && completions == 0, "A failed snapshot must not navigate or lose native text")
        }

        do {
            let (model,directory) = try fixture("draft-snapshot")
            model.newPageFromEditor()
            model.draftTitle = "Keep this title"
            model.text = "Native body"
            let generation = model.editorDocumentID, path = model.selected!.relativePath
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var completions = 0
            model.newPageFromEditor { completions += 1 }
            try check(callback != nil, "Drafts must participate in latest-editor snapshot capture too")
            try fm.removeItem(at:directory)
            callback?(.success(EditorSnapshot(text:"Newest draft body 中文🌸",currentPath:path)))
            await settle()
            try check(model.isDraft && model.draftTitle == "Keep this title" && model.text == "Newest draft body 中文🌸" && model.editorDocumentID == generation && completions == 0, "A failed pre-navigation save preserves the draft title and newest editor body")
            try check(!fm.fileExists(atPath:directory.path), "Failed draft navigation must not create partial storage")
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            model.error = nil
            model.editorSnapshot = nil
            model.newPageFromEditor { completions += 1 }
            await settle()
            try check(diskText(directory.appendingPathComponent("Keep this title.md")) == "# Keep this title\n\nNewest draft body 中文🌸", "Retrying New Page saves the draft title and latest body before transition")
            try check(model.isDraft && model.draftTitle.isEmpty && model.text.isEmpty && completions == 1, "Automatic save-and-new installs one clean replacement draft")
        }

        do {
            let (model,directory) = try fixture("first-save")
            model.newPageFromEditor()
            let draftPath = model.selected!.relativePath, generation = model.editorDocumentID
            model.draftTitle = "  研究 / 建议: 🌸  "
            model.text = "Body from native"
            var callback: ((Result<EditorSnapshot, Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            model.saveFromEditor()
            try check(model.isDraft && entries(directory).isEmpty, "First Save must wait for the draft's latest editor body")
            let body = "第一行🌸\r\n\r\n**Bold** and - [ ] todo\r\n"
            let bodyAnchor = "第一行🌸".utf16.count
            let bodyHead = "第一行🌸\n\n**Bold".utf16.count
            callback?(.success(EditorSnapshot(text:body,currentPath:draftPath,selectionAnchor:bodyAnchor,selectionHead:bodyHead)))
            await settle()
            guard let savedPath = model.currentPagePath, let file = model.index?.files.first(where: { $0.relativePath == savedPath }) else { fatalError("Saved draft backing file missing") }
            try check(model.isDraft && model.selected?.relativePath == draftPath && model.editorDocumentID == generation, "First Save preserves the draft editor identity so selection and undo history remain live")
            try check(file.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && !file.name.contains(":"), "Sanitized draft filenames must stay inside the selected vault")
            let serialized = "# 研究 / 建议: 🌸\n\n" + body
            try check(diskText(file.url) == serialized, "Filename sanitization must preserve the actual title, body, Unicode and body newlines")
            try check(model.text == body && model.originalText == body && !model.dirty, "A saved draft keeps body-only editor text and a clean body baseline")
            try check(model.editorSelection?.anchor == bodyAnchor && model.editorSelection?.head == bodyHead && model.pendingEditorSelection == nil, "First Save keeps canonical UTF-16 selection in the current editor without scheduling replacement")
            let savedGeneration = model.editorDocumentID
            callback?(.success(EditorSnapshot(text:"late draft body",currentPath:draftPath)))
            await settle()
            try check(model.text == body && model.currentPagePath == savedPath && model.selected?.relativePath == draftPath && model.editorDocumentID == savedGeneration, "A duplicate first-save snapshot cannot overwrite the saved draft body")
            model.editorSnapshot = nil
            model.text += "Follow-up edit"
            model.saveFromEditor()
            try check(model.currentPagePath == savedPath && entries(directory).count == 1 && diskText(file.url) == "# 研究 / 建议: 🌸\n\n" + model.text, "Later saves update the same backing note without creating extra files")
            try check(model.pendingEditorSelection == nil, "Later saves must not replay a consumed draft selection")
        }

        do {
            let (model,directory) = try fixture("unique-filenames")
            let occupied = directory.appendingPathComponent("Same.md")
            try Data("Keep existing file".utf8).write(to:occupied)
            model.index = try VaultIndex(root:directory)
            var savedPaths = Set<String>()
            for body in ["First draft", "Second draft"] {
                model.newPageFromEditor()
                try check(model.pendingEditorSelection == nil, "New Page clears selection restoration from the previous document")
                model.draftTitle = "Same"
                model.text = body
                try check(model.save(), "A titled draft should save successfully")
                guard let savedPath = model.currentPagePath, let file = model.index?.files.first(where: { $0.relativePath == savedPath }) else { fatalError("Unique saved backing page missing") }
                savedPaths.insert(file.relativePath)
                try check(file.relativePath != "Same.md" && diskText(file.url) == "# Same\n\n" + body, "A duplicate title must create a unique file with the correct body")
            }
            try check(savedPaths.count == 2 && entries(directory).count == 3 && diskText(occupied) == "Keep existing file", "Repeated duplicate titles must never overwrite an existing note or another new page")
        }

        do {
            let (model,directory) = try fixture("blank-explicit-save")
            model.newPageFromEditor()
            try check(!model.dirty && model.save(), "Explicit Save may save an untouched empty draft")
            try check(model.isDraft && model.currentPagePath == "New Page.md" && diskText(directory.appendingPathComponent("New Page.md")) == "# New Page\n\n", "An explicitly saved empty draft uses New Page as its backing title and filename")
            try check(model.text.isEmpty && model.pendingEditorSelection == nil, "Saving an empty draft keeps the live empty body without replacing the editor")
        }

        do {
            let (model,directory) = try fixture("save-failure-and-home")
            model.newPageFromEditor()
            model.draftTitle = "Retained draft"
            model.text = "Do not lose this body"
            let path = model.selected?.relativePath, generation = model.editorDocumentID
            try fm.removeItem(at:directory)
            try check(!model.save() && model.isDraft && model.draftTitle == "Retained draft" && model.text == "Do not lose this body" && model.selected?.relativePath == path && model.editorDocumentID == generation, "A failed first save must retain the complete draft and editor identity")
            model.error = nil
            model.goHome()
            try check(model.isDraft && model.text == "Do not lose this body" && model.error != nil, "A failed pre-Home save preserves an unsaved draft")
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            model.error = nil
            model.goHome()
            try check(!model.isDraft && model.selected == nil && model.text.isEmpty && model.draftTitle.isEmpty && model.editorDocumentID != generation, "A successful pre-Home save clears the editor only after persisting the draft")
            try check(diskText(directory.appendingPathComponent("Retained draft.md")) == "# Retained draft\n\nDo not lose this body", "Going Home preserves the recovered draft on disk")
        }

        print("NewPage: \(checks) checks passed for blank drafts, direct creation, snapshot safety, dirty transitions, first save, filename safety and failure recovery")
    }
}
