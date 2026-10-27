import AppKit
import Foundation
import SimpleLiveKit

private struct FakePayload: LiveSitePayload {}
private struct NoChat: LiveDanmakuClient {
    var events: AsyncStream<DanmakuEvent> { AsyncStream { $0.finish() } }
    func start() async {}
    func stop() async {}
}

private actor FakeSite: LiveSite {
    nonisolated let id = "fake"
    nonisolated let name = "fake"
    var fail = false
    var lineIDs = ["a", "b"]
    var statuses: [Bool?] = [true]
    var briefCalls = 0
    var urlCalls = 0
    var hold = false
    var pending: [CheckedContinuation<LivePlayURL, Error>] = []
    func configure(fail: Bool = false, lines: [String] = ["a", "b"], statuses: [Bool?] = [true], hold: Bool = false) {
        self.fail = fail; lineIDs = lines; self.statuses = statuses; self.hold = hold
        briefCalls = 0; urlCalls = 0
    }
    func pendingCount() -> Int { pending.count }
    func finishPending(at index: Int, line: String) { pending.remove(at: index).resume(returning: stream([line])) }
    nonisolated func stream(_ ids: [String]) -> LivePlayURL {
        LivePlayURL(urls: ids.map { "https://\($0).invalid/signed.flv" }, lineIDs: ids)
    }
    nonisolated func makeDanmakuClient(payload: (any LiveSitePayload)?) throws -> any LiveDanmakuClient { NoChat() }
    func roomDetail(roomID: String) async throws -> LiveRoomDetail {
        LiveRoomDetail(roomID: roomID, title: "fixture", cover: "", userName: "fixture", userAvatar: "", online: 0,
                       isLiving: true, payload: FakePayload(), url: "")
    }
    func roomBrief(roomID: String) async throws -> LiveRoomBrief {
        let state = statuses[min(briefCalls, statuses.count - 1)]
        briefCalls += 1
        guard let state else { throw LiveCoreError("unknown status") }
        return LiveRoomBrief(roomID: roomID, title: "", cover: "", userName: "", userAvatar: "", online: 0, isLiving: state, isRecord: false)
    }
    func playQualities(detail: LiveRoomDetail) async throws -> [LivePlayQuality] {
        ["高", "中", "低"].enumerated().map { LivePlayQuality(quality: $0.element, payload: FakePayload(), sort: $0.offset) }
    }
    func playURL(detail: LiveRoomDetail, quality: LivePlayQuality) async throws -> LivePlayURL {
        urlCalls += 1
        if fail { throw LiveCoreError("fixture stream error") }
        if hold { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return stream(lineIDs)
    }
    func categories() async throws -> [LiveCategory] { [] }
    func recommendRooms(page: Int) async throws -> LiveCategoryResult { .init(hasMore: false, items: []) }
    func categoryRooms(_ category: LiveSubCategory, page: Int) async throws -> LiveCategoryResult { .init(hasMore: false, items: []) }
    func searchRooms(_ keyword: String, page: Int) async throws -> LiveSearchRoomResult { .init(hasMore: false, items: []) }
    func searchAnchors(_ keyword: String, page: Int) async throws -> LiveSearchAnchorResult { .init(hasMore: false, items: []) }
    func liveStatus(roomID: String) async throws -> Bool { true }
}


@MainActor
private final class FakeMobilePlayer: MobilePlaybackEngine {
    var isActive = false
    var isMuted = false
    var volume = 1.0
    var onPrepareStream: (@MainActor (Bool) async throws -> PreparedPlaybackStream)?
    var onCommitStream: (@MainActor (PreparedPlaybackStream) -> Void)?
    var diagnosticFields: [String: String] { ["fixture": "mobile"] }
    var starts = 0
    var stops = 0
    var failures = 0
    func start(url: String, headers: [String: String]?) { starts += 1; isActive = true }
    func stop() { stops += 1; isActive = false }
    func abortReconnect(reason: String) { failures += 1; isActive = false }
}

@main
struct MobilePlaybackCheck {
    @MainActor static func main() async throws {
        let site = FakeSite()
        let player = FakeMobilePlayer()
        let session = MobileRoomPlaybackSession(roomID: "fixture", player: player, site: site, backgroundGrace: .milliseconds(10))
        session.activate(autoPlay: false)
        await session.waitUntilLoaded()
        precondition(player.starts == 0 && player.onPrepareStream != nil && player.onCommitStream != nil)
        session.chooseQuality(2)
        await session.waitUntilLoaded()
        session.switchLine()
        precondition(session.store.selectedQualityIndex == 2 && session.store.playbackSelection.lineID == "b" && player.starts == 0)
        session.play()
        await session.waitUntilLoaded()
        precondition(player.starts == 1 && session.store.selectedQualityIndex == 2 && session.store.playbackSelection.lineID == "b")
        print("PASS: autoplay-off remains paused; manual playback retains quality/CDN and enables buffered mode")

        let prepare = player.onPrepareStream!
        let commit = player.onCommitStream!
        let prior = session.store.currentStreamURL
        await site.configure(lines: ["fresh-b", "fresh-a"])
        let candidate = try await prepare(false)
        precondition(session.store.currentStreamURL == prior && player.starts == 1)
        commit(candidate)
        precondition(session.store.currentStreamURL == candidate.url && player.starts == 1 && player.stops == 0)
        session.activate(autoPlay: true)
        await session.waitUntilLoaded()
        precondition(player.starts == 1)
        print("PASS: background handoff and tab reappearance do not restart/flush the player")

        session.stopPlayback()
        session.activate(autoPlay: true)
        precondition(!player.isActive && player.starts == 1)
        session.play()
        await session.waitUntilLoaded()
        precondition(player.starts == 2)
        session.setBackgroundAudio(false)
        session.setSceneBackgrounded(true)
        try await settle()
        precondition(!player.isActive)
        session.setPictureInPictureActive(false) // repeated background notifications preserve resume intent
        try await settle()
        session.setSceneBackgrounded(false)
        await session.waitUntilLoaded()
        precondition(player.isActive && player.starts == 3)
        print("PASS: manual stop survives tab changes; foreground resumes a background-suspended stream")

        session.setPictureInPictureActive(true)
        session.setSceneBackgrounded(true)
        let beforePiP = player.stops
        try await settle()
        precondition(player.isActive && player.stops == beforePiP)
        session.setPictureInPictureActive(false)
        try await settle()
        precondition(!player.isActive)
        session.setSceneBackgrounded(false)
        await session.waitUntilLoaded()
        session.setBackgroundAudio(true)
        session.setSceneBackgrounded(true)
        try await settle()
        precondition(player.isActive)
        print("PASS: system PiP and background audio keep playing; exiting PiP respects background-off")

        session.setSceneBackgrounded(false)
        session.stopPlayback()
        await site.configure(hold: true)
        session.play()
        try await waitForPending(site)
        session.stopPlayback()
        await site.finishPending(at: 0, line: "cancelled")
        try await settle()
        precondition(!player.isActive)
        print("PASS: stopping while credentials refresh prevents a late restart")

        await site.configure()
        session.play()
        await session.waitUntilLoaded()
        let beforeClose = session.store.currentStreamURL
        session.close()
        commit(candidate)
        precondition(session.store.currentStreamURL == beforeClose && player.onPrepareStream == nil && player.onCommitStream == nil && !player.isActive)
        do { _ = try await prepare(false); fatalError("Closed session allowed preparation") }
        catch is CancellationError {}
        print("PASS: room exit detaches callbacks and rejects stale prepare/commit")

        let pausedSite = FakeSite()
        await pausedSite.configure(hold: true)
        let pausedPlayer = FakeMobilePlayer()
        let pausedSession = MobileRoomPlaybackSession(roomID: "fixture", player: pausedPlayer, site: pausedSite, backgroundGrace: .milliseconds(10))
        pausedSession.activate(autoPlay: false)
        try await waitForPending(pausedSite)
        pausedSession.setBackgroundAudio(false)
        pausedSession.setSceneBackgrounded(true)
        try await settle()
        await pausedSite.finishPending(at: 0, line: "metadata-only")
        await pausedSession.waitUntilLoaded()
        pausedSession.setSceneBackgrounded(false)
        precondition(pausedSession.store.currentStreamURL != nil && pausedPlayer.starts == 0 && !pausedSession.isWorking)
        pausedSession.close()
        print("PASS: backgrounding an autoplay-off room does not strand its metadata load")
        try await checkMultiWatch()
        try await checkMultiWatchDanmaku()
    }

    @MainActor private static func checkMultiWatchDanmaku() async throws {
        var limiter = DanmakuDeliveryLimiter(messagesPerSecond: 3)
        precondition(limiter.accept(at: 0))
        for _ in 0..<1000 { precondition(!limiter.accept(at: 0.1), "Burst escaped the admission limit") }
        precondition(limiter.accept(at: 0.34))
        precondition(limiter.accept(at: 0.68))
        precondition(!limiter.accept(at: 0.99))
        precondition(limiter.accept(at: 100))
        precondition(!limiter.accept(at: 100), "Idle time accumulated a catch-up burst")
        var unrestricted = DanmakuDeliveryLimiter()
        for _ in 0..<1000 { precondition(unrestricted.accept(at: 0), "Primary-only delivery was throttled") }

        let settings = AppSettings()
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.multiWatchDanmakuMode = .selected
        settings.data.danmakuVisibleByDefault = true
        settings.data.pictureInPictureDanmaku = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(storageDirectory: directory)
        let multi = MultiWatchSession(makePlayer: { FakeMobilePlayer() }, site: FakeSite())
        multi.configure(settings: settings, library: library)
        for id in ["1", "2", "3", "4"] { multi.add(id: id, title: id) }
        let identities = multi.rooms.map { ObjectIdentifier($0.playback.player) }
        func delivering() -> [String] { multi.rooms.filter { $0.playback.store.danmakuDeliveryEnabled }.map(\.id) }
        precondition(delivering() == ["1"])
        precondition(multi.rooms.allSatisfy { $0.playback.store.danmakuMessagesPerSecond == nil })
        let regular = multi.danmakuSettings(for: multi.rooms[0])
        multi.danmakuMode = .all
        precondition(delivering() == ["1", "2", "3", "4"])
        precondition(multi.rooms.allSatisfy { $0.playback.store.danmakuMessagesPerSecond == 3 })
        precondition(multi.danmakuSettings(for: multi.rooms[0]).areaRatio < regular.areaRatio)
        precondition(multi.danmakuSettings(for: multi.rooms[0]).gap > regular.gap)
        multi.setDanmakuVisible(false, for: multi.rooms[1])
        precondition(delivering() == ["1", "3", "4"])
        multi.setDanmakuVisible(true, for: multi.rooms[1])
        multi.focused = true
        precondition(delivering() == ["1"], "Hidden tiles kept publishing chat")
        multi.focused = false
        multi.setConstrained(true)
        precondition(delivering() == ["1"], "All-room mode did not shed secondary overlays under pressure")
        multi.setConstrained(false)
        precondition(delivering().count == 4)
        multi.setPiP("2")
        multi.setBackgrounded(true)
        precondition(delivering() == ["2"])
        multi.danmakuMode = .off
        precondition(delivering().isEmpty)
        multi.setBackgrounded(false)
        multi.setPiP(nil)
        precondition(delivering().isEmpty)
        multi.danmakuMode = .selected
        multi.select("3")
        multi.setConstrained(true)
        precondition(delivering() == ["3"])
        precondition(multi.rooms.allSatisfy { $0.playback.store.danmakuMessagesPerSecond == nil })
        precondition(multi.danmakuSettings(for: multi.rooms[2]) == regular, "Primary-only density changed")
        precondition(multi.rooms.map { ObjectIdentifier($0.playback.player) } == identities)
        multi.setConstrained(false)
        multi.finish()

        let original = MobileRoomPlaybackSession(roomID: "original", player: FakeMobilePlayer(), site: FakeSite())
        original.open(settings: settings, library: library, autoPlay: true)
        await original.waitUntilLoaded()
        multi.begin(from: original, id: "original", title: "Original")
        multi.danmakuMode = .all
        multi.setDanmakuVisible(false, for: multi.rooms[0])
        let previousStore = original.store
        original.store.detail = nil
        original.play()
        await original.waitUntilLoaded()
        precondition(original.store !== previousStore)
        precondition(!original.store.isDanmakuVisible && !original.store.danmakuDeliveryEnabled,
                     "Metadata retry lost the per-room danmaku opt-out")
        precondition(original.store.danmakuMessagesPerSecond == 3)
        multi.finish()
        precondition(original.store.danmakuMessagesPerSecond == nil && original.store.danmakuDeliveryEnabled,
                     "Returning to single-room playback retained multi-watch throttling")
        precondition(original.store.danmakuVisibilityOverride == nil)
        original.close()
        let persisted = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings.data))
        precondition(persisted.multiWatchDanmakuMode == .all)
        let legacy = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        precondition(legacy.multiWatchDanmakuMode == .selected)
        print("PASS: three danmaku modes, per-room opt-out, bounded admission without bursts, pressure/focus/background and unthrottled single-room return")
    }

    @MainActor private static func checkMultiWatch() async throws {
        let fixtureSite = FakeSite()
        let settings = AppSettings()
        let originalSettings = settings.data
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(storageDirectory: directory)
        let multi = MultiWatchSession(makePlayer: { FakeMobilePlayer() }, site: fixtureSite)
        multi.configure(settings: settings, library: library)
        for id in ["1", "2", "3", "4"] { precondition(multi.add(id: id, title: id)) }
        precondition(!multi.add(id: "5", title: "fifth"))
        precondition(multi.rooms.allSatisfy { $0.playback.player.starts == 0 }, "Selection must not start streams")
        let identities = multi.rooms.map { ObjectIdentifier($0.playback.player) }
        precondition(multi.add(id: "1", title: "duplicate") && multi.rooms.count == 4)
        multi.start()
        try await Task.sleep(for: .milliseconds(1400))
        for room in multi.rooms { await room.playback.waitUntilLoaded() }
        precondition(multi.rooms.allSatisfy { $0.playback.player.isActive })
        precondition(multi.rooms.filter { !$0.playback.player.isMuted }.map(\.id) == ["1"])
        multi.toggleSound("1")
        precondition(multi.rooms.allSatisfy { $0.playback.player.isMuted })
        multi.select("1")
        precondition(multi.rooms.allSatisfy { $0.playback.player.isMuted }, "Selecting the current tile undid its quick mute")
        multi.toggleSound("4")
        precondition(multi.selectedID == "1" && multi.rooms.filter { !$0.playback.player.isMuted }.map(\.id) == ["4"])
        multi.toggleSound("1")
        precondition(multi.rooms[0].playback.store.selectedQualityIndex == 1)
        precondition(multi.rooms.dropFirst().allSatisfy { $0.playback.store.selectedQualityIndex == 2 })
        let starts = multi.rooms.map { $0.playback.player.starts }
        multi.layoutMode = .stage
        multi.move("1", to: "4")
        multi.move("1", to: "4")
        precondition(multi.rooms.map { ObjectIdentifier($0.playback.player) } == identities)
        precondition(multi.rooms.map { $0.playback.player.starts } == starts)
        multi.select("2")
        precondition(multi.rooms.filter { !$0.playback.player.isMuted }.map(\.id) == ["2"])
        multi.audioLocked = true
        multi.select("3")
        precondition(multi.audibleID == "2" && multi.selectedID == "3")
        multi.muted = true
        precondition(multi.rooms.allSatisfy { $0.playback.player.isMuted })
        multi.audioLocked = false
        multi.select("3")
        multi.muted = false
        multi.focused = true
        precondition(multi.rooms.filter { $0.playback.player.isActive }.map(\.id) == ["3"])
        multi.focused = false
        for room in multi.rooms { await room.playback.waitUntilLoaded() }
        precondition(multi.rooms.allSatisfy { $0.playback.player.isActive })
        multi.rooms[0].playback.stopPlayback()
        multi.focused = true
        multi.focused = false
        for room in multi.rooms { await room.playback.waitUntilLoaded() }
        precondition(!multi.rooms[0].playback.player.isActive, "User-paused tile resumed on layout change")
        multi.setPiP("3")
        multi.setBackgrounded(true)
        precondition(multi.rooms.filter { $0.playback.player.isActive }.map(\.id) == ["3"])
        multi.setBackgrounded(false)
        multi.setPiP(nil)
        for room in multi.rooms { await room.playback.waitUntilLoaded() }
        multi.remove("3")
        precondition(multi.rooms.count == 3 && multi.audibleID == multi.selectedID)
        precondition(multi.rooms.filter { !$0.playback.player.isMuted }.count == 1)
        let players = multi.rooms.map { $0.playback.player }
        multi.finish()
        try await Task.sleep(for: .milliseconds(1000))
        precondition(players.allSatisfy { !$0.isActive && $0.onPrepareStream == nil })
        precondition(settings.data == originalSettings, "Multi-watch overwrote global quality/volume preferences")
        print("PASS: four independent streams, exclusive audio, lock/mute, stable layouts, focus/background suspension and cleanup")

        let originalPlayer = FakeMobilePlayer()
        let original = MobileRoomPlaybackSession(roomID: "original", player: originalPlayer, site: fixtureSite)
        original.open(settings: settings, library: library, autoPlay: true)
        await original.waitUntilLoaded()
        let originalStarts = originalPlayer.starts
        let originalStops = originalPlayer.stops
        let originalQuality = original.store.selectedQualityIndex
        multi.begin(from: original, id: "original", title: "Original")
        precondition(multi.owns(original) && multi.rooms[0].playback === original)
        multi.add(id: "extra", title: "Extra")
        try await Task.sleep(for: .milliseconds(1100))
        await multi.rooms[1].playback.waitUntilLoaded()
        precondition(originalPlayer.isActive && originalPlayer.starts == originalStarts && originalPlayer.stops == originalStops,
                     "Adding a room interrupted the existing stream")
        precondition(original.store.selectedQualityIndex == originalQuality, "Entry changed original quality")
        let extra = multi.rooms[1].playback.player
        multi.select("extra")
        precondition(originalPlayer.isMuted && !extra.isMuted)
        multi.finish()
        precondition(!extra.isActive && originalPlayer.isActive && !multi.owns(original))
        precondition(!originalPlayer.isMuted, "Returning from another audible room left the original muted")
        precondition(originalPlayer.starts == originalStarts && originalPlayer.stops == originalStops,
                     "Returning to the original player reconnected it")
        precondition(original.store.remembersQuality && original.store.qualityPreferenceOverride == nil)

        multi.begin(from: original, id: "original", title: "Original")
        multi.toggleAllSound()
        multi.finish()
        precondition(originalPlayer.isMuted, "Returning from multi-watch undid an explicit mute")
        originalPlayer.isMuted = false

        original.stopPlayback()
        multi.begin(from: original, id: "original", title: "Original")
        multi.finish()
        precondition(!originalPlayer.isActive, "Entry resumed a manually paused original room")
        original.play()
        await original.waitUntilLoaded()
        multi.begin(from: original, id: "original", title: "Original")
        multi.add(id: "extra", title: "Extra")
        multi.remove("original")
        multi.finish()
        precondition(!originalPlayer.isActive, "Removing the original room resumed it on return")
        original.play()
        await original.waitUntilLoaded()
        multi.begin(from: original, id: "original", title: "Original")
        multi.finish(stopOrigin: true)
        precondition(!originalPlayer.isActive, "End-all left the original stream running")
        original.close()
        print("PASS: player entry/return reuse the original session without reconnects; pause/remove/end-all intent survives")

        // Cancel an initial pending stream before its response arrives, then resume.
        let slowSite = FakeSite()
        await slowSite.configure(hold: true)
        let slow = MobileRoomPlaybackSession(roomID: "slow", player: FakeMobilePlayer(), site: slowSite)
        slow.activate(autoPlay: true)
        try await waitForPending(slowSite)
        slow.setSuspended(true)
        await slowSite.finishPending(at: 0, line: "stale")
        try await settle()
        precondition(!slow.player.isActive)
        await slowSite.configure()
        slow.setSuspended(false)
        await slow.waitUntilLoaded()
        precondition(slow.player.isActive, "Suspended initial load did not resume")
        slow.close()
        print("PASS: suspended in-flight loads cannot start late and resume with fresh credentials")

        let backgroundSite = FakeSite()
        await backgroundSite.configure(hold: true)
        let backgroundLoad = MobileRoomPlaybackSession(roomID: "background-load", player: FakeMobilePlayer(), site: backgroundSite, backgroundGrace: .milliseconds(100))
        backgroundLoad.activate(autoPlay: true)
        try await waitForPending(backgroundSite)
        backgroundLoad.setBackgroundAudio(false)
        backgroundLoad.setSceneBackgrounded(true)
        await backgroundSite.finishPending(at: 0, line: "loaded-in-background")
        await backgroundLoad.waitUntilLoaded()
        try await Task.sleep(for: .milliseconds(150))
        precondition(!backgroundLoad.player.isActive)
        await backgroundSite.configure()
        backgroundLoad.setSceneBackgrounded(false)
        await backgroundLoad.waitUntilLoaded()
        precondition(backgroundLoad.player.isActive, "Fast background load lost playback intent")
        backgroundLoad.close()
        print("PASS: initial load finishing inside the PiP grace period resumes on foreground")

        var activations = 0, deactivations = 0
        var sampleRates: [Double] = []
        let audio = PlaybackAudioSession(activate: { activations += 1 }, deactivate: { deactivations += 1 }, setSampleRate: { sampleRates.append($0) })
        let a = UUID(), b = UUID()
        audio.acquire(a); audio.acquire(a)
        audio.preferSampleRate(44100, owner: a)
        audio.acquire(b)
        audio.preferSampleRate(48000, owner: b)
        precondition(sampleRates == [44100], "Second stream changed shared hardware sample rate")
        audio.release(a); audio.release(a); audio.release(UUID())
        precondition(activations == 1 && deactivations == 0 && audio.owners.count == 1)
        audio.release(b)
        precondition(deactivations == 1 && audio.owners.isEmpty)
        print("PASS: releasing one player's audio lease cannot deactivate another player's session")
    }
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }
    private static func waitForPending(_ site: FakeSite) async throws {
        for _ in 0..<1000 {
            if await site.pendingCount() == 1 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("No fixture request")
    }
}
