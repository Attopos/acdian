import Foundation

@main
struct AutosaveTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acdian-autosave-tests-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:root)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"AutosaveTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func pause(_ interval: TimeInterval) async { try? await Task.sleep(nanoseconds:UInt64(interval * 1_000_000_000)) }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { try check(true,message); return }
                await pause(0.01)
            }
            try check(condition(),message)
        }
        func fixture(_ name: String, delay: TimeInterval = 0.03) throws -> (AppModel,URL) {
            let directory = root.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            let suite = "acdian-autosave-tests-\(UUID().uuidString)"
            suites.append(suite)
            guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create isolated preferences") }
            let model = AppModel(loadInitialVault:false,preferences:preferences,pagesRoot:directory,autosaveDelay:delay)
            model.index = try VaultIndex(root:directory)
            return (model,directory)
        }
        func disk(_ url: URL) throws -> String { try String(contentsOf:url,encoding:.utf8) }
        func select(_ model: AppModel, _ directory: URL, source: String = "# Original\r\n\r\nSaved body\r\n") throws -> URL {
            let url = directory.appendingPathComponent("Page.md")
            try Data(source.utf8).write(to:url)
            model.index = try VaultIndex(root:directory)
            model.selected = model.index?.files.first(where: { $0.relativePath == "Page.md" })
            model.originalText = source; model.text = source
            return url
        }

        do {
            let (model,directory) = try fixture("untouched-draft")
            model.newPageFromEditor()
            let identity = model.selected?.relativePath, generation = model.editorDocumentID
            await pause(0.1)
            try check(model.isDraft && model.persistedPage == nil && model.currentPagePath == nil && !model.dirty,"An untouched empty draft has no backing file")
            try check(model.saveBeforeLeaving() && (try fm.contentsOfDirectory(atPath:directory.path)).isEmpty,"Leaving a clean empty draft never materializes a page")
            try check(model.selected?.relativePath == identity && model.editorDocumentID == generation,"Checking whether the draft can leave does not replace its editor")
        }

        do {
            let (model,directory) = try fixture("title-autosave")
            model.newPageFromEditor()
            let identity = model.selected?.relativePath, generation = model.editorDocumentID
            model.draftTitle = "标题🌸"
            try check(model.persistedPage == nil,"A title edit waits for its debounce before writing")
            try await eventually("A title-only edit is automatically saved") { model.persistedPage != nil && !model.dirty }
            guard let file = model.persistedPage else { fatalError("Title-only backing file missing") }
            try check(try disk(file.url) == "# 标题🌸\n\n","Title-only autosave writes the complete Markdown page")
            try check(model.isDraft && model.text.isEmpty && model.originalText.isEmpty && model.selected?.relativePath == identity && model.editorDocumentID == generation,"First title autosave preserves the empty live draft editor")
            try check(model.currentPagePath == file.relativePath && model.index?.files.contains(where: { $0.relativePath == file.relativePath }) == true,"The real saved page is available to the sidebar without replacing the editor")
            model.draftTitle = "更新后的标题"
            try await eventually("A later title edit is automatically saved to the same file") { !model.dirty && (try? disk(file.url)) == "# 更新后的标题\n\n" }
            try check(model.currentPagePath == file.relativePath && (try fm.contentsOfDirectory(atPath:directory.path)).count == 1,"Editing a saved draft title does not create duplicate pages")
        }

        do {
            let (model,_) = try fixture("body-autosave")
            model.newPageFromEditor()
            let identity = model.selected?.relativePath, generation = model.editorDocumentID
            let body = "第一行🌸\r\n\r\n**中文正文**\r\n"
            let selection = (anchor:"第一行🌸".utf16.count,head:"第一行🌸\n\n**中文".utf16.count)
            let insertion = EditorInsertion(text:"pending attachment")
            model.text = body; model.editorSelection = selection; model.insertion = insertion
            try await eventually("A body-only draft is automatically saved") { model.persistedPage != nil && !model.dirty }
            guard let file = model.persistedPage else { fatalError("Body-only backing file missing") }
            try check(try disk(file.url) == "# New Page\n\n" + body,"Autosave preserves Chinese, emoji and exact CRLF body bytes")
            try check(model.isDraft && model.text == body && model.originalText == body && model.selected?.relativePath == identity && model.editorDocumentID == generation,"First autosave keeps the body and editor identity so the current undo history remains attached")
            try check(model.editorSelection?.anchor == selection.anchor && model.editorSelection?.head == selection.head && model.pendingEditorSelection == nil && model.insertion == insertion,"Autosave keeps the caret/range and pending insertion without reloading the editor")
            var snapshotRequests = 0
            model.editorSnapshot = { _ in snapshotRequests += 1 }
            model.open(file)
            await pause(0.05)
            try check(snapshotRequests == 0 && model.isDraft && model.selected?.relativePath == identity && model.editorDocumentID == generation,"Opening the active draft's saved sidebar entry does not snapshot or replace its editor")
            try check(model.text == body && model.draftTitle.isEmpty && model.editorSelection?.anchor == selection.anchor && model.editorSelection?.head == selection.head && model.insertion == insertion,"Selecting the current backing page preserves body, title, caret and undo ownership")
            let next = body + "继续输入"
            model.text = next
            try await eventually("Further draft typing updates its existing backing page") { !model.dirty && (try? disk(file.url)) == "# New Page\n\n" + next }
            try check(model.currentPagePath == file.relativePath && model.editorDocumentID == generation,"Later autosaves retain the same page and editor generation")
        }

        do {
            let (model,directory) = try fixture("debounced-normal-page",delay:0.25)
            let url = try select(model,directory)
            let original = model.originalText, generation = model.editorDocumentID
            model.text = original + "一"
            await pause(0.06)
            model.text = original + "一二"
            await pause(0.06)
            model.text = original + "一二三🌸"
            await pause(0.12)
            try check(try disk(url) == original && model.dirty,"Rapid edits reset the debounce instead of writing intermediate revisions")
            let final = model.text
            try await eventually("The final revision is saved after typing settles") { !model.dirty && (try? disk(url)) == final }
            try check(model.originalText == final && model.editorDocumentID == generation && model.currentPagePath == "Page.md","An ordinary-note autosave updates its baseline without reopening the editor")
        }

        do {
            let (model,directory) = try fixture("navigate-flush",delay:0.3)
            let url = try select(model,directory)
            let otherURL = directory.appendingPathComponent("Other.md")
            try Data("# Other\n".utf8).write(to:otherURL)
            model.index = try VaultIndex(root:directory)
            guard let other = model.index?.files.first(where: { $0.relativePath == "Other.md" }) else { fatalError("Navigation target missing") }
            model.text = "# Native pending body"
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            model.open(other)
            try check(callback != nil && model.currentPagePath == "Page.md","Navigation waits for the current editor snapshot before leaving")
            let latest = "# 最新中文🌸\r\n\r\nFinal keystroke\r\n"
            callback?(.success(EditorSnapshot(text:latest,currentPath:"Page.md")))
            try await eventually("Navigation opens its target after flushing the latest snapshot") { model.selected?.relativePath == "Other.md" && !model.loading }
            try check(try disk(url) == latest && model.text == "# Other\n","Pre-navigation flush writes the newest snapshot instead of the older native bridge value")
            await pause(0.4)
            try check(try disk(url) == latest && disk(otherURL) == "# Other\n" && model.text == "# Other\n","A canceled old debounce cannot write into the newly opened page")
        }

        do {
            let (model,directory) = try fixture("exit-flush",delay:0.3)
            let url = try select(model,directory)
            model.text = "# Native pending exit edit"
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var mayExit: Bool?
            model.withEditorSnapshot({ mayExit = model.saveBeforeLeaving() },onFailure:{ mayExit = false })
            try check(callback != nil && mayExit == nil,"Exit-style flush waits for the latest browser snapshot")
            let latest = "# 退出前最新内容🌸\r\n"
            callback?(.success(EditorSnapshot(text:latest,currentPath:"Page.md",selectionAnchor:4,selectionHead:4)))
            try check(mayExit == true && (try disk(url)) == latest && !model.dirty,"Exit can proceed only after the newest snapshot is synchronously saved")
            model.text = latest + "Later native edit"
            callback?(.success(EditorSnapshot(text:"stale duplicate",currentPath:"Page.md")))
            try check(model.text == latest + "Later native edit","An already-consumed exit snapshot cannot erase a newer bridge update")
            try check(model.saveBeforeLeaving() && (try disk(url)) == model.text,"A later explicit flush saves the current native state immediately")
        }

        do {
            let (model,directory) = try fixture("stale-snapshot",delay:0.15)
            let url = try select(model,directory)
            model.text = "# First pending revision"
            var callback: ((Result<EditorSnapshot,Error>) -> Void)?
            model.editorSnapshot = { callback = $0 }
            var executed = false, canceled = false
            model.withEditorSnapshot({ executed = true; model.saveBeforeLeaving() },onFailure:{ canceled = true })
            model.editorDocumentID = UUID()
            let current = "# 当前中文🌸\r\n\r\nNewest native revision\r\n"
            model.text = current
            callback?(.success(EditorSnapshot(text:"# Obsolete snapshot",currentPath:"Page.md")))
            try check(!executed && canceled && model.error == nil && model.text == current,"A stale same-file snapshot cannot flush or overwrite the current editor generation")
            try await eventually("The current generation still autosaves after rejecting an obsolete callback") { !model.dirty && (try? disk(url)) == current }
            callback?(.success(EditorSnapshot(text:"# Duplicate obsolete snapshot",currentPath:"Page.md")))
            try check(model.text == current && (try disk(url)) == current,"A repeated old callback cannot replace already persisted current content")
        }

        do {
            let (model,directory) = try fixture("write-failure")
            model.newPageFromEditor()
            let path = model.selected?.relativePath, generation = model.editorDocumentID
            try fm.removeItem(at:directory)
            model.draftTitle = "Recover this draft"; model.text = "正文不能丢🌸\r\n"
            try await eventually("A failed autosave reports its error") { model.error != nil }
            try check(model.isDraft && model.persistedPage == nil && model.dirty && model.draftTitle == "Recover this draft" && model.text == "正文不能丢🌸\r\n","An autosave write failure keeps the complete unsaved draft")
            try check(model.selected?.relativePath == path && model.editorDocumentID == generation && !model.saveBeforeLeaving(),"A failed flush blocks leaving without replacing the editor")
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            try check(model.saveBeforeLeaving() && !model.dirty,"A repaired storage location can save the retained draft on retry")
            try check(try disk(directory.appendingPathComponent("Recover this draft.md")) == "# Recover this draft\n\n正文不能丢🌸\r\n","Retry persists all retained Unicode and CRLF content")
        }

        do {
            let (model,directory) = try fixture("external-conflict")
            let url = try select(model,directory)
            let baseline = model.originalText, generation = model.editorDocumentID
            let local = "# 本地尚未保存🌸\r\n"
            model.text = local
            try Data("# Changed by another app\n".utf8).write(to:url)
            try await eventually("An external edit prevents automatic overwriting") { model.error != nil }
            try check(model.text == local && model.originalText == baseline && model.dirty && (try disk(url)) == "# Changed by another app\n","Conflict keeps both local unsaved text and the external disk version")
            try check(!model.saveBeforeLeaving() && model.editorDocumentID == generation,"A conflicting exit flush refuses to leave and preserves editor identity")
            model.goHome()
            try check(model.selected?.relativePath == "Page.md" && model.text == local,"A conflicting navigation flush leaves the current editor open")
            try Data(baseline.utf8).write(to:url)
            model.text = local + "Recovered edit"
            try await eventually("Typing after conflict recovery can save the retained content") { !model.dirty && (try? disk(url)) == local + "Recovered edit" }
        }

        print("Autosave: \(checks) checks passed for title/body debounce, coalesced edits, navigation/exit flush, stable draft editing, Unicode/CRLF, failures and conflicts")
    }
}
