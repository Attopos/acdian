import XCTest

/// Edits a copy of Fixtures/Vault on an iPad: typing, Chinese input, a merge with
/// an outside change, a comment, a picture and the save on going to the background.
/// Set TEST_RUNNER_ACDIAN_SHOTS and TEST_RUNNER_ACDIAN_DOCS (the simulator's app-data folder).
final class EditorTour: XCTestCase {
    private let app = XCUIApplication()
    private var log: [String] = []
    private func shot(_ name: String) throws {
        Thread.sleep(forTimeInterval:1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot:screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["ACDIAN_SHOTS"] else { return }
        let url = URL(fileURLWithPath:dir); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        try screenshot.pngRepresentation.write(to:url.appendingPathComponent(name + ".png"))
    }
    private func page() throws -> URL {
        let apps = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["ACDIAN_DOCS"]))
        return try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:apps,includingPropertiesForKeys:nil).map { $0.appendingPathComponent("Documents/Welcome.md") }.first { FileManager.default.fileExists(atPath:$0.path) })
    }
    private func disk() throws -> String { try String(contentsOf:try page(),encoding:.utf8) }
    private func eventually(_ message: String, timeout: Double = 10, _ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if (try? condition()) == true { return }; Thread.sleep(forTimeInterval:0.3) }
        XCTFail(message)
    }
    func testEditing() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Editing is iPad-only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--local-pages"]
        app.launch()
        let welcome = app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Welcome'")).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout:20))
        welcome.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout:15)); Thread.sleep(forTimeInterval:3)
        try shot("01-page")

        // Typing, saved by autosave.
        web.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55)).tap(); Thread.sleep(forTimeInterval:1)
        app.typeText("Typed on the iPad. ")
        try eventually("Typing is saved") { try disk().contains("Typed on the iPad. ") }
        try shot("02-typing")

        // Chinese text, then pinyin through the Chinese keyboard when it is installed.
        app.typeText("中文输入测试")
        try eventually("Chinese text is saved") { try disk().contains("中文输入测试") }
        let globe = app.buttons["Next keyboard"]
        if globe.exists {
            globe.tap(); Thread.sleep(forTimeInterval:1)
            // The first switch shows a one-time tip about switching keyboards.
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); Thread.sleep(forTimeInterval:1) }
            let pinyin = { self.app.keyboards.buttons["abc"].exists || self.app.keyboards.keys["abc"].exists }
            // The pinyin keyboard can be in Roman mode; its "拼音" key switches it to pinyin.
            let switchKey = app.keyboards.keys["Switch from Roman keys"]
            // Its mode is remembered between runs: test it by typing one letter and looking for candidates.
            func composes() -> Bool {
                log.append("keyboard frame \(app.keyboards.firstMatch.frame)")
                app.keyboards.keys["z"].tap(); Thread.sleep(forTimeInterval:0.8)
                let candidates = app.descendants(matching:.any).matching(NSPredicate(format:"label == '在'")).count > 0
                app.keyboards.keys["delete"].tap(); Thread.sleep(forTimeInterval:0.5)
                return candidates
            }
            if !composes(), switchKey.exists { switchKey.tap(); Thread.sleep(forTimeInterval:1) }
            log.append("pinyin mode: \(composes())")
            // typeText would bypass the input method, so the keys are pressed one by one.
            for letter in "zhongwen" { app.keyboards.keys[String(letter)].tap(); Thread.sleep(forTimeInterval:0.15) }
            Thread.sleep(forTimeInterval:1)
            try shot("03a-composing")
            // Space takes the first candidate, which for "zhongwen" is 中文.
            // The candidate bar sits above the keys; its first word, 中文, is tapped by position.
            let first = app.keyboards.firstMatch.frame
            app.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0)).withOffset(CGVector(dx:first.minX + 390,dy:first.minY - 21)).tap(); Thread.sleep(forTimeInterval:1)
            try eventually("The composed word is saved") { try disk().contains("测试中文") }
            log.append("pinyin: composed and committed: \((try? disk().contains("测试中文")) ?? false)")
            try shot("03-pinyin")
            // Back to Roman keys, so the plain typing that follows is not composed.
            let roman = app.keyboards.keys.matching(NSPredicate(format:"label BEGINSWITH 'Switch to Roman' OR label == 'abc'")).firstMatch
            if roman.exists { roman.tap(); Thread.sleep(forTimeInterval:0.6) }
        } else { log.append("pinyin: no keyboard switch key") }

        // An outside change to another line merges with the next edit.
        var text = try disk()
        text = text.replacingOccurrences(of:"## 常用 Markdown",with:"## 常用 Markdown（另一台设备改的）")
        try text.write(to:try page(),atomically:true,encoding:.utf8)
        app.typeText("After the outside edit. ")
        try eventually("Both edits are kept") { let now = try disk(); return now.contains("另一台设备改的") && now.contains("After the outside edit. ") }
        try shot("04-merged")

        // Going to the background saves what was just typed.
        web.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55)).tap(); Thread.sleep(forTimeInterval:0.5)
        app.typeText("Last words before leaving.")
        XCUIDevice.shared.press(.home)
        try eventually("The background save wrote the page") { try disk().contains("Last words before leaving.") }
        app.activate(); Thread.sleep(forTimeInterval:2)

        // A comment through the bar above the keyboard.
        web.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55)).tap(); Thread.sleep(forTimeInterval:1)
        let comment = app.buttons["format-comment"]
        if comment.waitForExistence(timeout:3) {
            comment.tap(); Thread.sleep(forTimeInterval:1)
            app.typeText("A comment from the iPad\n")
            let sidecar = try page().deletingLastPathComponent().appendingPathComponent(".Welcome.md.comments.json")
            try eventually("The comment is saved beside the page") { FileManager.default.fileExists(atPath:sidecar.path) }
            try shot("05-comment")
        } else { log.append("comment: no format bar (keyboard hidden?)"); XCTFail("The format bar shows above the keyboard") }

        // A picture from Photos goes into Attachments.
        app.buttons["attach"].firstMatch.tap(); Thread.sleep(forTimeInterval:1)
        let images = app.buttons["Images"].exists ? app.buttons["Images"] : app.buttons["图片"]
        if images.exists {
            images.tap(); Thread.sleep(forTimeInterval:3)
            // The picker runs in another process, so its first photo and its done
            // button are tapped by position (landscape 13-inch iPad).
            let origin = XCUIApplication(bundleIdentifier:"com.apple.springboard").coordinate(withNormalizedOffset:CGVector(dx:0,dy:0))
            Thread.sleep(forTimeInterval:3)
            if true {
                origin.withOffset(CGVector(dx:575,dy:459)).tap(); Thread.sleep(forTimeInterval:1)
                origin.withOffset(CGVector(dx:1066,dy:217)).tap(); Thread.sleep(forTimeInterval:2)
                let attachments = try page().deletingLastPathComponent().appendingPathComponent("Attachments")
                try eventually("The picture is copied into Attachments",timeout:15) { try FileManager.default.contentsOfDirectory(atPath:attachments.path).count > 4 }
                try eventually("Its link is in the page") { try disk().contains("![[Attachments/") && disk().components(separatedBy:"![[Attachments/").count > 2 }
                try shot("06-attachment")
            } else { log.append("photos: picker showed no photo") }
        } else { log.append("photos: no Images menu item") }
        let note = XCTAttachment(string:log.joined(separator:"\n")); note.name = "notes"; note.lifetime = .keepAlways; add(note)
    }
}
