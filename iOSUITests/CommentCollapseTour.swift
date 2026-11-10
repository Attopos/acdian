import XCTest

/// The iPad's comment sheet can be put away and brought back, the choice is kept
/// across a relaunch, and it stays put away in split view. Runs on a fixture copy.
final class CommentCollapseTour: XCTestCase {
    private let app = XCUIApplication()
    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval:1.5)
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func showSidebar() {
        if !app.buttons["module-Notes"].isHittable { app.navigationBars.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1.5) }
    }
    func testCollapse() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        app.launchArguments = ["--local-pages","-appLanguage","en","-AppleLanguages","(en)"]
        app.launch()
        if app.buttons["modules"].waitForExistence(timeout:10) { app.buttons["modules"].tap() }
        let welcome = app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Welcome'")).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout:20)); if !welcome.isHittable { showSidebar() }; welcome.tap()
        let web = app.webViews.firstMatch; XCTAssertTrue(web.waitForExistence(timeout:10)); Thread.sleep(forTimeInterval:2)
        web.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap(); Thread.sleep(forTimeInterval:1)
        app.buttons["format-comment"].tap(); Thread.sleep(forTimeInterval:1)
        app.typeText("A comment to put away"); Thread.sleep(forTimeInterval:1); app.typeText("\n"); Thread.sleep(forTimeInterval:1)
        if app.buttons["hideKeyboard"].exists { app.buttons["hideKeyboard"].tap() }
        shot("c1-sheet-open")
        let hide = web.buttons["Hide comments"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout:5),"The sheet has a hide button"); hide.tap()
        let show = web.buttons["Show comments"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout:5),"A button brings the comments back")
        shot("c2-sheet-hidden")
        app.terminate(); app.launch(); Thread.sleep(forTimeInterval:4)
        XCTAssertTrue(app.webViews.firstMatch.buttons["Show comments"].waitForExistence(timeout:15),"Still put away after a relaunch")
        shot("c3-after-relaunch")
        // Split view: the left page keeps its comments put away.
        showSidebar()
        app.buttons["module-Notes"].tap(); Thread.sleep(forTimeInterval:1)
        let same = app.buttons["row-Notes/Same.md"]; XCTAssertTrue(same.waitForExistence(timeout:5))
        same.press(forDuration:1.2); app.buttons["Open in split view"].tap(); Thread.sleep(forTimeInterval:2)
        if same.isHittable { app.navigationBars.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1.5) }
        shot("c4-split-hidden")
        app.webViews.firstMatch.buttons["Show comments"].firstMatch.tap()
        shot("c5-split-shown")
        app.webViews.firstMatch.buttons["Hide comments"].firstMatch.tap()
    }
}
