import Foundation
import Observation
import SimpleLiveKit

/// Kept independent of UIKit so lifecycle decisions can be tested without a phone,
/// window, network connection or real decoder.
@MainActor
protocol MobilePlaybackEngine: AnyObject {
    var isActive: Bool { get }
    var volume: Double { get set }
    var onPrepareStream: (@MainActor (Bool) async throws -> PreparedPlaybackStream)? { get set }
    var onCommitStream: (@MainActor (PreparedPlaybackStream) -> Void)? { get set }
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
    private var telemetry: Task<Void, Never>?
    private var settings: AppSettings?
    private var library: LibraryStore?

    init(roomID: String, player: Player, site: (any LiveSite)? = nil, backgroundGrace: Duration = .milliseconds(300)) {
        self.roomID = roomID
        self.player = player
        self.site = site
        self.backgroundGrace = backgroundGrace
        store = RoomStore(roomID: roomID, site: site)
    }

    func open(settings: AppSettings, library: LibraryStore) {
        self.settings = settings
        self.library = library
        backgroundAudio = settings.data.backgroundAudio
        if !opened { player.volume = settings.data.playerVolume }
        activate(autoPlay: settings.data.autoPlay)
    }

    /// Opening an already-open tab must never restart a paused/playing session.
    func activate(autoPlay: Bool) {
        guard !opened else { return }
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
        loadRoom()
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

    private var mayPlay: Bool { wantsPlayback && (!isBackgrounded || backgroundAudio || pictureInPictureActive) }
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
            }
        }
    }

    func play() {
        guard opened, !isWorking else { return }
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
        let previous = store
        let selection = previous.playbackSelection
        previous.cancelPendingStreamRequest()
        Task { await previous.stop() }
        store = RoomStore(roomID: roomID, site: site)
        loadRoom(selection: selection)
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
    private func reconcileBackground() {
        backgroundTask?.cancel()
        backgroundTask = nil
        guard opened else { return }
        if !isBackgrounded || backgroundAudio || pictureInPictureActive {
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
            guard self.opened, self.isBackgrounded, !self.backgroundAudio, !self.pictureInPictureActive else { return }
            guard self.wantsPlayback || self.player.isActive else { return }
            self.resumeAfterBackground = self.resumeAfterBackground || (self.wantsPlayback && (self.player.isActive || self.isWorking))
            self.cancelPlayback()
        }
    }

    func close() {
        guard opened else { return }
        opened = false
        wantsPlayback = false
        resumeAfterBackground = false
        backgroundTask?.cancel()
        backgroundTask = nil
        telemetry?.cancel()
        telemetry = nil
        settings?.data.playerVolume = player.volume
        cancelPlayback()
        player.onPrepareStream = nil
        player.onCommitStream = nil
        let store = self.store
        Task { await store.stop() }
        LiveDiagnostics.record("room.close", roomID: roomID, fields: player.diagnosticFields)
    }
}
