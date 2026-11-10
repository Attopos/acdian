import XCTest

/// Comment layouts, the picture menu, the split divider and module reordering on iPad.
final class RoundTwoTour: XCTestCase {
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
    private func text(_ path: String) -> String { (try? root()).flatMap { try? String(contentsOf:$0.appendingPathComponent(path),encoding:.utf8) } ?? "" }
    /// On a real device the Mac reads the app's files after the run instead.
    private var canReadFiles: Bool { ProcessInfo.processInfo.environment["ACDIAN_DOCS"] != nil }
    func testRoundTwo() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        // English labels whatever the device language, so the test can find its buttons.
        app.launchArguments = ["--local-pages","-appLanguage","en","-AppleLanguages","(en)"]
        app.launch()

        // Modules reorder by dragging in the sidebar.
        let notes = app.buttons["module-Notes"], archive = app.buttons["module-Archive"]
        XCTAssertTrue(notes.waitForExistence(timeout:20))
        notes.press(forDuration:1.2,thenDragTo:archive); Thread.sleep(forTimeInterval:2)
        let order = canReadFiles ? text(".acdian-modules.json") : "\"Notes\" \"Archive\""
        if let a = order.range(of:"\"Notes\""), let b = order.range(of:"\"Archive\"") { XCTAssertTrue(a.lowerBound < b.lowerBound,"Notes was moved before Archive") } else { XCTFail("The module order is saved: \(order.prefix(200))") }
        try shot("r1-modules-reordered")

        // A comment, then its layout with the sidebar shown, hidden, and in portrait.
        let welcome = app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Welcome'")).firstMatch
        if !welcome.isHittable { app.navigationBars.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar'")).firstMatch.tap(); Thread.sleep(forTimeInterval:1.5) }
        welcome.tap()
        let web = app.webViews.firstMatch; XCTAssertTrue(web.waitForExistence(timeout:10)); Thread.sleep(forTimeInterval:2)
        web.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55)).tap(); Thread.sleep(forTimeInterval:1)
        XCTAssertTrue(app.buttons["format-comment"].waitForExistence(timeout:5)); app.buttons["format-comment"].tap(); Thread.sleep(forTimeInterval:1)
        // Return goes separately: on a device, a Return typed in the same burst can
        // arrive before the last letters and send the comment early.
        app.typeText("Where does this comment show?"); Thread.sleep(forTimeInterval:1); app.typeText("\n"); Thread.sleep(forTimeInterval:1)
        if app.buttons["hideKeyboard"].exists { app.buttons["hideKeyboard"].tap() }
        try shot("r2-comment-with-sidebar")
        let toggle = app.buttons["ToggleSidebar"].exists ? app.buttons["ToggleSidebar"] : app.navigationBars.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar'")).firstMatch
        if toggle.exists { toggle.tap(); Thread.sleep(forTimeInterval:1.5) }
        try shot("r3-comment-wide")
        XCUIDevice.shared.orientation = .portrait; Thread.sleep(forTimeInterval:2)
        try shot("r4-comment-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft; Thread.sleep(forTimeInterval:2)

        // Holding a picture opens its menu.
        let image = web.images.firstMatch
        for _ in 0..<8 where !(image.exists && image.isHittable) { web.swipeUp() }
        if image.waitForExistence(timeout:5) {
            image.press(forDuration:1.2)
            XCTAssertTrue(app.buttons["Copy Image"].waitForExistence(timeout:5),"The picture menu opens")
            try shot("r5-image-menu")
            app.buttons["Copy Image"].tap()
        } else { XCTFail("A picture is on the page") }

        // Split view: drag the divider, then swap the sides.
        if toggle.exists { toggle.tap(); Thread.sleep(forTimeInterval:1.5) }
        app.buttons["module-Notes"].tap(); Thread.sleep(forTimeInterval:1)
        let same = app.buttons["row-Notes/Same.md"]; XCTAssertTrue(same.waitForExistence(timeout:5))
        same.press(forDuration:1.2); app.buttons["Open in split view"].tap(); Thread.sleep(forTimeInterval:2)
        let divider = app.descendants(matching:.any)["splitDivider"]; XCTAssertTrue(divider.waitForExistence(timeout:5))
        // The sidebar floats over the page in this width; a tap outside it would only close it.
        if same.exists && same.isHittable && toggle.exists { toggle.tap(); Thread.sleep(forTimeInterval:1.5) }
        try shot("r6a-split")
        let before = divider.frame.midX
        let grip = divider.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        grip.press(forDuration:0.3,thenDragTo:grip.withOffset(CGVector(dx:-200,dy:0)))
        Thread.sleep(forTimeInterval:1)
        XCTAssertLessThan(divider.frame.midX,before - 100,"The divider moves")
        app.buttons["swapSplit"].tap(); Thread.sleep(forTimeInterval:1)
        try shot("r6b-split-swapped")
    }
}
