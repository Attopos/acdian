import Foundation

@main
struct LocalizationTests {
    @MainActor static func main() throws {
        let suite = "acdian-localization-tests-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName:suite) else { fatalError("Could not create test preferences") }
        defer { preferences.removePersistentDomain(forName:suite) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain:"LocalizationTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        let model = AppModel(loadInitialVault:false,preferences:preferences)
        try check(model.language == .english && model.status == "Ready", "A fresh installation must use English independently of the system locale")
        preferences.set("unsupported-locale",forKey:"appLanguage")
        try check(AppLanguage.stored(in:preferences) == .english, "Unknown saved languages must fall back to English")

        let file = URL(fileURLWithPath:"/private/tmp/Localization.md")
        model.selected = VaultEntry(relativePath:"Localization.md",url:file,name:file.lastPathComponent,isDirectory:false,children:nil,modified:nil,size:0)
        model.originalText = "# Original"
        model.text = "# Original\n\nUnsaved **edits**"
        model.query = "edits"
        model.anchor = "Original"
        let generation = model.editorDocumentID
        let selected = model.selected?.id
        var snapshotRequests = 0
        model.editorSnapshot = { _ in snapshotRequests += 1 }
        model.language = .spanish
        try check(preferences.string(forKey:"appLanguage") == "es", "Choosing a language must persist its stable identifier")
        try check(AppModel(loadInitialVault:false,preferences:preferences).language == .spanish, "A new model must restore the selected language")
        try check(model.status == "Guardando…" && model.localized("新建页面") == "Nueva página", "Existing UI and the pending-save status must immediately use Spanish")
        try check(model.language.noteCount(1) == "1 nota" && model.language.noteCount(2) == "2 notas", "Counts must use Spanish singular and plural forms")
        try check(model.localizedError(VaultCoreError.conflict(file)).contains("Otra aplicación modificó «Localization.md»"), "File safety errors must use the selected language and preserve the filename")
        try check(AppStatus.openedPages(1).localized(.english) == "Ready" && AppStatus.openedPages(1).localized(.spanish) == "Listo", "Automatic page storage must show a ready status in the active language")
        try check(AppStatus.trashed.localized(.english) == "Moved to Trash" && AppStatus.restored.localized(.spanish) == "Archivo restaurado", "Trash action statuses must use the current language")
        try check(AppLanguage.english.remainingTrashDays(1) == "1 day remaining" && AppLanguage.spanish.remainingTrashDays(1) == "Queda 1 día", "Trash retention must use singular day labels")
        try check(AppLanguage.english.remainingTrashDays(2) == "2 days remaining" && AppLanguage.spanish.remainingTrashDays(2) == "Quedan 2 días", "Trash retention must use plural day labels")
        let saved = AppStatus.saved(Date(timeIntervalSince1970:1_792_728_000))
        try check(saved.localized(.english).hasPrefix("Saved · ") && saved.localized(.spanish).hasPrefix("Guardado · "), "A saved status must be re-renderable in another language")

        model.language = .simplifiedChinese
        try check(model.localized("新建页面") == "新建页面" && model.status == "正在保存…", "The original Chinese UI and pending-save status must remain available")
        model.language = .english
        try check(model.text == "# Original\n\nUnsaved **edits**" && model.originalText == "# Original" && model.dirty, "Switching languages must preserve unsaved edits")
        try check(model.editorDocumentID == generation && model.selected?.id == selected && snapshotRequests == 0, "Switching languages must not recreate, navigate, or request a snapshot of the editor")
        try check(model.query == "edits" && model.anchor == "Original", "Switching languages must preserve navigation and search state")
        print("Localization: English default, saved language, Spanish counts/errors/status, Chinese support, and unsaved-editor preservation passed")
    }
}
