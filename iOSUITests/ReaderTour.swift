import XCTest

/// Walks the reader over a copy of Fixtures/Vault and saves a screenshot of each
/// screen. Set TEST_RUNNER_ACDIAN_SHOTS and TEST_RUNNER_ACDIAN_DOCS when running.
final class ReaderTour: XCTestCase {
    private let app = XCUIApplication()
    private var shots: URL { URL(fileURLWithPath:ProcessInfo.processInfo.environment["ACDIAN_SHOTS"] ?? NSTemporaryDirectory()) }
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func shot(_ name: String) throws {
        Thread.sleep(forTimeInterval:1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot:screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard ProcessInfo.processInfo.environment["ACDIAN_SHOTS"] != nil else { return }
        try FileManager.default.createDirectory(at:shots,withIntermediateDirectories:true)
        try screenshot.pngRepresentation.write(to:shots.appendingPathComponent(name + ".png"))
    }
    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@",prefix)).firstMatch
    }
    private func open(_ prefix: String) {
        let target = button(prefix)
        XCTAssertTrue(target.waitForExistence(timeout:15),"\(prefix) should be listed")
        target.tap()
    }
    private func back() { app.navigationBars.buttons.element(boundBy:0).tap() }
    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout:3) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout:5))
        field.tap(); field.typeText(text)
    }

    func testTour() throws {
        continueAfterFailure = false
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launchArguments = ["--local-pages"]
        app.launch()
        XCTAssertTrue(button("Notes").waitForExistence(timeout:20))
        try shot("01-launcher")

        open("Notes")
        XCTAssertTrue(button("Words").waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["Ephemeral"].exists,"the Card Index source stays out of the list")
        try shot("02-folder")
        open("Words")
        XCTAssertTrue(button("Ephemeral").waitForExistence(timeout:10))
        try shot("03-card-index")
        let all = app.staticTexts["All"]
        if all.waitForExistence(timeout:3) { all.tap(); try shot("03b-card-index-all"); XCTAssertTrue(button("Zenith").waitForExistence(timeout:5)) }
        if !pad { back() }
        app.navigationBars["Notes"].buttons.firstMatch.tap()

        open("Welcome")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout:15))
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","欢迎使用")).firstMatch.waitForExistence(timeout:15),"the page should render")
        try shot("04-page")

        // Scroll to the picture, then open it.
        let image = web.images.firstMatch
        for _ in 0..<8 where !(image.exists && image.isHittable) { web.swipeUp() }
        XCTAssertTrue(image.waitForExistence(timeout:5))
        try shot("05-page-with-image")
        image.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout:10))
        try shot("06-image-full-screen")
        app.navigationBars["pink-sample.png"].buttons.firstMatch.tap()

        // The open page picks up a change to its file.
        if let apps = ProcessInfo.processInfo.environment["ACDIAN_DOCS"] {
            // ACDIAN_DOCS is the simulator's app-data folder: installing can change the app's own folder name.
            let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:apps),includingPropertiesForKeys:nil)
                .map { $0.appendingPathComponent("Documents/Welcome.md") }.first { FileManager.default.fileExists(atPath:$0.path) })
            var text = try String(contentsOf:file,encoding:.utf8)
            text = text.replacingOccurrences(of:"Markdown 相对路径：",with:"外部修改过的说明")
            try text.write(to:file,atomically:true,encoding:.utf8)
            XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval:1); app.activate()
            XCTAssertTrue(web.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","外部修改过")).firstMatch.waitForExistence(timeout:15),"the open page should refresh")
            try shot("07-page-refreshed")
        }
        if !pad { back() }

        search("Deep")
        XCTAssertTrue(button("Deep Note").waitForExistence(timeout:10),"title search")
        try shot("08-search-title")
        let field = app.searchFields.firstMatch
        field.buttons.firstMatch.tap(); field.tap(); field.typeText("emoji")
        XCTAssertTrue(button("Welcome").waitForExistence(timeout:10),"full-text search")
        try shot("09-search-text")
    }
}
