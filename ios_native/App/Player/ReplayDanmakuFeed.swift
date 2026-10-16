import Foundation
import Observation
import SimpleLiveKit

/// 按录像播放进度投放弹幕。
///
/// 弹幕按时间窗口分批拉取，只维护一段连续的已加载区间：
/// 正常播放时在区间末尾预取；拖动到区间外时丢弃旧区间、从新位置重新拉。
/// 播放器每 0.25 秒回报一次进度，投放 (上次进度, 本次进度] 之间的弹幕；
/// 进度倒退或跳跃超过几秒视为拖动，清屏后从新位置继续。
@MainActor
@Observable
final class ReplayDanmakuFeed {
    /// 交给飞幕层的消息。只增不改，飞幕层按 id 找新增部分。
    private(set) var messages: [LiveMessage] = []
    /// 侧栏列表：当前进度之前最近的弹幕
    private(set) var recent: [DouyuReplayDanmaku] = []
    /// 拖动后自增，飞幕层据此清屏
    private(set) var clearToken = 0
    private(set) var notice: String?
    private(set) var isLoading = false

    var isBlocked: (String) -> Bool = { _ in false }

    private let load: @Sendable (Int) async throws -> DouyuReplayDanmakuBatch
    private var buffer: [DouyuReplayDanmaku] = []
    private var seen = Set<String>()
    private var loadedFrom: TimeInterval = 0
    private var loadedUntil: TimeInterval = 0
    private var nextStart: Int?
    private var reachedEnd = false
    private var cursor: TimeInterval?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var retryAfter: Date?

    private let messageLimit = 160
    private let recentLimit = 200
    private let prefetchLead: TimeInterval = 90
    private let jumpThreshold: TimeInterval = 3

    init(load: @escaping @Sendable (Int) async throws -> DouyuReplayDanmakuBatch) {
        self.load = load
    }

    convenience init(hashID: String, service: DouyuReplayService = DouyuReplayService()) {
        self.init { start in try await service.danmaku(hashID: hashID, from: start) }
    }

    /// 播放器进度回调
    func update(time: TimeInterval) {
        guard time.isFinite else { return }
        guard let last = cursor else { reset(at: time); return }
        if time < last - 0.5 || time > last + jumpThreshold {
            reset(at: time)
            return
        }
        guard time > last else { return }
        emit(from: last, through: time)
        cursor = time
        prefetchIfNeeded(around: time)
    }

    /// 拖动或首次进入：清屏，列表回填最近一分钟，必要时从新位置重新拉取
    func reset(at time: TimeInterval) {
        clearToken += 1
        messages.removeAll()
        cursor = time
        let covered = time >= loadedFrom && (time <= loadedUntil || reachedEnd) && !buffer.isEmpty
        if covered {
            recent = Array(buffer[firstIndex(after: time - 60)..<firstIndex(after: time)]
                .filter { !isBlocked($0.text) }
                .suffix(recentLimit))
            prefetchIfNeeded(around: time)
        } else {
            recent.removeAll()
            restart(at: time)
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }

    // MARK: 投放

    private func emit(from start: TimeInterval, through end: TimeInterval) {
        var index = firstIndex(after: start)
        var fresh: [DouyuReplayDanmaku] = []
        while index < buffer.count, buffer[index].offset <= end {
            if !isBlocked(buffer[index].text) { fresh.append(buffer[index]) }
            index += 1
        }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh.map {
            LiveMessage(kind: .chat, userName: $0.userName, message: $0.text, color: $0.color)
        })
        if messages.count > messageLimit { messages.removeFirst(messages.count - messageLimit) }
        recent.append(contentsOf: fresh)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
    }

