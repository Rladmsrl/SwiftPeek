import Foundation
import Observation
import SimpleLiveKit

/// 全局单例站点。后续接入虎牙/B站/抖音时改为 `[any LiveSite]` 注册表即可。
@MainActor
enum Sites {
    static let douyu = DouyuSite()
}

// MARK: - 推荐

@MainActor
@Observable
final class RecommendStore {
    var rooms: [LiveRoomItem] = []
    var phase: LoadPhase = .idle
    var isLoadingMore = false

    private var page = 1
    private var hasMore = true
    /// 下拉刷新会让进行中的 loadMore 作废，避免旧页数据接到新列表上。
    private var loadGeneration = 0

    func refresh() async {
        loadGeneration += 1
        let generation = loadGeneration
        page = 1
        hasMore = true
        phase = .loading
        do {
            let result = try await Sites.douyu.recommendRooms(page: 1)
            guard generation == loadGeneration else { return }
            rooms = result.items
            hasMore = result.hasMore
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentItem item: LiveRoomItem) async {
        guard hasMore, !isLoadingMore, phase == .loaded else { return }
        // 距末尾 6 个卡片时预取
        guard let index = rooms.firstIndex(of: item), index >= rooms.count - 6 else { return }

        isLoadingMore = true
        let generation = loadGeneration
        let nextPage = page + 1
        defer { isLoadingMore = false }
        do {
            let result = try await Sites.douyu.recommendRooms(page: nextPage)
            guard generation == loadGeneration else { return }
            page = nextPage
            // 斗鱼分页偶发重复，按 roomID 去重
            let existing = Set(rooms.map(\.roomID))
            rooms.append(contentsOf: result.items.filter { !existing.contains($0.roomID) })
            hasMore = result.hasMore
        } catch {
            guard generation == loadGeneration else { return }
            hasMore = false
        }
    }
}

// MARK: - 分类

@MainActor
@Observable
final class CategoryStore {
    var categories: [LiveCategory] = []
    var phase: LoadPhase = .idle

