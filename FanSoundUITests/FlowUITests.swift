import XCTest

final class FlowUITests: XCTestCase {
    private enum Language: String, CaseIterable {
        case simplified = "zh-Hans"
        case english = "en"
        case traditional = "zh-Hant"
        case japanese = "ja"

        var locale: String {
            switch self {
            case .simplified: return "zh_CN"
            case .english: return "en_US"
            case .traditional: return "zh_TW"
            case .japanese: return "ja_JP"
            }
        }
    }

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 8

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testAAAWarmUpSimulator() {
        XCTExpectFailure("云端模拟器首次启动可能超时", strict: false)
        launch()
        app.terminate()
    }

    private func launch(_ args: [String] = [], language: Language = .simplified,
                        reset: Bool = true, code: String? = nil) {
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))",
                               "-AppleLocale", language.locale] + (reset ? ["-reset"] : []) + args
        app.launchEnvironment = code.map { ["FAN_TEST_PRESET_CODE": $0] } ?? [:]
        app.launch()
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = app.buttons.matching(identifier: id)
        for attempt in 0..<5 {
            if let button = matches.allElementsBoundByIndex.first(where: \.isHittable) {
                button.tap()
                return
            }
            if attempt == 0 && matches.count == 0 {
                _ = matches.firstMatch.waitForExistence(timeout: 2)
            } else if attempt < 3 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTFail("Button is not hittable: " + id, file: file, line: line)
    }

    private func assertStatus(_ title: String, timeout: TimeInterval = 8,
                              file: StaticString = #filePath, line: UInt = #line) {
        let status = app.staticTexts["home.status"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", title),
                                                 object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, file: file, line: line)
    }

    private func assertSheetClosed(file: StaticString = #filePath, line: UInt = #line) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.buttons["sheet.done"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: timeout), .completed,
                       "The sheet should close", file: file, line: line)
    }

    private func shot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SHOTS_DIR"] ?? environment["TEST_RUNNER_SHOTS_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    func testFreshIdlePlayStopAndResumeAfterRelaunch() {
        launch()
        assertStatus("待播放")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.buttons["home.play"].label, "播放风扇声")
        tap("home.play")
        assertStatus("轻风播放中")
        tap("home.play")
        assertStatus("待播放")
        launch(reset: false)
        XCTAssertTrue(app.buttons["home.play"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.buttons["home.play"].label, "播放上次设置")
        tap("home.play")
        assertStatus("轻风播放中")
    }

    func testChangeSpeedAndTimerWhilePlayingThenStop() {
        launch(["-paid-mode"])
        tap("sound.medium")
        tap("home.play")
        assertStatus("中风播放中")
        tap("timer.60")
        XCTAssertEqual(app.staticTexts["home.detail"].label, "剩余时间 · 到时渐停")
        tap("sound.high")
        assertStatus("强风播放中")
        XCTAssertEqual(app.staticTexts["home.detail"].label, "剩余时间 · 到时渐停")
        tap("timer.0")
        XCTAssertEqual(app.staticTexts["home.detail"].label, "整夜播放 · 可离线播放")
        tap("timer.more")
        tap("timer.45")
        XCTAssertEqual(app.staticTexts["timer.advancedSelected"].label, "45 分钟")
        tap("home.play")
        assertStatus("待播放")
    }

    func testShortTimerFadesAndExpires() {
        launch(["-short-timer"])
        tap("timer.30")
        tap("home.play")
        assertStatus("正在渐停", timeout: 2)
        assertStatus("本次定时已结束", timeout: 10)
        tap("home.play")
        assertStatus("正在渐停", timeout: 2)
        tap("timer.0")
        assertStatus("轻风播放中")
        tap("home.play")
        assertStatus("待播放")
    }

    func testImportUsesFixtureForMultilineAndInvalidCodeLeavesPreset() {
        let payload = Data(#"{"version":1,"soundID":"medium","timerMinutes":45}"#.utf8)
        let code = "FAN1." + payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        launch(["-paid-mode"], code: "\n" + code + "\n")
        tap("home.settings")
        tap("settings.import")
        tap("import.apply")
        assertSheetClosed()
        let advancedTimer = app.staticTexts["timer.advancedSelected"]
        XCTAssertTrue(advancedTimer.waitForExistence(timeout: timeout), "Trial users should see the imported advanced timer")
        XCTAssertEqual(advancedTimer.label, "45 分钟")
        XCTAssertEqual(app.staticTexts["home.focus"].label, "中风")
        assertStatus("待播放")
        tap("home.play")
        assertStatus("中风播放中")

        launch(["-paid-mode"], reset: false, code: "FAN1.invalid")
        tap("home.settings")
        tap("settings.import")
        tap("import.apply")
        let importError = app.staticTexts["import.error"]
        XCTAssertTrue(importError.waitForExistence(timeout: timeout))
        XCTAssertEqual(importError.label, "无法识别这条风扇设置")
        tap("sheet.done")
        XCTAssertTrue(app.buttons["settings.import"].waitForExistence(timeout: timeout), "Closing import should return to Settings")
        tap("sheet.done")
        assertSheetClosed()
        XCTAssertTrue(advancedTimer.waitForExistence(timeout: timeout))
        XCTAssertEqual(advancedTimer.label, "45 分钟")
        XCTAssertEqual(app.staticTexts["home.focus"].label, "中风")
    }

    func testShareImageAndCodeUseInAppConfirmation() {
        launch()
        tap("timer.60")
        tap("home.share")
        tap("share.image")
        let confirmation = app.staticTexts["share.requested"]
        if !confirmation.isHittable { app.swipeUp() }
        XCTAssertTrue(confirmation.waitForExistence(timeout: timeout))
        tap("share.code")
        let copied = app.staticTexts["share.copied"]
        if !copied.isHittable { app.swipeUp() }
        XCTAssertTrue(copied.waitForExistence(timeout: timeout))
    }

    func testTrialPaywallAndExpiredFallbackCanShareSavedPreset() {
        launch(["-paid-mode"])
        tap("home.settings")
        let entitlement = app.staticTexts["settings.entitlement"]
        XCTAssertTrue(entitlement.waitForExistence(timeout: timeout))
        XCTAssertEqual(entitlement.label, "试用还剩 30 天")
        tap("settings.paywall")
        XCTAssertTrue(app.buttons["paywall.trial"].waitForExistence(timeout: timeout))

        launch(["-expired"])
        XCTAssertTrue(app.staticTexts["home.fallback"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["home.focus"].label, "轻风")
        XCTAssertEqual(app.staticTexts["home.detail"].label, "定时 60 分钟 · 到时渐停")
        tap("home.share")
        XCTAssertTrue(app.staticTexts["强风"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["90 分钟"].exists)
        tap("share.image")
        let confirmation = app.staticTexts["share.requested"]
        if !confirmation.isHittable { app.swipeUp() }
        XCTAssertTrue(confirmation.waitForExistence(timeout: timeout))
        tap("sheet.done")
        tap("home.play")
        assertStatus("轻风播放中")
        tap("home.play")
        tap("sound.medium")
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["paywall.trial"].exists)
    }

    func testFreeBuildHidesPaymentAndAllowsAllGears() {
        launch(["-free-mode"])
        tap("home.settings")
        XCTAssertTrue(app.buttons["settings.import"].exists)
        XCTAssertFalse(app.buttons["settings.paywall"].exists)
        XCTAssertFalse(app.buttons["settings.restore"].exists)
        tap("sheet.done")
        tap("sound.high")
        tap("home.play")
        assertStatus("强风播放中")
    }

    func testMilestoneShareIsOptIn() {
        launch(["-milestone"])
        XCTAssertTrue(app.buttons["milestone.share"].waitForExistence(timeout: timeout))
        tap("milestone.share")
        XCTAssertTrue(app.staticTexts["用了 7 晚的风扇声"].waitForExistence(timeout: timeout))
        tap("share.image")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: timeout))
    }

    func testAccessibilityTextKeepsCoreActionsAndLabelsAvailable() {
        launch(["-large-text"])
        XCTAssertTrue(app.buttons["home.play"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.buttons["sound.low"].label, "轻风")
        XCTAssertEqual(app.buttons["timer.30"].label, "30 分钟")
        tap("timer.30")
        app.swipeDown()
        tap("home.play")
        assertStatus("轻风播放中")
        XCTAssertTrue(app.staticTexts["home.focus"].label.contains("剩余"))
    }

    func testStoreScreenshots() {
        for language in Language.allCases {
            launch(["-shot", "resume"], language: language)
            XCTAssertTrue(app.buttons["home.play"].waitForExistence(timeout: timeout))
            shot("store-\(language.rawValue)-01-resume")
            launch(["-shot", "overnight"], language: language)
            XCTAssertTrue(app.staticTexts["home.status"].waitForExistence(timeout: timeout))
            shot("store-\(language.rawValue)-02-overnight")
            launch(["-shot", "timer"], language: language)
            XCTAssertTrue(app.staticTexts["home.detail"].waitForExistence(timeout: timeout))
            shot("store-\(language.rawValue)-03-timer")
            launch(["-shot", "gears"], language: language)
            XCTAssertTrue(app.buttons["sound.medium"].waitForExistence(timeout: timeout))
            shot("store-\(language.rawValue)-04-speeds")
            launch(["-shot", "share"], language: language)
            XCTAssertTrue(app.buttons["share.image"].waitForExistence(timeout: timeout))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                  object: app.buttons["share.image"])
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
            shot("store-\(language.rawValue)-05-share")
        }
    }

    func testPaidReviewScreenshot() {
        launch(["-paid-mode", "-paywall"])
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["paywall.buy"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        shot("paid-01-paywall")
    }
}
