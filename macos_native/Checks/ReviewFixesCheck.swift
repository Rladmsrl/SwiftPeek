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

@main
struct ReviewFixesCheck {
    @MainActor static func main() async throws {
        let site = FakeSite()
        let store = RoomStore(roomID: "fixture", site: site)
        await store.load()
        store.switchToNextLine()
        precondition(store.currentLineIndex == 1)
        let oldURL = store.currentStreamURL
        await site.configure(fail: true)
        let changed = await store.selectQuality(2)
        precondition(!changed && store.selectedQualityIndex == 0 && store.currentLineIndex == 1 && store.currentStreamURL == oldURL)
        print("PASS: failed quality request preserves selection, CDN and URL")

        await site.configure()
        let selected = await store.selectQuality(2)
        precondition(selected)
        await site.configure(lines: ["b", "a"])
        _ = await store.refreshStreamURL(rotateLine: false)
        precondition(store.selectedQualityIndex == 2 && store.playbackSelection.lineID == "b" && store.currentLineIndex == 0)
        let replacement = RoomStore(roomID: "fixture", site: site)
        await replacement.load(selection: store.playbackSelection)
        precondition(replacement.selectedQualityIndex == 2 && replacement.playbackSelection.lineID == "b")
        print("PASS: resume and full reload preserve quality/CDN across reordered signed URLs")
        let beforePrepare = store.currentStreamURL
        let beforeLine = store.currentLineIndex
        await site.configure(lines: ["new-b", "new-a"])
        let prepared = try await store.prepareReplacementStream(rotateLine: true)
        precondition(store.currentStreamURL == beforePrepare && store.currentLineIndex == beforeLine)
        store.commitReplacementStream(prepared)
        precondition(store.currentStreamURL == prepared.url && store.selectedQualityIndex == 2)
        print("PASS: background URL preparation leaves active selection untouched until explicit commit")

        await site.configure(statuses: [nil])
        let unknown = await store.refreshStreamURL()
        precondition(unknown != nil && store.offlineNotice == nil)
        await site.configure(statuses: [false, true])
        let transient = await store.refreshStreamURL()
        precondition(transient != nil && store.offlineNotice == nil)
        await site.configure(statuses: [false, nil])
        let uncertainConfirmation = await store.refreshStreamURL()
        precondition(uncertainConfirmation != nil && store.offlineNotice == nil)
        await site.configure(statuses: [false, false])
        let offline = await store.refreshStreamURL()
        let calls = await site.urlCalls
        precondition(offline == nil && store.offlineNotice != nil && calls == 0)
        print("PASS: unknown/transient offline recover; two valid offline responses stop fetching")

        await site.configure(hold: true)
        let earlier = Task { await store.selectQuality(0) }
        try await waitForPending(site, count: 1)
        let later = Task { await store.selectQuality(1) }
        try await waitForPending(site, count: 2)
        await site.finishPending(at: 1, line: "new")
        let newerChanged = await later.value
        await site.finishPending(at: 0, line: "old")
        let olderChanged = await earlier.value
        precondition(newerChanged && !olderChanged && store.selectedQualityIndex == 1 && store.playbackSelection.lineID == "new")
        let cancelled = Task { await store.selectQuality(0) }
        try await waitForPending(site, count: 1)
        cancelled.cancel()
        await site.finishPending(at: 0, line: "cancelled")
        let cancelledChanged = await cancelled.value
        precondition(!cancelledChanged && store.selectedQualityIndex == 1)
        let stopped = Task { await store.selectQuality(0) }
        try await waitForPending(site, count: 1)
        await store.stop()
        await site.finishPending(at: 0, line: "stopped")
        let stoppedChanged = await stopped.value
        precondition(!stoppedChanged && store.selectedQualityIndex == 1)
        print("PASS: stale/cancelled/stopped quality responses cannot overwrite the latest selection")

        let view = DanmakuHostView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        view.wantsLayer = true
        view.layout()
        view.emit(text: "existing message", color: .white)
        precondition(!(view.layer?.sublayers ?? []).isEmpty)
        var settings = DanmakuSettings()
        settings.speed = 200
        view.apply(settings)
        precondition((view.layer?.sublayers ?? []).isEmpty)
        view.emit(text: "new message", color: .white)
        precondition(!(view.layer?.sublayers ?? []).isEmpty)
        view.frame.size.width = 400
        view.layout()
        precondition((view.layer?.sublayers ?? []).isEmpty)
        print("PASS: speed/size changes remove old animations before freeing tracks")
        await store.stop()
        await replacement.stop()
    }
    private static func waitForPending(_ site: FakeSite, count: Int) async throws {
        for _ in 0..<1000 {
            if await site.pendingCount() == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Fixture request was not issued")
    }
}
