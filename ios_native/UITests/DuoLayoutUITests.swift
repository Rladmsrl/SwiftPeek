import XCTest
import UIKit
import AVKit

@_silgen_name("DuoSetHingeAngle")
private func setSimulatorHingeAngle(_ angle: Double) -> Double

/// Exercises phone/tablet layout and real Duo simulator hinge transitions.
/// Duo tests verify sensor readback; unsupported targets are explicitly skipped.
/// Device Hub controls physical orientation, independently of XCTest's enum.
final class DuoLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["DUO_PRESERVE_POSE"] != "1" {
            XCUIDevice.shared.orientation = .portrait
        }
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    }

    override func tearDownWithError() throws {
        app.terminate()
        if ProcessInfo.processInfo.environment["DUO_PRESERVE_POSE"] != "1" {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func capture(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = name + "-display-" + String(index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let geometry = XCTAttachment(string: "deviceOrientation=\(XCUIDevice.shared.orientation.rawValue); windows=\(app.windows.allElementsBoundByIndex.map(\.frame))")
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func exitFullscreen(_ name: String) {
        let exit = app.buttons["退出全屏"].firstMatch
        let restored = app.buttons["全屏"].firstMatch
        for _ in 0..<2 {
            if !exit.isHittable {
                let window = app.windows.allElementsBoundByIndex
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                XCTAssertNotNil(window)
                window?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(exit.waitForExistence(timeout: 3))
            exit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: restored)
            if XCTWaiter.wait(for: [visible], timeout: 2) == .completed {
                capture(name)
                return
            }
            capture(name + "-retry")
        }
        XCTFail("Fullscreen exit did not restore the visible fullscreen entry control")
    }

    /// Requests an XCTest orientation. On Duo this may update only the reported
    /// enum; genuine orientation coverage requires Device Hub plus display/bounds evidence.
    private func rotate(_ orientation: UIDeviceOrientation, name: String) {
        XCUIDevice.shared.orientation = orientation
        // Duo active-display dimensions are pose dependent; orientation does not
        // imply width > height. Record geometry after the system transition.
        // The accessibility window changes before the simulator display finishes rotating.
        // A run-loop wait lets the system animation settle before recording visual evidence.
        let settled = expectation(description: "Rotation animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        capture(name)
    }

    func testRecommendationListRotatesAndKeepsSelectedTab() {
        app.launch()
        XCTAssertTrue(app.navigationBars["斗鱼推荐"].waitForExistence(timeout: 20))
        capture("list-portrait")
        rotate(.landscapeLeft, name: "list-landscape")
        XCTAssertTrue(app.navigationBars["斗鱼推荐"].exists)
        rotate(.portrait, name: "list-portrait-restored")
        XCTAssertTrue(app.navigationBars["斗鱼推荐"].exists)
    }

    func testLiveRoomRotationAndFullscreenExit() {
        app.launchArguments += ["-launchRoom", "9999", "-keepControls", "1"]
        app.launch()
        let panel = app.staticTexts["实时弹幕"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        capture("room-portrait")
        app.buttons["全屏"].firstMatch.tap()
        let portraitExit = app.buttons["退出全屏"].firstMatch
        XCTAssertTrue(portraitExit.waitForExistence(timeout: 5))
        capture("room-fullscreen-from-portrait")
        exitFullscreen("room-portrait-fullscreen-exited")
        XCTAssertTrue(panel.isHittable)
        rotate(.landscapeLeft, name: "room-landscape")
        XCTAssertTrue(panel.exists, "Rotation must retain the companion panel")
        let fullscreen = app.buttons["全屏"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10))
        fullscreen.tap()
        let exit = app.buttons["退出全屏"].firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        capture("room-fullscreen")
        exitFullscreen("room-fullscreen-exited")
        XCTAssertTrue(panel.isHittable)
        rotate(.portrait, name: "room-portrait-restored")
        XCTAssertTrue(panel.exists)
    }

    private func verifyFullscreenButtonRotatesToLandscape(launchArgument: String, companion: String) {
        app.launchArguments += [launchArgument, "1", "-keepControls", "1"]
        app.launch()
        let panel = app.staticTexts[companion]
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.frame.height > window.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        let initialSize = window.frame.size
        for cycle in 1...2 {
            app.buttons["全屏"].firstMatch.tap()
            let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                window.frame.width > window.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed,
                           "Fullscreen must rotate the actual window without a device rotation command")
            XCTAssertTrue(app.buttons["退出全屏"].firstMatch.waitForExistence(timeout: 5))
            capture(launchArgument + "-button-landscape-\(cycle)")
            exitFullscreen(launchArgument + "-button-exited-\(cycle)")
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                window.frame.size == initialSize && panel.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                           "Exit must restore the entry layout without manually rotating the device")
        }
        for direction in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            rotate(direction, name: launchArgument + "-entry-landscape-\(direction.rawValue)")
            XCTAssertGreaterThan(window.frame.width, window.frame.height)
            app.buttons["全屏"].firstMatch.tap()
            XCTAssertTrue(app.buttons["退出全屏"].firstMatch.waitForExistence(timeout: 5))
            exitFullscreen(launchArgument + "-landscape-exited-\(direction.rawValue)")
            XCTAssertGreaterThan(window.frame.width, window.frame.height,
                                 "A landscape entry must not be forced to portrait on exit")
            XCTAssertTrue(panel.isHittable)
        }
    }

    func testLiveFullscreenButtonRotatesToLandscape() {
        verifyFullscreenButtonRotatesToLandscape(launchArgument: "-launchRoomLayout", companion: "实时弹幕")
    }

    func testReplayFullscreenButtonRotatesToLandscape() {
        verifyFullscreenButtonRotatesToLandscape(launchArgument: "-launchReplayLayout", companion: "选择一段录像")
    }

    func testReplayListNavigationSurvivesRotation() {
        app.launchArguments += ["-launchRoom", "9999", "-keepControls", "1"]
        app.launch()
        let replay = app.buttons["查看主播的直播录像"].firstMatch
        XCTAssertTrue(replay.waitForExistence(timeout: 20))
        replay.tap()
        XCTAssertTrue(app.navigationBars["录像"].waitForExistence(timeout: 10))
        capture("replay-list-portrait")
        rotate(.landscapeLeft, name: "replay-list-landscape")
        XCTAssertTrue(app.navigationBars["录像"].exists)
        rotate(.portrait, name: "replay-list-portrait-restored")
        XCTAssertTrue(app.navigationBars["录像"].exists)
    }

    func testReplayLayoutKeepsPanelSelectionAndExitsFullscreen() {
        app.launchArguments += ["-launchReplayLayout", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["选择一段录像"].waitForExistence(timeout: 20))
        let chapters = app.segmentedControls.buttons["章节"]
        XCTAssertTrue(chapters.exists)
        chapters.tap()
        XCTAssertTrue(app.staticTexts["暂无章节"].waitForExistence(timeout: 5))
        capture("replay-layout-portrait")
        rotate(.landscapeLeft, name: "replay-layout-landscape")
        XCTAssertTrue(app.staticTexts["暂无章节"].exists, "Rotation must preserve the selected replay panel")
        XCTAssertTrue(chapters.isHittable)
        XCTAssertGreaterThan(chapters.frame.height, 0)
        XCTAssertGreaterThan(app.staticTexts["暂无章节"].frame.height, 0)
        let fullscreen = app.buttons["全屏"].firstMatch
        XCTAssertTrue(fullscreen.exists)
        fullscreen.tap()
        let exit = app.buttons["退出全屏"].firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        capture("replay-layout-fullscreen")
        exitFullscreen("replay-layout-fullscreen-exited")
        XCTAssertTrue(app.staticTexts["暂无章节"].isHittable)
        rotate(.portrait, name: "replay-layout-portrait-restored")
        XCTAssertTrue(app.staticTexts["暂无章节"].exists)
    }



    /// XCTest can restore a scene's previous orientation on launch. The host
    /// presses Device Hub Rotate Right only after this foreground handshake.
    private func calibrateOuterPose() throws {
        guard let text = ProcessInfo.processInfo.environment["DUO_EXPECT_OUTER_WIDTH"], let expected = Double(text) else { return }
        func width() -> Double {
            Double(app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width * $0.height < $1.width * $1.height }?.width ?? 0)
        }
        for _ in 0..<3 {
            if abs(width() - expected) < 1 { return }
            let before = width()
            print("DUO_POSE_ROTATE_READY")
            let changed = NSPredicate { _, _ in abs(width() - before) > 1 }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 10)
        }
        capture("pose-calibration-failed")
        XCTAssertEqual(width(), expected, accuracy: 1, "Device Hub foreground rotation did not reach the required outer width")
    }

    private func fold(_ angle: Double, name: String) throws {
        let measured = setSimulatorHingeAngle(angle)
        guard measured.isFinite else { throw XCTSkip("Duo hinge sensor/injection unavailable on this simulator") }
        XCTAssertEqual(measured, angle, accuracy: 1)
        let settled = expectation(description: "Fold display settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 4)
        let sensor = XCTAttachment(string: "requested=\(angle); measured=\(measured)")
        sensor.name = name + "-hinge-readback"
        sensor.lifetime = .keepAlways
        add(sensor)
        capture(name)
        if angle == 0, let text = ProcessInfo.processInfo.environment["DUO_EXPECT_OUTER_WIDTH"], let expected = Double(text) {
            let width = app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width * $0.height < $1.width * $1.height }?.width ?? 0
            XCTAssertEqual(Double(width), expected, accuracy: 1, "Physical Duo pose differs from the matrix label")
        }
    }

    func testDuoReplayPanelSurvivesFolding() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        app.launchArguments += ["-launchReplayLayout", "1"]
        app.launch()
        XCTAssertTrue(app.segmentedControls.buttons["章节"].waitForExistence(timeout: 20))
        app.segmentedControls.buttons["章节"].tap()
        for (angle, name) in [(0.0, "outer"), (180.0, "inner"), (90.0, "half"), (0.0, "outer-restored")] {
            try fold(angle, name: "fold-replay-" + name)
            XCTAssertTrue(app.staticTexts["暂无章节"].isHittable)
            XCTAssertTrue(app.segmentedControls.buttons["章节"].isSelected)
        }
    }


    func testDuoRootPagesAcrossFolds() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        let pages = [("recommend", "斗鱼推荐"), ("category", "分类"), ("follow", "关注"), ("mine", "我的"), ("search", "搜索"), ("settings", "设置")]
        for (key, title) in pages {
            app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launchArguments += key == "settings" ? ["-launchRoute", "settings"] : ["-launchTab", key]
            app.launch()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 20))
            try calibrateOuterPose()
            for (angle, pose) in [(0.0, "outer"), (180.0, "inner"), (90.0, "half")] {
                try fold(angle, name: "page-" + key + "-" + pose)
                XCTAssertTrue(app.navigationBars[title].exists)
            }
            XCTAssertTrue(setSimulatorHingeAngle(0).isFinite)
            app.terminate()
        }
    }

    func testDuoLiveSessionAcrossFolds() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        app.launchArguments += ["-launchRoom", "9999", "-keepControls", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["实时弹幕"].waitForExistence(timeout: 20))
        try calibrateOuterPose()
        for (angle, pose) in [(0.0, "outer"), (180.0, "inner"), (90.0, "half"), (0.0, "outer-restored")] {
            try fold(angle, name: "live-session-" + pose)
            XCTAssertTrue(app.staticTexts["实时弹幕"].isHittable)
            XCTAssertTrue(app.buttons["全屏"].firstMatch.isHittable)
        }
    }

    func testDuoPublicReplayAcrossFolds() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        guard let hash = ProcessInfo.processInfo.environment["DUO_REPLAY_HASH"], !hash.isEmpty else {
            throw XCTSkip("Supply DUO_REPLAY_HASH through TEST_RUNNER_DUO_REPLAY_HASH for a currently available public replay")
        }
        app.launchArguments += ["-launchReplayHash", hash, "-keepControls", "1"]
        app.launch()
        let pause = app.buttons["暂停"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 40), "Public replay must start before testing continuity")
        try calibrateOuterPose()
        let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9:]+ / [0-9:]+")).firstMatch
        XCTAssertTrue(timer.exists)
        func seconds(_ value: String) -> Int {
            value.components(separatedBy: " / ")[0].split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        }
        let start = seconds(timer.label)
        for (angle, pose) in [(0.0, "outer"), (180.0, "inner"), (90.0, "half"), (0.0, "outer-restored")] {
            try fold(angle, name: "public-replay-" + pose)
            XCTAssertTrue(app.buttons["暂停"].firstMatch.exists)
            XCTAssertTrue(app.segmentedControls.buttons["章节"].isHittable)
            let progress = XCTAttachment(string: timer.label)
            progress.name = "public-replay-" + pose + "-progress"
            progress.lifetime = .keepAlways
            add(progress)
        }
        XCTAssertGreaterThan(seconds(timer.label), start, "Replay must advance through the fold sequence")
    }


    func testDuoNavigationAcrossFolds() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        app.launch()
        XCTAssertTrue(app.navigationBars["斗鱼推荐"].waitForExistence(timeout: 20))
        try calibrateOuterPose()
        for (angle, pose) in [(0.0, "outer"), (180.0, "inner"), (90.0, "half")] {
            try fold(angle, name: "navigation-" + pose)
            for (tab, title) in [("分类", "分类"), ("关注", "关注"), ("我的", "我的")] {
                app.buttons[tab].firstMatch.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            }
            app.buttons["设置"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
            capture("navigation-settings-" + pose)
            let back = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            app.buttons["搜索"].firstMatch.tap()
            let scope = app.segmentedControls.buttons["主播"]
            XCTAssertTrue(scope.waitForExistence(timeout: 5))
            scope.tap()
            XCTAssertTrue(scope.isSelected)
            capture("navigation-search-" + pose)
            app.buttons["推荐"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["斗鱼推荐"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(setSimulatorHingeAngle(0).isFinite)
    }

    func testDuoRecommendationScrollAndOpenAfterFold() throws {
        guard setSimulatorHingeAngle(0).isFinite else { throw XCTSkip("Duo hinge unavailable") }
        app.launch()
        XCTAssertTrue(app.navigationBars["斗鱼推荐"].waitForExistence(timeout: 20))
        try calibrateOuterPose()
        try fold(90, name: "grid-half-initial")
        let scroll = app.scrollViews.firstMatch
        let loaded = NSPredicate { [weak self] _, _ in
            self?.app.scrollViews.buttons.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.height > 80 } == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 20), .completed)
        capture("grid-half-before-scroll")
        scroll.swipeUp()
        capture("grid-half-after-scroll")
        try fold(180, name: "grid-unfolded-after-scroll")
        try fold(90, name: "grid-refolded-after-scroll")
        let viewport = app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        guard let card = app.scrollViews.buttons.allElementsBoundByIndex.first(where: {
            let frame = $0.frame
            return $0.isHittable && frame.height > 80 && viewport.contains(frame)
                && frame.minY > viewport.minY + 100 && frame.maxY < viewport.maxY - 80
        }) else {
            XCTFail("No complete recommendation remains tappable after folding")
            return
        }
        let originalFrame = card.frame
        let cardLabel = ([card.label] + card.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " | ")
        let settled = expectation(description: "Recommendation position remains stable")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(card.frame.midY, originalFrame.midY, accuracy: 2)
        XCTAssertEqual(card.frame.height, originalFrame.height, accuracy: 2)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["实时弹幕"].waitForExistence(timeout: 15))
        let titleMatches = NSPredicate { [weak self] _, _ in
            self?.app.navigationBars.staticTexts.allElementsBoundByIndex.contains { !$0.label.isEmpty && cardLabel.contains($0.label) } == true
        }
        let match = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: titleMatches, object: nil)], timeout: 10)
        let destination = XCTAttachment(string: "card=\(cardLabel)\ncardFrame=\(originalFrame)\nviewport=\(viewport)\nroomTitles=\(app.navigationBars.staticTexts.allElementsBoundByIndex.map(\.label))")
        destination.name = "grid-selected-destination"
        destination.lifetime = .keepAlways
        add(destination)
        capture("grid-card-opened")
        XCTAssertEqual(match, .completed, "Opened room must match the selected recommendation")
        XCTAssertTrue(setSimulatorHingeAngle(0).isFinite)
    }


    func testDuoPoseProbe() throws {
        app.launchArguments += ["-launchReplayLayout", "1"]
        app.launch()
        XCTAssertTrue(app.segmentedControls.buttons["章节"].waitForExistence(timeout: 20))
        capture("pose-before-hinge")
        try fold(0, name: "pose-after-closed")
        try fold(180, name: "pose-after-open")
        try fold(90, name: "pose-after-half")
        XCTAssertTrue(setSimulatorHingeAngle(0).isFinite)
    }


    func testSystemPictureInPictureCapability() throws {
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        let capability = XCTAttachment(string: "systemPiPSupported=\(supported)")
        capability.name = "system-pip-capability"
        capability.lifetime = .keepAlways
        add(capability)
        guard supported else { throw XCTSkip("System PiP is unsupported on this simulator; inline checks do not validate system PiP or background FPS") }
    }

    private func verifyInlineDanmakuSettings(_ name: String) {
        if app.buttons["显示弹幕"].exists { app.buttons["显示弹幕"].tap() }
        XCTAssertTrue(app.buttons["隐藏弹幕"].waitForExistence(timeout: 5))
        app.buttons["弹幕设置"].tap()
        let pipDanmaku = app.switches["画中画显示弹幕"].firstMatch
        XCTAssertTrue(pipDanmaku.waitForExistence(timeout: 5))
        let original = pipDanmaku.value as? String
        if original != "1" { pipDanmaku.tap() }
        XCTAssertEqual(pipDanmaku.value as? String, "1")
        capture(name + "-danmaku-settings")
        app.buttons["关闭弹幕设置"].tap()
        XCTAssertTrue(app.buttons["隐藏弹幕"].waitForExistence(timeout: 5))
        app.buttons["弹幕设置"].tap()
        XCTAssertEqual(pipDanmaku.value as? String, "1", "The setting must persist after dismissing the panel")
        if original != "1" { pipDanmaku.tap() }
        app.buttons["关闭弹幕设置"].tap()
        app.buttons["隐藏弹幕"].tap()
        XCTAssertTrue(app.buttons["显示弹幕"].waitForExistence(timeout: 5))
        app.buttons["显示弹幕"].tap()
        XCTAssertTrue(app.buttons["隐藏弹幕"].waitForExistence(timeout: 5))
        capture(name + "-inline-restored")
    }

    func testLiveInlineDanmakuSettingsRegression() {
        app.launchArguments += ["-launchRoom", "9999", "-keepControls", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["实时弹幕"].waitForExistence(timeout: 25))
        verifyInlineDanmakuSettings("live")
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            XCTAssertFalse(app.buttons["画中画"].exists)
        }
    }

    func testReplayInlineDanmakuSettingsRegression() throws {
        guard let hash = ProcessInfo.processInfo.environment["DUO_REPLAY_HASH"], !hash.isEmpty else {
            throw XCTSkip("Provide a currently available public replay through the test runner environment")
        }
        app.launchArguments += ["-launchReplayHash", hash, "-keepControls", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 40))
        let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9:]+ / [0-9:]+")).firstMatch
        XCTAssertTrue(timer.exists)
        let initial = timer.label
        verifyInlineDanmakuSettings("replay")
        XCTAssertTrue(app.buttons["暂停"].firstMatch.exists)
        XCTAssertNotEqual(timer.label, initial, "Inline replay should advance while changing danmaku settings")
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            XCTAssertFalse(app.buttons["画中画"].exists)
        }
    }

}
