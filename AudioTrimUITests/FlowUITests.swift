import XCTest

final class FlowUITests: XCTestCase {
    private enum StoreLanguage: String, CaseIterable {
        case english = "en", simplified = "zh-Hans", traditional = "zh-Hant"

        var locale: String {
            switch self {
            case .english: return "en_US"
            case .simplified: return "zh_CN"
            case .traditional: return "zh_TW"
            }
        }
    }

    private var app: XCUIApplication!
    private var sandbox = UUID()

    override func setUp() {
        continueAfterFailure = false
        sandbox = UUID()
        app = XCUIApplication()
    }

    private func launch(_ flags: [String] = [], language: StoreLanguage = .simplified,
                        reset: Bool = true, token: String? = nil) {
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))",
                               "-AppleLocale", language.locale] + (reset ? ["-reset"] : []) + flags
        app.launchEnvironment["AUDIOTRIM_TEST_SANDBOX"] = sandbox.uuidString
        app.launchEnvironment["AUDIOTRIM_SELECTION"] = token
        app.launch()
    }

    private func button(_ id: String) -> XCUIElement { app.buttons[id].firstMatch }

    private func tap(_ id: String) {
        let element = button(id)
        XCTAssertTrue(element.waitForExistence(timeout: 15), id)
        for _ in 0..<4 {
            if element.isHittable { break }
            if let view = app.scrollViews.allElementsBoundByIndex.last { view.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, id)
        element.tap()
    }

    private func firstButton(withPrefix prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func shot(_ name: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = ProcessInfo.processInfo.environment["SHOTS_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }

    private func openDraft() {
        let draft = firstButton(withPrefix: "home.draft.")
        XCTAssertTrue(draft.waitForExistence(timeout: 12))
        draft.tap()
        XCTAssertTrue(app.staticTexts["editor.title"].waitForExistence(timeout: 12))
    }

    func testColdStartAndRecord() {
        launch(language: .english)
        XCTAssertTrue(button("home.import").waitForExistence(timeout: 12))
        XCTAssertTrue(button("home.video").exists)
        XCTAssertFalse(app.staticTexts["paywall.title"].exists)
        tap("home.record")
        XCTAssertTrue(app.staticTexts["record.timer"].waitForExistence(timeout: 8))
        tap("record.stop")
        XCTAssertTrue(app.staticTexts["editor.title"].waitForExistence(timeout: 15))
        tap("editor.export")
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 20))
    }

    func testDeniedMicrophoneLeavesFileImportAvailable() {
        launch(["-mic-denied"], language: .english)
        tap("home.record")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(button("home.import").isHittable)
        XCTAssertTrue(button("home.video").isHittable)
    }

    func testOpenFilePresetUndoTimeAndPersistence() {
        launch(["-open-fixture"])
        let value = app.staticTexts["editor.duration"]
        XCTAssertTrue(value.waitForExistence(timeout: 15))
        XCTAssertEqual(value.label, "48.20")
        tap("editor.preset.both")
        XCTAssertEqual(value.label, "46.20")
        tap("editor.undo")
        XCTAssertEqual(value.label, "48.20")
        tap("editor.time")
        let start = app.textFields["time.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        if let text = start.value as? String { start.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count)) }
        start.typeText("2")
        tap("time.apply")
        XCTAssertEqual(value.label, "46.20")
        tap("editor.home")
        app.terminate()
        launch(reset: false)
        openDraft()
        XCTAssertEqual(value.label, "46.20")
    }

    func testWaveHandleAndPreview() {
        launch(["-open-fixture"], language: .english)
        let start = app.staticTexts["editor.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let thumb = app.descendants(matching: .any)["wave.start"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 8))
        let origin = thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 58, dy: 0)))
        XCTAssertNotEqual(start.label, "00:00.00")
        tap("editor.preview")
        XCTAssertTrue(button("editor.preview").exists)
        tap("editor.undo")
        XCTAssertEqual(start.label, "00:00.00")
    }

    func testExpiredCanExportAndReadWAVHistory() {
        launch(["-open-fixture"])
        XCTAssertTrue(app.staticTexts["editor.title"].waitForExistence(timeout: 15))
        tap("editor.format")
        tap("format.wav")
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 20))
        tap("result.close")
        tap("editor.home")
        app.terminate()
        launch(["-expired"], reset: false)
        openDraft()
        tap("editor.split")
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 8))
        XCTAssertFalse(button("paywall.trial").exists)
        tap("paywall.close")
        tap("editor.more")
        tap("editor.history")
        let wav = firstButton(withPrefix: "history.file.")
        XCTAssertTrue(wav.waitForExistence(timeout: 8))
        wav.tap()
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["result.saved"].label.contains("WAV"))
        tap("result.close")
        tap("editor.export")
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["result.saved"].label.contains("M4A"))
    }

    func testSplitAndBatch() {
        launch(["-open-fixture"])
        XCTAssertTrue(app.staticTexts["editor.title"].waitForExistence(timeout: 15))
        tap("editor.split")
        tap("split.add")
        tap("split.export")
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 25))
        tap("result.close")
        tap("editor.home")
        tap("home.batch")
        let item = firstButton(withPrefix: "batch.draft.")
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        item.tap()
        tap("batch.export")
        XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 25))
    }

    func testSelectionRoundTripCreatesIndependentDraft() {
        launch(["-fixture", "-code"], token: "fixture")
        XCTAssertTrue(app.staticTexts["code.range"].waitForExistence(timeout: 18))
        tap("code.apply")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "46.20")
        tap("editor.home")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.draft.")).count, 2)
    }

    func testBadSelectionCodeShowsError() {
        launch(["-fixture", "-code"], language: .english, token: "Instructions\nAudioTrim AC1:invalid")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15))
        app.alerts.firstMatch.buttons["OK"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "48.20")
    }

    func testStoreScreenshots() throws {
        for language in StoreLanguage.allCases {
            launch(["-fixture", "-store-shots"], language: language)
            let prefix = "store-\(language.rawValue)-"
            XCTAssertTrue(firstButton(withPrefix: "home.draft.").waitForExistence(timeout: 15))
            try shot(prefix + "02-home")
            openDraft()
            tap("editor.preset.both")
            XCTAssertEqual(app.staticTexts["editor.duration"].label, "46.20")
            try shot(prefix + "01-quick-trim")
            tap("wave.zoomIn")
            XCTAssertTrue(app.staticTexts["wave.level"].waitForExistence(timeout: 8))
            try shot(prefix + "03-waveform")
            tap("editor.export")
            XCTAssertTrue(app.staticTexts["result.saved"].waitForExistence(timeout: 25))
            try shot(prefix + "04-export")
            tap("result.card")
            XCTAssertTrue(app.staticTexts["card.title"].waitForExistence(timeout: 12))
            try shot(prefix + "05-share-card")
            app.terminate()
        }
    }

    func testPaidScreenshot() throws {
        launch(["-paid-mode", "-paywall"])
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(button("paywall.buy").exists)
        XCTAssertTrue(button("paywall.trial").exists)
        try shot("paid-01-paywall")
    }
}
