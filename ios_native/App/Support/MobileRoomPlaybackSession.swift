import Foundation
import Observation
import SimpleLiveKit

/// Kept independent of UIKit so lifecycle decisions can be tested without a phone,
/// window, network connection or real decoder.
@MainActor
protocol MobilePlaybackEngine: AnyObject {
    var isActive: Bool { get }
    var volume: Double { get set }
    var isMuted: Bool { get set }
    var onPrepareStream: (@MainActor (Bool) async throws -> PreparedPlaybackStream)? { get set }
    var onCommitStream: (@MainActor (PreparedPlaybackStream) -> Void)? { get set }
    var onSustainedUnderrun: (@MainActor () -> Void)? { get set }
    var diagnosticFields: [String: String] { get }
    func start(url: String, headers: [String: String]?)
    func stop()
    func abortReconnect(reason: String)
}

@MainActor
@Observable
final class MobileRoomPlaybackSession<Player: MobilePlaybackEngine> {
    private(set) var store: RoomStore
    let player: Player
    private(set) var isWorking = false
    private let roomID: String
    private let site: (any LiveSite)?
    private let backgroundGrace: Duration
    private var opened = false
    private var wantsPlayback = false
    private var resumeAfterBackground = false
    private var isBackgrounded = false
    private var backgroundAudio = true
    private var pictureInPictureActive = false
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    /// 实际生效的暂停：多画面中断（`externalSuspended`）或让出前台（`yielded`）任一成立。
    private var suspended = false
    private var externalSuspended = false
    private var yielded = false
    /// 关闭后再次打开（例如从录像页返回）时换新 store：旧 store 的弹幕连接已停，地址也可能过期。
    private var hasClosed = false
    private let foreground: ForegroundPlayback?
    /// 弱网自动降档后的最低一档（清晰度从高到低排列，下标越大画质越低）。
    /// 多画面的自动画质不会再调回这一档之上，否则降档一秒后又被升回去，反复重连。
    private(set) var weakNetworkQualityFloor: Int?
    @ObservationIgnored private var interruptionToken: UUID?
    private var managedByMultiWatch: Bool
    private var telemetry: Task<Void, Never>?
    private var settings: AppSettings?
    private var library: LibraryStore?

    /// `foreground` 只给单画面页面传入；多画面里的房间由多画面统一调度，不参与前台归属。
    init(roomID: String, player: Player, site: (any LiveSite)? = nil, backgroundGrace: Duration = .milliseconds(300),
         managedByMultiWatch: Bool = false, foreground: ForegroundPlayback? = nil) {
        self.roomID = roomID
        self.player = player
        self.site = site
        self.backgroundGrace = backgroundGrace
        self.managedByMultiWatch = managedByMultiWatch
        self.foreground = foreground
        store = RoomStore(roomID: roomID, site: site)
    }

    func open(settings: AppSettings, library: LibraryStore, autoPlay: Bool? = nil) {
        self.settings = settings
        self.library = library
        backgroundAudio = settings.data.backgroundAudio
        if !opened { player.volume = settings.data.playerVolume }
        updateInterruptionObservation()
        activate(autoPlay: autoPlay ?? settings.data.autoPlay)
        // 页面出现且要播放（自动播放、或之前被让出）时接管前台：其他单画面页面暂停，自己续播。
        // 用户手动停掉的房间切回来不抢，避免无故打断另一个 Tab 里还在播的页面。
        if wantsPlayback { claimForeground() }
    }

    /// 让本房间成为唯一在播的单画面页面。多画面接管期间不参与。
    func claimForeground() {
        guard opened, !managedByMultiWatch, let foreground else { return }
        foreground.claim(self)
    }

    /// The player page lends its existing session to multi-watch without stopping
    /// its stream. Only ownership of interruption/background policy changes.
    func setManagedByMultiWatch(_ value: Bool) {
        managedByMultiWatch = value
        updateInterruptionObservation()
    }

    private func updateInterruptionObservation() {
        #if os(iOS)
        if managedByMultiWatch {
            MobilePlaybackInterruption.shared.remove(interruptionToken)
            interruptionToken = nil
        } else if interruptionToken == nil {
            interruptionToken = MobilePlaybackInterruption.shared.observe { [weak self] in self?.setSuspended($0) }
        }
        #endif
    }

