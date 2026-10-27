import XCTest

@_silgen_name("DuoSetHingeAngle")
private func multiWatchHinge(_ angle: Double) -> Double

final class MultiWatchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-launchTab", "mine"]
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let geometry = XCTAttachment(string: "windows=\(app.windows.allElementsBoundByIndex.map(\.frame))")
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    private func preview(_ count: Int) {
        app.launchArguments += ["-launchMultiWatchLayout", String(count)]
        app.launch()
        XCTAssertTrue(app.buttons["multiwatch.select.layout-1"].waitForExistence(timeout: 15))
    }

    func testFourTilesSelectionFocusRemovalAndLandscape() {
        preview(4)
        for index in 1...4 { XCTAssertTrue(app.buttons["multiwatch.select.layout-\(index)"].isHittable) }
        XCTAssertFalse(app.buttons["multiwatch.add"].isEnabled)
        app.buttons["multiwatch.sound.layout-1"].tap()
        XCTAssertEqual(app.buttons["multiwatch.sound.layout-1"].value as? String, "静音")
        app.buttons["multiwatch.select.layout-1"].tap()
        XCTAssertEqual(app.buttons["multiwatch.sound.layout-1"].value as? String, "静音")
        app.buttons["multiwatch.sound.layout-3"].tap()
        XCTAssertEqual(app.buttons["multiwatch.sound.layout-3"].value as? String, "有声")
        XCTAssertEqual(app.buttons["multiwatch.sound.layout-1"].value as? String, "静音")
        capture("multiwatch-phone-four")
        let second = app.buttons["multiwatch.select.layout-2"]
        second.tap()
        XCTAssertEqual(second.value as? String, "主画面，正在出声")
        app.buttons["multiwatch.mute"].tap()
        XCTAssertEqual(second.value as? String, "主画面，静音")
        app.buttons["multiwatch.mute"].tap()
        app.buttons["multiwatch.focus"].tap()
        XCTAssertTrue(second.isHittable)
        XCTAssertFalse(app.buttons["multiwatch.select.layout-1"].isHittable)
        capture("multiwatch-phone-focused")
        app.buttons["multiwatch.focus"].tap()
        capture("multiwatch-phone-restored")
        XCTAssertEqual(app.buttons["multiwatch.focus"].label, "放大主画面")
        XCTAssertTrue(app.buttons["multiwatch.select.layout-1"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        let settled = expectation(description: "Display rotation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 4)
        XCTAssertTrue(app.buttons["multiwatch.select.layout-4"].waitForExistence(timeout: 5))
        capture("multiwatch-phone-landscape")
        app.buttons["multiwatch.options.layout-4"].tap()
        app.buttons["移除直播间"].tap()
        XCTAssertFalse(app.buttons["multiwatch.select.layout-4"].exists)
        XCTAssertTrue(app.buttons["multiwatch.add"].isEnabled)
        capture("multiwatch-phone-three")
        app.buttons["multiwatch.close"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testOneAndTwoTilesRemainUsableAtLargeTextSize() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        preview(2)
        XCTAssertTrue(app.buttons["multiwatch.options.layout-1"].isHittable)
        XCTAssertTrue(app.buttons["multiwatch.options.layout-2"].isHittable)
        capture("multiwatch-phone-two-large-text")
        app.buttons["multiwatch.options.layout-2"].tap()
        for _ in 0..<4 {
            if app.buttons["移除直播间"].isHittable { break }
            // An upward-opening system menu reverses its presentation order and
            // starts at the bottom; reveal the remaining actions above it.
            app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeDown()
        }
        app.buttons["移除直播间"].tap()
        XCTAssertTrue(app.buttons["multiwatch.select.layout-1"].isHittable)
        capture("multiwatch-phone-one-large-text")
    }

    func testDanmakuModesAndPerRoomSwitch() {
        preview(4)
        let menu = app.buttons["multiwatch.danmaku"]
        for mode in ["所有画面", "关闭", "仅主画面", "所有画面"] {
            menu.tap()
            let choice = app.buttons[mode]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertEqual(menu.value as? String, mode)
            for index in 1...4 { XCTAssertTrue(app.buttons["multiwatch.select.layout-\(index)"].isHittable) }
        }
        capture("multiwatch-danmaku-all")
        app.buttons["multiwatch.options.layout-2"].tap()
        let toggle = app.buttons["本画面弹幕"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        if app.buttons["multiwatch.close"].isHittable { app.buttons["multiwatch.close"].tap() }
        else { app.tap(); app.buttons["multiwatch.close"].tap() }
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        XCTAssertEqual(menu.value as? String, "所有画面")
        menu.tap()
        app.buttons["仅主画面"].tap()
    }

    func testDuoFoldingKeepsAllRoomIdentities() throws {
        guard multiWatchHinge(-1).isFinite else { throw XCTSkip("Duo hinge runtime unavailable") }
        defer { _ = multiWatchHinge(180) }
        preview(4)
        for angle in [180.0, 90.0, 0.0, 180.0] {
            XCTAssertEqual(multiWatchHinge(angle), angle, accuracy: 2)
            for index in 1...4 {
                XCTAssertTrue(app.buttons["multiwatch.select.layout-\(index)"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["multiwatch.options.layout-\(index)"].isHittable)
            }
            capture("multiwatch-duo-\(Int(angle))")
        }
    }

    func testAddFromPlayerWithoutStartPage() {
        app.launchArguments += ["-launchRoomLayout", "1", "-keepControls", "1"]
        app.launch()
        let entry = app.buttons["multiwatch.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["multiwatch.picker.cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["历史"].exists)
        app.segmentedControls.buttons["关注"].tap()
        XCTAssertTrue(app.staticTexts["关注的主播"].exists)
        capture("player-add-history-follow-search")
        app.buttons["multiwatch.picker.cancel"].tap()
        XCTAssertTrue(entry.isHittable)
        XCTAssertFalse(app.buttons["multiwatch.close"].exists)
        entry.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        var id = ""
        for digit in ["1", "2", "3"] {
            id += digit
            search.typeText(digit)
            let row = app.buttons["multiwatch.pick.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.tap()
            capture("player-picked-\(id)")
            XCTAssertEqual(app.buttons["multiwatch.picker.add"].label, "添加（\(id.count)）")
        }
        search.typeText("4")
        XCTAssertFalse(app.buttons["multiwatch.pick.1234"].isEnabled)
        app.buttons["multiwatch.picker.add"].tap()
        XCTAssertTrue(app.buttons["multiwatch.select.layout-origin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["multiwatch.select.123"].exists)
        XCTAssertFalse(app.buttons["multiwatch.start"].exists)
        XCTAssertFalse(app.buttons["multiwatch.add"].isEnabled)
        capture("player-directly-expanded-to-four")
        app.buttons["multiwatch.close"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.isHittable)
    }

    func testNoStandaloneEntryInLibrary() {
        app.launch()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["multiwatch.entry"].exists)
        app.buttons["关注"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["关注"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["multiwatch.entry"].exists)
    }
}
