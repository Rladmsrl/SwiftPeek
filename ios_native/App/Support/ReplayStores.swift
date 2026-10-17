import Foundation
import Observation
import SimpleLiveKit

/// 打开录像的路由值。macOS 用作窗口参数，iOS 用作导航目的地。
struct ReplayRoute: Hashable, Codable {
    /// 指定录像；为空时打开主播的录像列表并选中最新一段
    var hashID: String?
    /// 直播间号，用于列出同一主播的其他录像
    var roomID: String?
    /// 起播位置（秒），来自链接里的 `t`
    var start: TimeInterval?
}

// MARK: - 观看进度

/// 记住每段录像看到哪里，下次打开接着看。只存最近 300 段。
@MainActor
@Observable
final class ReplayProgressStore {
    static let shared = ReplayProgressStore()

    struct Entry: Codable, Equatable {
        var position: TimeInterval
        var duration: TimeInterval
        var updatedAt: Date
    }

    private static let storageKey = "replay.progress.v1"
    private static let limit = 300
    private(set) var entries: [String: Entry] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) {
            entries = decoded
        }
    }

    /// 可续播的位置。开头或已看完的不算。
    func resumePosition(for hashID: String) -> TimeInterval? {
        entries[hashID]?.position
    }

    func fraction(for hashID: String) -> Double? {
        guard let entry = entries[hashID], entry.duration > 0 else { return nil }
        return min(1, entry.position / entry.duration)
    }

    func record(hashID: String, position: TimeInterval, duration: TimeInterval) {
        guard duration > 0, position.isFinite else { return }
        if position < 15 || position > duration - 30 {
            guard entries[hashID] != nil else { return }
            entries[hashID] = nil
        } else {
            entries[hashID] = Entry(position: position, duration: duration, updatedAt: Date())
        }
        if entries.count > Self.limit {
            let stale = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
            stale.forEach { entries[$0.key] = nil }
        }
        if let raw = try? JSONEncoder().encode(entries) {
            defaults.set(raw, forKey: Self.storageKey)
        }
    }
}

// MARK: - 录像列表

@MainActor
@Observable
final class ReplayListStore {
    let roomID: String
    private(set) var author: DouyuReplayAuthor?
    private(set) var shows: [DouyuReplayShow] = []
    private(set) var phase: LoadPhase = .idle
    private(set) var isLoadingMore = false

    private let service: DouyuReplayService
    private var page = 1
    private var hasMore = true
    private var generation = 0

    init(roomID: String, service: DouyuReplayService = DouyuReplayService()) {
        self.roomID = roomID
        self.service = service
    }

