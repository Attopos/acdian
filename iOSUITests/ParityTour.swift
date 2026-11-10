import XCTest

/// The iPad's Mac features over a copy of Fixtures/Vault: new page and title,
/// slash menu, tables, tabs kept across a relaunch, split view, rename, move,
/// trash and restore, a new module, a Card Index, Settings and Attachments.
/// Set TEST_RUNNER_ACDIAN_SHOTS and TEST_RUNNER_ACDIAN_DOCS like EditorTour.
final class ParityTour: XCTestCase {
    private let app = XCUIApplication()
    private func shot(_ name: String) throws {
        Thread.sleep(forTimeInterval:1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot:screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["ACDIAN_SHOTS"] else { return }
        let url = URL(fileURLWithPath:dir); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        try screenshot.pngRepresentation.write(to:url.appendingPathComponent(name + ".png"))
    }
    private func root() throws -> URL {
        let apps = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["ACDIAN_DOCS"]))
        return try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:apps,includingPropertiesForKeys:nil).map { $0.appendingPathComponent("Documents") }.first { FileManager.default.fileExists(atPath:$0.appendingPathComponent("Welcome.md").path) })
    }
    private func exists(_ path: String) -> Bool { (try? root()).map { FileManager.default.fileExists(atPath:$0.appendingPathComponent(path).path) } ?? false }
    private func text(_ path: String) -> String { (try? root()).flatMap { try? String(contentsOf:$0.appendingPathComponent(path),encoding:.utf8) } ?? "" }
    private func eventually(_ message: String, timeout: Double = 10, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return }; Thread.sleep(forTimeInterval:0.3) }
        XCTFail(message)
    }
    private func row(_ path: String) -> XCUIElement { app.buttons["row-" + path].firstMatch }
    private func menu(_ path: String, _ item: String) {
        let target = row(path)
        XCTAssertTrue(target.waitForExistence(timeout:8),"\(path) is listed")
        target.press(forDuration:1.2)
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout:4),"\(item) is in the menu")
        button.tap(); Thread.sleep(forTimeInterval:1)
    }
    func testParity() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Editing is iPad-only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--local-pages"]
        app.launch()
        let notes = app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Notes'")).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout:20)); notes.tap()

        // A new page, its title typed in the page, then the slash menu and a table.
        app.buttons["newPage"].tap(); Thread.sleep(forTimeInterval:2)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout:10))
        let title = app.textFields["draftTitle"]; XCTAssertTrue(title.waitForExistence(timeout:5),"A new page asks for its title")
        title.tap(); title.typeText("Fresh Page\n"); Thread.sleep(forTimeInterval:1)
        app.typeText("First line\n/todo"); Thread.sleep(forTimeInterval:1)
        try shot("01-slash-menu")
        app.typeText("\n"); app.typeText("Buy paper\n\n| Name | Count |\n| --- | --- |\n| Ink | 2 |")
        eventually("The new page is saved under its title",timeout:12) { exists("Notes/Fresh Page.md") }
        eventually("The slash menu inserted a task") { text("Notes/Fresh Page.md").contains("- [ ] Buy paper") }
        XCTAssertTrue(text("Notes/Fresh Page.md").contains("| Ink | 2 |"),"The table is written")
        let draftNew = app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'tab-'")).count
        try shot("02-new-page-table")
        // ⌘N from the hardware keyboard, while the editor has the focus.
        app.typeKey("n",modifierFlags:.command); Thread.sleep(forTimeInterval:2)
        XCTAssertTrue(app.textFields["draftTitle"].waitForExistence(timeout:5) && draftNew >= 1,"⌘N opens a new page")
        try shot("02b-command-n")

        // Tabs: a second page opens in its own tab, and both come back after a relaunch.
        row("Notes/Same.md").tap(); Thread.sleep(forTimeInterval:2)
        XCTAssertTrue(app.descendants(matching:.any)["tab-Fresh Page"].exists && app.descendants(matching:.any)["tab-Same"].exists,"Two tabs")
        try shot("03-tabs")
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["tab-Same"].waitForExistence(timeout:15) && app.descendants(matching:.any)["tab-Fresh Page"].exists,"Tabs are restored on relaunch")

        // Split view: another page beside the open one.
        if !row("Notes/Fresh Page.md").waitForExistence(timeout:5) { app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Notes'")).firstMatch.tap() }
        menu("Notes/Fresh Page.md","Open in split view")
        XCTAssertTrue(app.buttons["closeSplit"].waitForExistence(timeout:8),"Split view opens")
        try shot("04-split")
        app.buttons["closeSplit"].tap()

        // Rename, move, trash and restore.
        menu("Notes/Fresh Page.md","Rename")
        let field = app.textFields["renameField"]; XCTAssertTrue(field.waitForExistence(timeout:5))
        field.tap(); field.press(forDuration:1.0); if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue + "Renamed Page"); app.buttons["renameDone"].tap()
        eventually("Rename") { exists("Notes/Renamed Page.md") && !exists("Notes/Fresh Page.md") }
        menu("Notes/Renamed Page.md","Move to")
        app.buttons["moveTo-Archive"].tap()
        eventually("Move") { exists("Archive/Renamed Page.md") }
        app.buttons["modules"].tap(); Thread.sleep(forTimeInterval:1)
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Archive'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1)
        menu("Archive/Renamed Page.md","Move to Trash")
        eventually("To the trash") { !exists("Archive/Renamed Page.md") }
        app.buttons["Trash"].tap()
        let restore = app.buttons["restore-Renamed Page.md"]; XCTAssertTrue(restore.waitForExistence(timeout:5))
        try shot("05-trash")
        restore.tap()
        eventually("Restore") { exists("Archive/Renamed Page.md") }

        // A new module, and a Card Index over a folder, with a card starred.
        app.buttons["modules"].tap(); Thread.sleep(forTimeInterval:1)
        app.buttons["New module"].tap()
        let name = app.textFields["moduleName"]; XCTAssertTrue(name.waitForExistence(timeout:5)); name.tap(); name.typeText("Ideas")
        try shot("06-new-module")
        app.buttons["moduleDone"].tap()
        eventually("The module's folder is made") { exists("Ideas") && text(".acdian-modules.json").contains("Ideas") }
        app.buttons["modules"].tap(); Thread.sleep(forTimeInterval:1)
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Notes'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1)
        menu("Notes/Nested","Add Card Index")
        app.buttons["cardIndexDone"].tap()
        eventually("The Card Index is made") { exists("Notes/Nested.acdian") }
        Thread.sleep(forTimeInterval:2)
        app.buttons["cardGroup"].tap(); if app.buttons["All"].waitForExistence(timeout:3) { app.buttons["All"].tap() }
        let star = app.buttons["star-Deep Note"]
        if star.waitForExistence(timeout:8) { star.tap(); eventually("Starring is saved") { text("Notes/Nested.acdian").contains("Deep Note") } }
        else { XCTFail("The card shows a star") }
        try shot("07-card-index")

        // Settings and the Attachments grid.
        app.buttons["Settings"].tap(); Thread.sleep(forTimeInterval:1)
        try shot("08-settings")
        app.buttons["OK"].firstMatch.tap(); Thread.sleep(forTimeInterval:1)
        app.buttons["modules"].tap(); Thread.sleep(forTimeInterval:1)
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Attachments'")).firstMatch.tap(); Thread.sleep(forTimeInterval:3)
        try shot("09-attachments")
    }
}
