import Foundation
import SimpleLiveKit

/// 录像弹幕投放、观看进度与热度曲线的离线检查：假接口，不联网、不启动 App。
@main
struct ReplayCheck {
    /// 1200 秒录像，每秒一条弹幕；每个窗口最多 500 条，语义与斗鱼 getBarrageList 一致
    static let all = (0..<1200).map {
        DouyuReplayDanmaku(id: "m\($0)", offset: TimeInterval($0), userName: "u\($0)", text: $0 == 42 ? "屏蔽词" : "第\($0)条")
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [Int] = []
        func add(_ start: Int) { lock.lock(); starts.append(start); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return starts }
    }

    @MainActor static func main() async throws {
        let requests = Requests()
        let feed = ReplayDanmakuFeed { start in
            requests.add(start)
            let items = all.filter { Int($0.offset * 1000) > start }.prefix(500)
            let next = items.count == 500 ? items.last.map { Int($0.offset * 1000) } : nil
            return DouyuReplayDanmakuBatch(items: Array(items), nextStart: next)
        }
        feed.isBlocked = { $0.contains("屏蔽") }

        feed.update(time: 0)
        try await settle(feed)
        precondition(requests.values == [0], "First update loads from the start: \(requests.values)")
        var time = 0.0
        while time < 60 { time += 0.25; feed.update(time: time) }
        precondition(feed.messages.count == 59, "One message per second, blocked one removed: \(feed.messages.count)")
        precondition(feed.messages.first?.message == "第1条" && feed.messages.last?.message == "第60条")
        precondition(!feed.recent.contains { $0.text.contains("屏蔽") })
        print("PASS: danmaku emitted in playback order, filtered by block keywords")

        let clearsBefore = feed.clearToken
        feed.update(time: 300)
        precondition(feed.clearToken == clearsBefore + 1 && feed.messages.isEmpty, "Jump clears the overlay")
        precondition(feed.recent.first?.offset == 241 && feed.recent.last?.offset == 300, "List backfills the last minute")
        time = 300
        while time < 420 { time += 0.25; feed.update(time: time) }
        try await settle(feed)
        precondition(requests.values.count == 2 && requests.values[1] == 500_000, "Prefetch continues from window end: \(requests.values)")
        print("PASS: seek inside the loaded range reuses the buffer; prefetch continues at the window end")

        feed.update(time: 1100)
        try await settle(feed)
        precondition(requests.values.last == 1_099_000, "Seek outside the range reloads from the new position: \(requests.values)")
        time = 1100
        while time < 1110 { time += 0.25; feed.update(time: time) }
        precondition(feed.messages.map { $0.message } == (1101...1110).map { "第\($0)条" })
        let countAfterSeek = requests.values.count
        feed.update(time: 1105)
        precondition(requests.values.count == countAfterSeek, "Small backward seek inside the range does not refetch")
        feed.update(time: 1300)
        precondition(feed.messages.isEmpty)
        print("PASS: far seek reloads, backward seek reuses, end of video stops loading")

        let paused = feed.messages.count
        for _ in 0..<8 { feed.update(time: 1300) }
        precondition(feed.messages.count == paused, "Paused playback emits nothing")
        feed.stop()

        let suite = "replay-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = ReplayProgressStore(defaults: defaults)
        progress.record(hashID: "a", position: 600, duration: 7200)
        precondition(progress.resumePosition(for: "a") == 600)
        precondition(ReplayProgressStore(defaults: defaults).resumePosition(for: "a") == 600, "Progress survives reload")
        progress.record(hashID: "a", position: 7190, duration: 7200)
        precondition(progress.resumePosition(for: "a") == nil, "Finished videos restart from the beginning")
        progress.record(hashID: "b", position: 5, duration: 7200)
        precondition(progress.resumePosition(for: "b") == nil, "The first seconds are not worth resuming")
        print("PASS: watch progress resumes, survives reload, and forgets finished videos")

        progress.record(hashID: "private", position: 60, duration: 600)
        progress.clear()
        precondition(progress.entries.isEmpty && ReplayProgressStore(defaults: defaults).entries.isEmpty,
                     "Clear must remove both in-memory and persisted progress")
        print("PASS: clearing progress removes all persisted viewing records")

        let bins = ReplayDanmakuHeat.normalize([0, 0, 9, 0, 0, 36, 0])
        precondition(bins.count == 7 && bins.max() == 1 && bins[0] == 0 && bins[2] > 0)
        precondition(ReplayDanmakuHeat.normalize([0, 0]).allSatisfy { $0 == 0 })
        print("PASS: heat curve normalizes and smooths")
    }

    @MainActor static func settle(_ feed: ReplayDanmakuFeed) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(5))
            if !feed.isLoading { return }
        }
        fatalError("Feed did not finish loading")
    }
}
