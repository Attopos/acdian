import XCTest

/// Read-only look at the real pages on an iPad: modules, one page, one search.
/// It types only into the search field, never into a page.
final class RealPagesIPad: XCTestCase {
    func testRealPages() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let app = XCUIApplication(); app.launchArguments = ["-appLanguage","en"]; app.launch()
        func shot(_ name: String) { Thread.sleep(forTimeInterval:2); let a = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        // The app reopens in the module it was left in.
        if app.buttons["modules"].waitForExistence(timeout:20) { app.buttons["modules"].tap() }
        let cs = app.buttons["module-CS"]
        XCTAssertTrue(cs.waitForExistence(timeout:60),"The CS module is listed")
        for name in ["wandering-wondering","Languages","Teaching","CS","Attachments"] { XCTAssertTrue(app.buttons["module-" + name].exists,"\(name) is listed") }
        shot("p1-modules")
        cs.tap(); Thread.sleep(forTimeInterval:2)
        let page = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'row-CS/' AND identifier ENDSWITH '.md'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout:10),"A CS page is listed"); page.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:10)); Thread.sleep(forTimeInterval:3)
        shot("p2-page")
        // Search covers the open module, as on the Mac. The search field shows once the sidebar list is pulled down; ⌘F does the same with a keyboard.
        let search = app.searchFields.firstMatch
        if !search.exists { app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'row-CS/'")).firstMatch.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText("agents")
        Thread.sleep(forTimeInterval:3)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'row-'")).count > 0,"The search finds pages")
        shot("p3-search")
    }

    /// Trash and Settings sit at the bottom of the sidebar, in both orientations. Read-only.
    func testSidebarBottom() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let app = XCUIApplication(); app.launchArguments = ["-appLanguage","en"]; app.launch()
        func shot(_ name: String) { Thread.sleep(forTimeInterval:2); let a = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        for orientation in [UIDeviceOrientation.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation = orientation; Thread.sleep(forTimeInterval:2)
            let trash = app.buttons["Trash"]
            if !(trash.exists && trash.isHittable) { app.navigationBars.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1.5) }
            XCTAssertTrue(trash.waitForExistence(timeout:20),"Trash is shown")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(trash.frame.minY,window.height * 0.75,"Trash is at the bottom")
            XCTAssertGreaterThan(app.buttons["Settings"].frame.minY,trash.frame.minY,"Settings is below Trash")
            shot(orientation == .portrait ? "s2-portrait" : "s1-landscape")
        }
    }
}
