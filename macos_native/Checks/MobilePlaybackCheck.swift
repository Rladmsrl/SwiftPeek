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