    /// 第一条 offset 严格大于 time 的位置
    private func firstIndex(after time: TimeInterval) -> Int {
        var low = 0, high = buffer.count
        while low < high {
            let mid = (low + high) / 2
            if buffer[mid].offset <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: 加载

    private func restart(at time: TimeInterval) {
        generation += 1
        task?.cancel()
        task = nil
        buffer.removeAll()
        seen.removeAll()
        loadedFrom = max(0, time - 1)
        loadedUntil = loadedFrom
        nextStart = Int(loadedFrom * 1000)
        reachedEnd = false
        retryAfter = nil
        fetchNext()
    }

    private func prefetchIfNeeded(around time: TimeInterval) {
        guard !reachedEnd, task == nil, loadedUntil - time < prefetchLead else { return }
        if let retryAfter, retryAfter > Date() { return }
        fetchNext()
    }

    private func fetchNext() {
        guard let start = nextStart, task == nil else { return }
        let token = generation
        isLoading = true
        task = Task { [weak self, load] in
            let result: Result<DouyuReplayDanmakuBatch, Error>
            do { result = .success(try await load(start)) } catch { result = .failure(error) }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.task = nil
            self.isLoading = false
            switch result {
            case .success(let batch): self.append(batch)
            case .failure(let error):
                self.notice = "弹幕加载失败：\(error.localizedDescription)"
                self.retryAfter = Date().addingTimeInterval(5)
            }
        }
    }

    private func append(_ batch: DouyuReplayDanmakuBatch) {
        notice = nil
        retryAfter = nil
        let fresh = batch.items.filter { seen.insert($0.id).inserted }
        let wasEmpty = buffer.isEmpty
        buffer.append(contentsOf: fresh)
        if !wasEmpty, let first = fresh.first, first.offset < buffer[buffer.count - fresh.count - 1].offset {
            buffer.sort { $0.offset < $1.offset }
        }
        nextStart = batch.nextStart
        reachedEnd = batch.nextStart == nil
        if let next = batch.nextStart { loadedUntil = TimeInterval(next) / 1000 }
        else if let last = buffer.last { loadedUntil = last.offset }

        // 首批到达时把「当前位置之前一分钟」回填到列表
        if wasEmpty, let cursor {
            recent = Array(buffer[firstIndex(after: cursor - 60)..<firstIndex(after: cursor)]
                .filter { !isBlocked($0.text) }
                .suffix(recentLimit))
        }
        if let cursor { prefetchIfNeeded(around: cursor) }
    }
}

/// 弹幕热度曲线：后台按窗口扫一遍全部弹幕，统计每段时间的数量。
/// 曲线从左到右逐步长出来；弹幕过多时提前停止，不为装饰拖慢网络。
@MainActor
@Observable
final class ReplayDanmakuHeat {
    static let binCount = 120
    private(set) var bins: [Double] = []
    private(set) var isComplete = false
    private var task: Task<Void, Never>?

    func start(duration: TimeInterval, maxRequests: Int = 40,
               load: @escaping @Sendable (Int) async throws -> DouyuReplayDanmakuBatch) {
        task?.cancel()
        guard duration > 0 else { return }
        task = Task { [weak self] in
            var counts = [Int](repeating: 0, count: Self.binCount)
            var start = 0
            for _ in 0..<maxRequests {
                guard !Task.isCancelled,
                      let batch = try? await load(start) else { return }
                for item in batch.items {
                    let bin = min(Self.binCount - 1, max(0, Int(item.offset / duration * Double(Self.binCount))))
                    counts[bin] += 1
                }
                guard let self, !Task.isCancelled else { return }
                self.bins = Self.normalize(counts)
                guard let next = batch.nextStart else { self.isComplete = true; return }
                start = next
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 平滑后按最大值归一化，避免单个尖峰把其余部分压平
    static func normalize(_ counts: [Int]) -> [Double] {
        guard !counts.isEmpty else { return [] }
        let smoothed = counts.indices.map { index -> Double in
            let range = max(0, index - 1)...min(counts.count - 1, index + 1)
            return Double(range.reduce(0) { $0 + counts[$1] }) / Double(range.count)
        }
        let peak = smoothed.max() ?? 0
        guard peak > 0 else { return smoothed.map { _ in 0 } }
        return smoothed.map { ($0 / peak).squareRoot() }
    }
}