    func load() async {
        guard categories.isEmpty else { return }
        phase = .loading
        do {
            categories = try await Sites.douyu.categories()
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
final class CategoryRoomsStore {
    let category: LiveSubCategory
    var rooms: [LiveRoomItem] = []
    var phase: LoadPhase = .idle

    private var page = 1
    private var hasMore = true
    private var isLoadingMore = false
    private var loadGeneration = 0

    init(category: LiveSubCategory) {
        self.category = category
    }

    func refresh() async {
        loadGeneration += 1
        let generation = loadGeneration
        page = 1
        hasMore = true
        phase = .loading
        do {
            let result = try await Sites.douyu.categoryRooms(category, page: 1)
            guard generation == loadGeneration else { return }
            rooms = result.items
            hasMore = result.hasMore
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentItem item: LiveRoomItem) async {
        guard hasMore, !isLoadingMore, phase == .loaded else { return }
        guard let index = rooms.firstIndex(of: item), index >= rooms.count - 6 else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let nextPage = page + 1
        defer { isLoadingMore = false }
        do {
            let result = try await Sites.douyu.categoryRooms(category, page: nextPage)
            guard generation == loadGeneration else { return }
            page = nextPage
            let existing = Set(rooms.map(\.roomID))
            rooms.append(contentsOf: result.items.filter { !existing.contains($0.roomID) })
            hasMore = result.hasMore
        } catch {
            guard generation == loadGeneration else { return }
            hasMore = false
        }
    }
}

// MARK: - 搜索

@MainActor
@Observable
final class SearchStore {
    enum Scope: String, CaseIterable, Identifiable {
        case rooms = "直播间"
        case anchors = "主播"
        var id: String { rawValue }
    }

    var keyword = ""
    var scope: Scope = .rooms
    var rooms: [LiveRoomItem] = []
    var anchors: [LiveAnchorItem] = []
    var phase: LoadPhase = .idle

    private var task: Task<Void, Never>?

    func search() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !trimmed.isEmpty else {
            rooms = []
            anchors = []
            phase = .idle
            return
        }
        phase = .loading
        task = Task { [scope] in
            do {
                switch scope {
                case .rooms:
                    let result = try await Sites.douyu.searchRooms(trimmed, page: 1)
                    guard !Task.isCancelled else { return }
                    rooms = result.items
                case .anchors:
                    let result = try await Sites.douyu.searchAnchors(trimmed, page: 1)
                    guard !Task.isCancelled else { return }
                    anchors = result.items
                }
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 直播间

/// Spaced admission, with no backlog or catch-up burst after an idle period.
struct DanmakuDeliveryLimiter {
    let messagesPerSecond: Int?
    private var nextAllowedAt: TimeInterval?

    init(messagesPerSecond: Int? = nil) { self.messagesPerSecond = messagesPerSecond }

    mutating func accept(at time: TimeInterval) -> Bool {
        guard let limit = messagesPerSecond else { return true }
        guard limit > 0, time >= (nextAllowedAt ?? time) else { return false }
        nextAllowedAt = time + 1 / Double(limit)
        return true
    }
}

@MainActor
@Observable
final class RoomStore {
    let roomID: String
    private let site: any LiveSite
    private var streamRequestGeneration = 0

    struct Selection {
        let qualityName: String?
        let lineID: String?
    }

    var playbackSelection: Selection {
        Selection(qualityName: qualities.indices.contains(selectedQualityIndex) ? qualities[selectedQualityIndex].quality : nil,
                  lineID: playURL?.lineID(at: currentLineIndex))
    }

    func cancelPendingStreamRequest() { streamRequestGeneration += 1 }

    private func isCurrentRequest(_ generation: Int) -> Bool {
        generation == streamRequestGeneration && !Task.isCancelled
    }

    var detail: LiveRoomDetail?
    var phase: LoadPhase = .idle

    var qualities: [LivePlayQuality] = []
    var selectedQualityIndex = 0
    var qualityPreferenceOverride: QualityPreference?
    var remembersQuality = true
    var playURL: LivePlayURL?
    var currentLineIndex = 0

    var messages: [LiveMessage] = []
    var danmakuNotice: String?
    var isDanmakuVisible = true
    /// A per-room choice made in multi-watch survives metadata reloads.
    var danmakuVisibilityOverride: Bool?

    /// 重连过程中确认主播已下播时置位，供 UI 显示明确原因而不是笼统的连接失败。
    var offlineNotice: String?

    /// 最近一次播放地址变更是否来自自动重连。
    ///
    /// 播放地址变更有两个来源——用户切清晰度/线路，和自动重连取到新址——
    /// 二者语义相反：前者应重置重连预算，后者必须保留，否则
    /// 「取新址 → 失败 → 重置预算 → 再取新址」永远走不到放弃分支。
    /// 光看地址字符串分不出来源，所以在每个写入点显式标注。
    var lastStreamChangeWasReconnect = false

    private var danmaku: (any LiveDanmakuClient)?
    private var danmakuPump: Task<Void, Never>?

    /// 由 RoomView 注入：用于按设置过滤弹幕、选默认清晰度、写观看历史
    private var settings: AppSettings?
    private var library: LibraryStore?

    /// 弹幕列表上限，避免长时间观看内存无上界增长
    private let messageLimit = 300
    /// 先攒一小段再一次性改 `messages`。每条都刷新 SwiftUI 会把主线程打满。
    private var pendingMessages: [LiveMessage] = []
    private var flushTask: Task<Void, Never>?
    private var flushGeneration = 0
    private(set) var danmakuDeliveryEnabled = true
    private var danmakuLimiter = DanmakuDeliveryLimiter()
    var danmakuMessagesPerSecond: Int? { danmakuLimiter.messagesPerSecond }

    func setDanmakuDeliveryLimit(_ messagesPerSecond: Int?) {
        guard danmakuMessagesPerSecond != messagesPerSecond else { return }
        danmakuLimiter = DanmakuDeliveryLimiter(messagesPerSecond: messagesPerSecond)
        clearDeliveredDanmaku()
    }

    private func clearDeliveredDanmaku() {
        flushGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        pendingMessages.removeAll()
        messages.removeAll()
    }

    /// A hidden multi-watch room keeps its socket but does not accumulate or
    /// publish message batches. Selection can resume immediately without a login.
    func setDanmakuDeliveryEnabled(_ enabled: Bool) {
        guard danmakuDeliveryEnabled != enabled else { return }
        danmakuDeliveryEnabled = enabled
        if !enabled {
            clearDeliveredDanmaku()
            danmakuLimiter = DanmakuDeliveryLimiter(messagesPerSecond: danmakuMessagesPerSecond)
        }
    }

    /// 防止 `.task` 重跑时并发进入 load()
    private var isLoading = false

    init(roomID: String, site: (any LiveSite)? = nil) {
        self.roomID = roomID
        self.site = site ?? Sites.douyu
    }

    var currentStreamURL: String? {
        guard let playURL, playURL.urls.indices.contains(currentLineIndex) else { return nil }
        return playURL.urls[currentLineIndex]
    }

    var lineCount: Int { playURL?.urls.count ?? 0 }

    func configure(settings: AppSettings, library: LibraryStore) {
        self.settings = settings
        self.library = library
        isDanmakuVisible = danmakuVisibilityOverride ?? settings.data.danmakuVisibleByDefault
    }

    func load(selection: Selection? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        streamRequestGeneration += 1
        let generation = streamRequestGeneration
        defer { isLoading = false }
        do {
            if detail == nil {
                phase = .loading
                let loaded = try await site.roomDetail(roomID: roomID)
                guard isCurrentRequest(generation) else { return }
                detail = loaded
                phase = .loaded
                if let settings, settings.data.historyEnabled {
                    library?.recordHistory(detail: loaded, limit: settings.data.historyLimit)
                }
                await startDanmaku(detail: loaded)
                guard isCurrentRequest(generation) else { return }
            }
            guard let detail, detail.isLiving else { return }
            if qualities.isEmpty {
                let loadedQualities = try await site.playQualities(detail: detail)
                guard isCurrentRequest(generation) else { return }
                qualities = loadedQualities
                guard !qualities.isEmpty else { return }
                selectedQualityIndex = selection?.qualityName.flatMap { name in
                    qualities.firstIndex { $0.quality == name }
                } ?? preferredQualityIndex(for: qualities)
            }
            if playURL == nil {
                let fresh = try await site.playURL(detail: detail, quality: qualities[selectedQualityIndex])
                guard isCurrentRequest(generation) else { return }
                try requireUsable(fresh)
                lastStreamChangeWasReconnect = false
                playURL = fresh
                currentLineIndex = fresh.index(forLineID: selection?.lineID)
                offlineNotice = nil
            }
        } catch {
            guard isCurrentRequest(generation) else { return }
            if detail == nil { phase = .failed(error.localizedDescription) }
            else { danmakuNotice = "取流失败：\(error.localizedDescription)" }
        }
    }

    private func requireUsable(_ stream: LivePlayURL) throws {
        guard !stream.urls.isEmpty else { throw LiveCoreError("未取到可用线路") }
    }

    private func preferredQualityIndex(for qualities: [LivePlayQuality]) -> Int {
        if let preference = qualityPreferenceOverride {
            return preference.index(in: qualities.count, lastQualityName: nil, names: qualities.map(\.quality))
        }
        guard let settings, !qualities.isEmpty else { return 0 }
        let index = settings.data.qualityPreference.index(
            in: qualities.count,
            lastQualityName: settings.data.lastQualityName,
            names: qualities.map(\.quality)
        )
        return min(max(index, 0), qualities.count - 1)
    }

    /// 当前是否被设置为「不自动播放」
    var autoPlayEnabled: Bool { settings?.data.autoPlay ?? true }
    var backgroundAudioEnabled: Bool { settings?.data.backgroundAudio ?? true }
    var showResolutionBadge: Bool { settings?.data.showResolutionBadge ?? true }
    var danmakuRenderSettings: DanmakuSettings {
        settings?.danmakuSettings ?? DanmakuSettings()
    }

    /// Commit quality, URL, line and preference together only after a successful request.
    @discardableResult
    func selectQuality(_ index: Int, remember: Bool = true) async -> Bool {
        guard let detail, index != selectedQualityIndex, qualities.indices.contains(index) else { return false }
        streamRequestGeneration += 1
        let generation = streamRequestGeneration
        let quality = qualities[index]
        let previousLine = playbackSelection.lineID
        do {
            let fresh = try await site.playURL(detail: detail, quality: quality)
            guard isCurrentRequest(generation) else { return false }
            try requireUsable(fresh)
            selectedQualityIndex = index
            currentLineIndex = fresh.index(forLineID: previousLine)
            lastStreamChangeWasReconnect = false
            playURL = fresh
            if remember, remembersQuality { settings?.data.lastQualityName = quality.quality }
            danmakuNotice = nil
            offlineNotice = nil
            return true
        } catch {
            guard isCurrentRequest(generation) else { return false }
            danmakuNotice = "切换清晰度失败：\(error.localizedDescription)"
            return false
        }
    }

    func switchToNextLine() {
        guard lineCount > 1 else { return }
        cancelPendingStreamRequest()
        lastStreamChangeWasReconnect = false
        currentLineIndex = (currentLineIndex + 1) % lineCount
    }

    /// Recovery rotates CDN; a user resuming playback retains the selected CDN.
    /// An offline result must be confirmed; failed/unknown status still permits fetching a stream.
    func refreshStreamURL(rotateLine: Bool = true) async -> String? {
        guard let detail, qualities.indices.contains(selectedQualityIndex) else { return nil }
        streamRequestGeneration += 1
        let generation = streamRequestGeneration
        let quality = qualities[selectedQualityIndex]
        let previousLine = playbackSelection.lineID
        offlineNotice = nil
        LiveDiagnostics.record("room.refreshStream", roomID: roomID, fields: ["line": String(currentLineIndex), "rotate": String(rotateLine)])
        do {
            let first = try await site.roomBrief(roomID: roomID)
            guard isCurrentRequest(generation) else { return nil }
            LiveDiagnostics.record("room.reconnectStatus", roomID: roomID, fields: ["living": String(first.isLiving), "loop": String(first.isRecord)])
            if !first.isLiving {
                try await Task.sleep(for: .milliseconds(300))
                let confirmed = try await site.roomBrief(roomID: roomID)
                guard isCurrentRequest(generation) else { return nil }
                if !confirmed.isLiving {
                    offlineNotice = confirmed.isRecord ? "当前为轮播内容" : "主播已下播"
                    LiveDiagnostics.record("room.offlineConfirmed", roomID: roomID)
                    return nil
                }
            }
        } catch {
            guard isCurrentRequest(generation) else { return nil }
            LiveDiagnostics.record("room.statusFailed", roomID: roomID, fields: ["error": error.localizedDescription])
        }
        do {
            let fresh = try await site.playURL(detail: detail, quality: quality)
            guard isCurrentRequest(generation) else { return nil }
            try requireUsable(fresh)
            let matchedLine = fresh.index(forLineID: previousLine)
            // If the old CDN disappeared, use the first healthy one, not an unrelated numeric index.
            let previousStillExists = previousLine.map { fresh.lineIDs.contains($0) } ?? false
            currentLineIndex = rotateLine && previousStillExists && fresh.urls.count > 1
                ? (matchedLine + 1) % fresh.urls.count : matchedLine
            lastStreamChangeWasReconnect = rotateLine
            playURL = fresh
            offlineNotice = nil
            danmakuNotice = nil
            return currentStreamURL
        } catch {
            guard isCurrentRequest(generation) else { return nil }
            danmakuNotice = "取流失败：\(error.localizedDescription)"
            LiveDiagnostics.record("room.refreshFailed", roomID: roomID, fields: ["error": error.localizedDescription])
            return nil
        }
    }

    /// Prepare without touching the active URL, selected line, or the UI. The
    /// player commits this only after the replacement has media ready to consume.
    func prepareReplacementStream(rotateLine: Bool) async throws -> PreparedPlaybackStream {
        guard let detail, qualities.indices.contains(selectedQualityIndex) else {
            throw LiveCoreError("直播间尚未就绪")
        }
        let quality = qualities[selectedQualityIndex]
        let previousLine = playbackSelection.lineID
        let current = playURL
        // 续接只需要一条线路。只解析目标线路，弱网下少几次接口往返；其余线路沿用旧地址，
        // 过期了也只会在手动切线时触发一次 403 续签。
        let target = Self.replacementLine(in: current, previous: previousLine, rotate: rotateLine)
        let fresh = try await site.playURL(detail: detail, quality: quality, lineIDs: target.map { [$0] } ?? [])
        try Task.checkCancellation()
        try requireUsable(fresh)
        // 只有恰好拿回目标线路时才合并。站点退回全量解析（目标线路坏了、或不支持按线路取）
        // 时，结果就是完整线路表，按原逻辑处理，不保留已消失线路的过期地址。
        if let current, let target, fresh.lineIDs == [target] {
            let merged = current.merging(fresh)
            return PreparedPlaybackStream(stream: merged, lineIndex: merged.index(forLineID: target), qualityName: quality.quality)
        }
        let matched = fresh.index(forLineID: previousLine)
        let exists = previousLine.map { fresh.lineIDs.contains($0) } ?? false
        let index = rotateLine && exists && fresh.urls.count > 1 ? (matched + 1) % fresh.urls.count : matched
        return PreparedPlaybackStream(stream: fresh, lineIndex: index, qualityName: quality.quality)
    }

    /// 续接的目标线路：保持当前线路，或轮转到下一条。没有线路身份时返回 nil（解析全部线路）。
    static func replacementLine(in current: LivePlayURL?, previous: String?, rotate: Bool) -> String? {
        guard let previous else { return nil }
        guard rotate, let current, current.lineIDs.count > 1,
              let index = current.lineIDs.firstIndex(of: previous) else { return previous }
        return current.lineIDs[(index + 1) % current.lineIDs.count]
    }

    /// 弱网自动降档的目标：清晰度列表从高到低排列，取下一档。
    var lowerQualityIndex: Int? {
        let next = selectedQualityIndex + 1
        return qualities.indices.contains(next) ? next : nil
    }

    func commitReplacementStream(_ prepared: PreparedPlaybackStream) {
        guard qualities.indices.contains(selectedQualityIndex),
              qualities[selectedQualityIndex].quality == prepared.qualityName else { return }
        lastStreamChangeWasReconnect = true
        playURL = prepared.stream
        currentLineIndex = prepared.lineIndex
        offlineNotice = nil
        LiveDiagnostics.record("room.backgroundStreamCommitted", roomID: roomID,
                               fields: ["line": String(currentLineIndex), "cdn": playURL?.lineID(at: currentLineIndex) ?? "unknown"])
    }

    // MARK: 弹幕

    private func startDanmaku(detail: LiveRoomDetail) async {
        guard !Task.isCancelled else { return }
        guard danmaku == nil else { return }
        do {
            let client = try site.makeDanmakuClient(payload: detail.danmakuPayload)
            danmaku = client
            let stream = client.events
            danmakuPump = Task { @MainActor [weak self] in
                defer {
                    if let self, !Task.isCancelled {
                        self.flushPendingMessages()
                    }
                }
                for await event in stream {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    switch event {
                    case .ready:
                        self.danmakuNotice = nil
                    case .message(let message):
                        guard self.danmakuDeliveryEnabled else { continue }
                        // 屏蔽词在入口处过滤一次，飞幕和列表同时生效
                        self.enqueueDanmaku(message)
                    case .notice(let text):
                        self.danmakuNotice = text
                    case .closed(let reason):
                        self.flushSoon()
                        self.danmakuNotice = reason
                    }
                }
            }
            await client.start()
        } catch {
            danmakuNotice = "弹幕连接失败：\(error.localizedDescription)"
        }
    }

    /// 约 80ms 合并一次。安静的房间几乎无感，热门房不会每条弹幕都刷新整页。
    private func enqueueDanmaku(_ message: LiveMessage) {
        if settings?.isBlocked(message.message) == true { return }
        guard danmakuLimiter.accept(at: ProcessInfo.processInfo.systemUptime) else { return }
        pendingMessages.append(message)
        guard flushTask == nil else { return }
        flushGeneration += 1
        let generation = flushGeneration
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, generation == self.flushGeneration else { return }
            self.flushPendingMessages()
        }
    }

    /// 连接结束时把不足一个窗口的尾巴立刻刷出来。
    private func flushSoon() {
        flushGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        flushPendingMessages()
    }

    private func flushPendingMessages() {
        flushTask = nil
        let batch = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        messages.append(contentsOf: batch)
        if messages.count > messageLimit {
            messages.removeFirst(messages.count - messageLimit)
        }
    }

    func stop() async {
        cancelPendingStreamRequest()
        flushGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        pendingMessages.removeAll()
        danmakuPump?.cancel()
        danmakuPump = nil
        await danmaku?.stop()
        danmaku = nil
    }
}