    func refresh() async {
        generation += 1
        let token = generation
        phase = .loading
        do {
            let author: DouyuReplayAuthor
            if let known = self.author { author = known } else { author = try await service.author(roomID: roomID) }
            guard token == generation else { return }
            self.author = author
            let result = try await service.replays(upID: author.upID, page: 1)
            guard token == generation else { return }
            shows = result.shows
            page = 1
            hasMore = result.hasMore
            phase = .loaded
        } catch {
            guard token == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(current show: DouyuReplayShow) async {
        guard hasMore, !isLoadingMore, phase == .loaded, let author,
              let index = shows.firstIndex(of: show), index >= shows.count - 3 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let token = generation
        do {
            let result = try await service.replays(upID: author.upID, page: page + 1)
            guard token == generation else { return }
            page += 1
            let existing = Set(shows.map(\.showID))
            shows.append(contentsOf: result.shows.filter { !existing.contains($0.showID) })
            hasMore = result.hasMore
        } catch {
            guard token == generation else { return }
            hasMore = false
        }
    }
}

// MARK: - 录像播放

/// 一个窗口 / 页面拥有一个录像会话。切换分段复用同一个播放器。
@MainActor
@Observable
final class ReplaySession {
    let player = ReplayPlayer()
    let heat = ReplayDanmakuHeat()
    private(set) var hashID: String?
    private(set) var detail: DouyuReplayDetail?
    private(set) var qualities: [DouyuReplayQuality] = []
    private(set) var selectedQualityIndex = 0
    private(set) var chapters: [DouyuReplayChapter] = []
    /// 同一场直播的全部分段
    private(set) var segments: [DouyuReplayVideo] = []
    private(set) var phase: LoadPhase = .idle
    private(set) var feed: ReplayDanmakuFeed?
    var isDanmakuVisible = true
    /// 播放结束后自动播下一段
    var autoAdvance = true

    private let service: DouyuReplayService
    private var settings: AppSettings?
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var recoveries = 0
    private var lastSaved = Date.distantPast
    private var closed = false

    init(service: DouyuReplayService = DouyuReplayService()) {
        self.service = service
        player.onTick = { [weak self] time in self?.tick(time) }
        player.onSeek = { [weak self] time in self?.feed?.reset(at: time) }
        player.onFailure = { [weak self] message in self?.recover(message) }
        player.onEnded = { [weak self] in self?.playbackEnded() }
    }

    func configure(settings: AppSettings) {
        guard self.settings == nil else { return }
        self.settings = settings
        player.configurePiP(settings: settings)
        player.danmakuSnapshot = { [weak self, weak settings] in
            guard let self, let settings else { return PiPDanmakuSnapshot() }
            return PiPDanmakuSnapshot(messages: self.feed?.messages ?? [], settings: settings.danmakuSettings,
                                      isVisible: settings.data.pictureInPictureDanmaku && self.isDanmakuVisible,
                                      isPaused: !self.player.isPlaying, clearToken: self.feed?.clearToken ?? 0,
                                      sourceID: self.hashID ?? "")
        }
        player.volume = settings.data.playerVolume
        isDanmakuVisible = settings.data.danmakuVisibleByDefault
    }

    var currentQuality: DouyuReplayQuality? {
        qualities.indices.contains(selectedQualityIndex) ? qualities[selectedQualityIndex] : nil
    }

    var currentSegmentIndex: Int? { segments.firstIndex { $0.hashID == hashID } }
    var nextSegment: DouyuReplayVideo? {
        guard let index = currentSegmentIndex, segments.indices.contains(index + 1) else { return nil }
        return segments[index + 1]
    }

    /// 当前进度所在的章节
    var currentChapter: DouyuReplayChapter? {
        let time = player.displayTime
        return chapters.last { $0.start <= time }
    }

    var duration: TimeInterval { player.duration > 0 ? player.duration : detail?.duration ?? 0 }

    // MARK: 打开

    /// 打开一段录像。`start` 为空时从上次看到的位置继续。
    func open(hashID: String, start: TimeInterval? = nil, autoplay: Bool = true) {
        guard !closed else { return }
        saveProgress(force: true)
        generation += 1
        let token = generation
        operation?.cancel()
        feed?.stop()
        heat.stop()
        self.hashID = hashID
        detail = nil
        chapters = []
        qualities = []
        recoveries = 0
        phase = .loading
        player.pause()

        if !segments.contains(where: { $0.hashID == hashID }) { segments = [] }
        let feed = ReplayDanmakuFeed(hashID: hashID, service: service)
        let settings = self.settings
        feed.isBlocked = { [weak settings] text in settings?.isBlocked(text) ?? false }
        self.feed = feed

        operation = Task { [weak self, service] in
            do {
                let source = try await service.source(hashID: hashID)
                guard let self, self.isCurrent(token) else { return }
                self.apply(source, start: start, autoplay: autoplay)
                self.loadExtras(for: source.detail, token: token)
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ source: DouyuReplaySource, start: TimeInterval?, autoplay: Bool) {
        detail = source.detail
        qualities = source.qualities
        selectedQualityIndex = preferredQualityIndex()
        phase = .loaded
        guard let quality = currentQuality, let url = URL(string: quality.url) else {
            phase = .failed("这段录像暂时没有可播放的地址")
            return
        }
        let position = start ?? ReplayProgressStore.shared.resumePosition(for: source.detail.hashID) ?? 0
        player.load(url: url, at: position, autoplay: autoplay)
        feed?.reset(at: position)
        LiveDiagnostics.record("replay.open", fields: ["quality": quality.key, "start": String(Int(position))])
    }

    /// 章节、分段、热度曲线都是锦上添花，失败不影响播放
    private func loadExtras(for detail: DouyuReplayDetail, token: Int) {
        let hashID = detail.hashID
        let service = self.service
        Task { [weak self] in
            let chapters = (try? await service.chapters(hashID: hashID)) ?? []
            guard let self, self.isCurrent(token) else { return }
            self.chapters = chapters
        }
        if !segments.contains(where: { $0.hashID == hashID }), !detail.upID.isEmpty {
            Task { [weak self] in
                let segments = (try? await service.segments(hashID: hashID, upID: detail.upID)) ?? []
                guard let self, self.isCurrent(token) else { return }
                self.segments = segments
            }
        }
        heat.start(duration: detail.duration) { start in
            try await service.danmaku(hashID: hashID, from: start)
        }
    }

    private func preferredQualityIndex() -> Int {
        guard let settings, !qualities.isEmpty else { return 0 }
        let names = qualities.map(\.name)
        let index = settings.data.qualityPreference.index(
            in: qualities.count, lastQualityName: settings.data.lastQualityName, names: names
        )
        return min(max(index, 0), qualities.count - 1)
    }

    // MARK: 控制

    func seek(to time: TimeInterval) {
        player.seek(to: time)
    }

    func skip(by delta: TimeInterval) {
        seek(to: player.displayTime + delta)
    }

    func chooseQuality(_ index: Int) {
        guard qualities.indices.contains(index), index != selectedQualityIndex,
              let url = URL(string: qualities[index].url) else { return }
        selectedQualityIndex = index
        player.load(url: url, at: player.displayTime, autoplay: player.isPlaying || player.state == .loading)
    }

    /// 播放失败多半是签名地址过期：重新取流，从原位置继续。连续失败两次就交给用户。
    private func recover(_ message: String) {
        guard let hashID, let detail, recoveries < 2, !closed else { return }
        recoveries += 1
        let token = generation
        let position = player.displayTime
        let key = currentQuality?.key
        operation = Task { [weak self, service] in
            do {
                let fresh = try await service.qualities(hashID: hashID, pointID: detail.pointID)
                guard let self, self.isCurrent(token) else { return }
                self.qualities = fresh
                self.selectedQualityIndex = fresh.firstIndex { $0.key == key } ?? self.preferredQualityIndex()
                guard let quality = self.currentQuality, let url = URL(string: quality.url) else { return }
                LiveDiagnostics.record("replay.recover", fields: ["attempt": String(self.recoveries), "reason": message])
                self.player.load(url: url, at: position, autoplay: true)
            } catch {
                LiveDiagnostics.record("replay.recoverFailed", fields: ["error": error.localizedDescription])
            }
        }
    }

    /// 用户点「重试」：重新抓页面、取流，从当前位置继续
    func retry() {
        guard let hashID else { return }
        let position = player.displayTime
        open(hashID: hashID, start: position > 1 ? position : nil)
    }

    private func playbackEnded() {
        saveProgress(force: true)
        if autoAdvance, let next = nextSegment { open(hashID: next.hashID, start: 0) }
    }

    private func tick(_ time: TimeInterval) {
        feed?.update(time: time)
        if player.state == .playing { recoveries = 0 }
        saveProgress(force: false)
    }

    private func saveProgress(force: Bool) {
        guard let hashID, duration > 0, player.state != .loading, player.state != .idle else { return }
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        ReplayProgressStore.shared.record(hashID: hashID, position: player.displayTime, duration: duration)
    }

    private func isCurrent(_ token: Int) -> Bool { !closed && token == generation && !Task.isCancelled }

    func close() {
        guard !closed else { return }
        saveProgress(force: true)
        settings?.data.playerVolume = player.volume
        closed = true
        generation += 1
        operation?.cancel()
        feed?.stop()
        heat.stop()
        player.shutdown()
    }
}