    /// Opening an already-open tab must never restart a paused/playing session.
    func activate(autoPlay: Bool) {
        guard !opened else { return }
        let selection = hasClosed ? replaceStore(stoppingPrevious: false) : nil
        opened = true
        wantsPlayback = autoPlay
        player.onPrepareStream = { [weak self] rotate in
            guard let self, self.opened, self.wantsPlayback else { throw CancellationError() }
            return try await self.store.prepareReplacementStream(rotateLine: rotate)
        }
        player.onCommitStream = { [weak self] prepared in
            guard let self, self.opened, self.wantsPlayback else { return }
            // No URL observation starts the player here: its buffered handoff already did the work.
            self.store.commitReplacementStream(prepared)
        }
        player.onSustainedUnderrun = { [weak self] in self?.lowerQualityForWeakNetwork() }
        loadRoom(selection: selection)
        LiveDiagnostics.record("room.open", roomID: roomID, fields: player.diagnosticFields)
        telemetry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.opened else { return }
                LiveDiagnostics.record("player.heartbeat", roomID: self.roomID, fields: self.player.diagnosticFields)
            }
        }
        reconcileBackground()
    }

    func waitUntilLoaded() async { await operation?.value }

    /// 兜底：页面被直接销毁而没走 close() 时（深链替换导航栈，隐藏 Tab 里的房间随之移除），
    /// 播放器的拉流任务强引用着播放器本身，不会自己停下；这里按正常离开收尾，停流并断开弹幕。
    /// 只做必要的收尾，不改动自身的可观察状态。
    isolated deinit {
        #if os(iOS)
        MobilePlaybackInterruption.shared.remove(interruptionToken)
        #endif
        guard opened else { return }
        operation?.cancel()
        backgroundTask?.cancel()
        telemetry?.cancel()
        if !managedByMultiWatch { settings?.data.playerVolume = player.volume }
        store.cancelPendingStreamRequest()
        player.onPrepareStream = nil
        player.onCommitStream = nil
        player.onSustainedUnderrun = nil
        player.stop()
        let store = self.store
        Task { await store.stop() }
        LiveDiagnostics.record("room.close", roomID: roomID, fields: player.diagnosticFields)
    }

    private var mayPlay: Bool { wantsPlayback && !suspended && (!isBackgrounded || backgroundAudio || pictureInPictureActive) }
    var playbackRequested: Bool { wantsPlayback && (player.isActive || isWorking) }
    private func current(_ token: Int) -> Bool { opened && token == generation && !Task.isCancelled }
    private func beginOperation() -> Int {
        generation += 1
        operation?.cancel()
        store.cancelPendingStreamRequest()
        isWorking = true
        return generation
    }
    private func loadRoom(selection: RoomStore.Selection? = nil) {
        if let settings, let library { store.configure(settings: settings, library: library) }
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            await store.load(selection: selection)
            guard let self, self.current(token) else { return }
            self.isWorking = false
            if self.mayPlay, let url = store.currentStreamURL {
                self.player.start(url: url, headers: store.playURL?.headers)
            } else if self.wantsPlayback && !self.mayPlay {
                // A fast load may finish before the background grace expires.
                // Preserve intent even though no renderer has started yet.
                self.resumeAfterBackground = true
            }
        }
    }

    func play() {
        guard opened else { return }
        // 用户点播放（含画中画里的播放键）等于要这一路出声；若之前被让出，接管时会直接续播
        claimForeground()
        guard !isWorking else { return }
        wantsPlayback = true
        guard mayPlay else { resumeAfterBackground = true; return }
        guard store.detail?.isLiving == true, !store.qualities.isEmpty else {
            reloadRoom()
            return
        }
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let fresh = await store.refreshStreamURL(rotateLine: false)
            guard let self, self.current(token) else { return }
            self.isWorking = false
            guard self.mayPlay else { return }
            if let fresh { self.player.start(url: fresh, headers: store.playURL?.headers) }
            else { self.player.abortReconnect(reason: store.offlineNotice ?? store.danmakuNotice ?? "取流失败") }
        }
    }

    private func reloadRoom() {
        loadRoom(selection: replaceStore(stoppingPrevious: true))
    }

    /// 换一个全新的 RoomStore，沿用画质偏好、弹幕开关与投递限制，返回旧的清晰度 / 线路选择。
    private func replaceStore(stoppingPrevious: Bool) -> RoomStore.Selection {
        let previous = store
        let selection = previous.playbackSelection
        if stoppingPrevious {
            previous.cancelPendingStreamRequest()
            Task { await previous.stop() }
        }
        store = RoomStore(roomID: roomID, site: site)
        store.qualityPreferenceOverride = previous.qualityPreferenceOverride
        store.remembersQuality = previous.remembersQuality
        store.danmakuVisibilityOverride = previous.danmakuVisibilityOverride
        store.isDanmakuVisible = previous.isDanmakuVisible
        store.setDanmakuDeliveryLimit(previous.danmakuMessagesPerSecond)
        store.setDanmakuDeliveryEnabled(previous.danmakuDeliveryEnabled)
        weakNetworkQualityFloor = nil
        return selection
    }

    func stopPlayback() {
        wantsPlayback = false
        resumeAfterBackground = false
        cancelPlayback()
    }
    private func cancelPlayback() {
        generation += 1
        operation?.cancel()
        operation = nil
        store.cancelPendingStreamRequest()
        isWorking = false
        player.stop()
    }
    func togglePlayback() {
        if player.isActive || isWorking { stopPlayback() }
        else { play() }
    }

    func chooseQuality(_ index: Int) {
        guard opened, !isWorking else { return }
        let restart = player.isActive
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let changed = await store.selectQuality(index)
            guard let self, self.current(token) else { return }
            self.isWorking = false
            if changed, restart, self.mayPlay, let url = store.currentStreamURL {
                self.player.start(url: url, headers: store.playURL?.headers)
            }
        }
    }
    /// Weak-network downgrade applies to this room only; the default preference is untouched.
    private func lowerQualityForWeakNetwork() {
        guard opened, wantsPlayback, !isWorking, settings?.data.autoLowerQuality == true,
              let index = store.lowerQualityIndex else { return }
        let name = store.qualities[index].quality
        LiveDiagnostics.record("room.autoLowerQuality", roomID: roomID, fields: ["quality": name])
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let changed = await store.selectQuality(index, remember: false)
            guard let self, self.current(token) else { return }
            self.isWorking = false
            guard changed else { return }
            self.weakNetworkQualityFloor = max(self.weakNetworkQualityFloor ?? 0, index)
            store.danmakuNotice = "网络较差，已自动切换到\(name)"
            if self.mayPlay, let url = store.currentStreamURL {
                self.player.start(url: url, headers: store.playURL?.headers)
            }
        }
    }

    func switchLine() {
        guard opened, !isWorking else { return }
        let restart = player.isActive
        store.switchToNextLine()
        if restart, mayPlay, let url = store.currentStreamURL {
            player.start(url: url, headers: store.playURL?.headers)
        }
    }

    func setBackgroundAudio(_ enabled: Bool) { backgroundAudio = enabled; reconcileBackground() }
    func setPictureInPictureActive(_ active: Bool) { pictureInPictureActive = active; reconcileBackground() }
    func setSceneBackgrounded(_ backgrounded: Bool) { isBackgrounded = backgrounded; reconcileBackground() }
    func setSuspended(_ value: Bool) {
        externalSuspended = value
        applySuspension()
    }
    private func setYielded(_ value: Bool) {
        yielded = value
        applySuspension()
    }
    private func applySuspension() {
        let value = externalSuspended || yielded
        guard value != suspended else { return }
        suspended = value
        if value {
            backgroundTask?.cancel()
            resumeAfterBackground = wantsPlayback
            cancelPlayback()
        } else {
            resumeAfterBackground = wantsPlayback
            reconcileBackground()
        }
    }
    private func reconcileBackground() {
        backgroundTask?.cancel()
        backgroundTask = nil
        guard opened else { return }
        if !suspended && (!isBackgrounded || backgroundAudio || pictureInPictureActive) {
            if resumeAfterBackground {
                resumeAfterBackground = false
                play()
            }
            return
        }
        // Give automatic system PiP a chance to send willStart before suspending.
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.backgroundGrace) } catch { return }
            guard self.opened, self.suspended || (self.isBackgrounded && !self.backgroundAudio && !self.pictureInPictureActive) else { return }
            guard self.wantsPlayback || self.player.isActive else { return }
            self.resumeAfterBackground = self.resumeAfterBackground || (self.wantsPlayback && (self.player.isActive || self.isWorking))
            self.cancelPlayback()
        }
    }

    func close() {
        guard opened else { return }
        opened = false
        hasClosed = true
        wantsPlayback = false
        resumeAfterBackground = false
        yielded = false
        suspended = externalSuspended
        foreground?.release(self)
        backgroundTask?.cancel()
        backgroundTask = nil
        telemetry?.cancel()
        telemetry = nil
        if !managedByMultiWatch { settings?.data.playerVolume = player.volume }
        #if os(iOS)
        MobilePlaybackInterruption.shared.remove(interruptionToken)
        interruptionToken = nil
        #endif
        cancelPlayback()
        player.onPrepareStream = nil
        player.onCommitStream = nil
        player.onSustainedUnderrun = nil
        let store = self.store
        Task { await store.stop() }
        LiveDiagnostics.record("room.close", roomID: roomID, fields: player.diagnosticFields)
    }
}

extension MobileRoomPlaybackSession: ForegroundPlaybackParticipant {
    func foregroundPlaybackChanged(owned: Bool) { setYielded(!owned) }
}
