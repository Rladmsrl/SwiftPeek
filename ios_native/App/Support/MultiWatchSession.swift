import Foundation
import Observation
import SimpleLiveKit

struct MultiWatchSelection: Identifiable, Equatable {
    let id: String
    let title: String
}

@MainActor
@Observable
final class MultiWatchRoom<Player: MobilePlaybackEngine>: Identifiable {
    let id: String
    let title: String
    let playback: MobileRoomPlaybackSession<Player>
    var manualQuality = false
    var name: String { playback.store.detail?.userName ?? title }

    init(id: String, title: String, player: Player, site: (any LiveSite)? = nil) {
        self.id = id
        self.title = title
        playback = MobileRoomPlaybackSession(roomID: id, player: player, site: site, managedByMultiWatch: true)
        playback.store.remembersQuality = false
    }

    init(id: String, title: String, playback: MobileRoomPlaybackSession<Player>) {
        self.id = id
        self.title = title
        self.playback = playback
        // Keep the current stream's quality when entering; changing layout alone
        // must not restart the stream the user was already watching.
        manualQuality = true
    }
}

/// Owns sessions independently of grid position, display size and fold posture.
@MainActor
@Observable
final class MultiWatchSession<Player: MobilePlaybackEngine> {
    private(set) var rooms: [MultiWatchRoom<Player>] = []
    private(set) var selectedID: String?
    private(set) var audibleID: String?
    var isPresented = false
    var audioLocked = false {
        didSet {
            if !audioLocked { audibleID = selectedID; reconcileAudio(); reconcileResources() }
        }
    }
    var muted = false { didSet { reconcileAudio(); reconcileResources() } }
    var focused = false { didSet { reconcileResources() } }
    var layoutMode: MultiWatchLayout.Mode = .balanced
    var danmakuMode: MultiWatchDanmakuMode = .selected {
        didSet {
            guard danmakuMode != oldValue else { return }
            settings?.data.multiWatchDanmakuMode = danmakuMode
            reconcileResources()
        }
    }
    private(set) var backgrounded = false
    private(set) var constrained = false
    private var pipID: String?
    private var settings: AppSettings?
    private var library: LibraryStore?
    private let makePlayer: () -> Player
    private let site: (any LiveSite)?
    private var qualityTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupGeneration = 0
    private var started: Set<String> = []
    private(set) var isRunning = false
    private struct Origin {
        let room: MultiWatchRoom<Player>
        let preference: QualityPreference?
        let remembersQuality: Bool
        let danmakuMessagesPerSecond: Int?
        let danmakuVisibilityOverride: Bool?
    }
    private var origin: Origin?
    var hasOrigin: Bool { origin != nil }
    #if DEBUG
    var suppressConnectionsForLayoutPreview = false
    #endif

    init(makePlayer: @escaping () -> Player, site: (any LiveSite)? = nil) {
        self.makePlayer = makePlayer
        self.site = site
    }

    var selected: MultiWatchRoom<Player>? { rooms.first { $0.id == selectedID } }
    var pipCandidate: MultiWatchRoom<Player>? { rooms.first { $0.id == audibleID } ?? selected }
    var hasSound: Bool { !muted && audibleID != nil }

    func configure(settings: AppSettings, library: LibraryStore) {
        self.settings = settings
        self.library = library
        danmakuMode = settings.data.multiWatchDanmakuMode
    }

    func present() {
        MobilePlaybackInterruption.shared.setActive(true)
        isPresented = true
    }

    func owns(_ playback: MobileRoomPlaybackSession<Player>) -> Bool {
        origin?.room.playback === playback
    }

    func begin(from playback: MobileRoomPlaybackSession<Player>, id: String, title: String) {
        guard rooms.isEmpty, origin == nil else { return }
        let room = MultiWatchRoom(id: id, title: title, playback: playback)
        origin = Origin(room: room, preference: playback.store.qualityPreferenceOverride,
                        remembersQuality: playback.store.remembersQuality,
                        danmakuMessagesPerSecond: playback.store.danmakuMessagesPerSecond,
                        danmakuVisibilityOverride: playback.store.danmakuVisibilityOverride)
        playback.store.danmakuVisibilityOverride = playback.store.isDanmakuVisible
        playback.setManagedByMultiWatch(true)
        playback.store.remembersQuality = false
        rooms = [room]
        started.insert(id)
        selectedID = id
        audibleID = playback.player.isMuted ? nil : id
        isRunning = true
        reconcileResources()
        present()
    }

    @discardableResult
    func add(id: String, title: String) -> Bool {
        guard !id.isEmpty else { return false }
        if rooms.contains(where: { $0.id == id }) { select(id); return true }
        guard rooms.count < 4 else { return false }
        let room = MultiWatchRoom(id: id, title: title, player: makePlayer(), site: site)
        room.playback.player.isMuted = true
        rooms.append(room)
        if selectedID == nil { selectedID = id; audibleID = id }
        room.playback.store.qualityPreferenceOverride = preferredQuality(for: room)
        reconcileAudio()
        reconcileResources()
        if isRunning { scheduleStartup() }
        scheduleQuality()
        return true
    }

    func start() {
        guard !rooms.isEmpty else { return }
        isRunning = true
        scheduleStartup()
    }

    /// Stagger signatures/connections so four additions do not spike together.
    private func scheduleStartup() {
        #if DEBUG
        if suppressConnectionsForLayoutPreview { return }
        #endif
        guard startupTask == nil, let settings, let library else { return }
        let generation = startupGeneration
        startupTask = Task { [weak self] in
            defer { if self?.startupGeneration == generation { self?.startupTask = nil } }
            while let self, !Task.isCancelled, self.isRunning,
                  let room = self.rooms.first(where: { !self.started.contains($0.id) }) {
                self.started.insert(room.id)
                room.playback.store.qualityPreferenceOverride = self.preferredQuality(for: room)
                room.playback.open(settings: settings, library: library, autoPlay: true)
                self.reconcileResources()
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
        }
    }

    func select(_ id: String) {
        guard rooms.contains(where: { $0.id == id }) else { return }
        guard selectedID != id else { return }
        selectedID = id
        if !audioLocked { audibleID = id }
        reconcileAudio()
        reconcileResources()
        scheduleQuality()
    }

    func listen(_ id: String) {
        guard rooms.contains(where: { $0.id == id }) else { return }
        audibleID = id
        muted = false
        reconcileAudio()
        reconcileResources()
    }

    func toggleSound(_ id: String) {
        guard rooms.contains(where: { $0.id == id }) else { return }
        if audibleID == id && !muted {
            audibleID = nil
            reconcileAudio()
            reconcileResources()
        } else { listen(id) }
    }

    func toggleAllSound() {
        if hasSound { muted = true }
        else {
            if audibleID == nil { audibleID = selectedID }
            muted = false
        }
    }

    private func reconcileAudio() {
        // Mute all other renderers before unmuting the destination.
        for room in rooms where muted || room.id != audibleID { room.playback.player.isMuted = true }
        if !muted { rooms.first { $0.id == audibleID }?.playback.player.isMuted = false }
    }

    func remove(_ id: String) {
        guard let room = rooms.first(where: { $0.id == id }) else { return }
        room.playback.player.isMuted = true
        if owns(room.playback) {
            room.playback.stopPlayback()
            room.playback.store.setDanmakuDeliveryEnabled(false)
        }
        else { room.playback.close() }
        rooms.removeAll { $0.id == id }
        started.remove(id)
        if selectedID == id { selectedID = rooms.first?.id }
        if audibleID == id { audibleID = selectedID }
        if pipID == id { pipID = nil }
        if rooms.isEmpty { isRunning = false; focused = false }
        reconcileAudio()
        reconcileResources()
        scheduleQuality()
        if rooms.isEmpty { finish() }
    }

    func move(_ id: String, to targetID: String) {
        guard let from = rooms.firstIndex(where: { $0.id == id }),
              let to = rooms.firstIndex(where: { $0.id == targetID }), from != to else { return }
        rooms.swapAt(from, to)
    }

    func chooseQuality(_ index: Int, for room: MultiWatchRoom<Player>) {
        guard !room.playback.isWorking else { return }
        room.manualQuality = true
        room.playback.chooseQuality(index)
    }

    func useAutomaticQuality(_ room: MultiWatchRoom<Player>) {
        room.manualQuality = false
        scheduleQuality()
    }

    func refreshAutomaticQuality() { scheduleQuality() }

    private func preferredQuality(for room: MultiWatchRoom<Player>) -> QualityPreference {
        constrained || (rooms.count > 1 && room.id != selectedID) ? .lowest : .medium
    }

    private func scheduleQuality() {
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard let self else { return }
            for room in self.rooms where !room.manualQuality {
                let preference = self.preferredQuality(for: room)
                room.playback.store.qualityPreferenceOverride = preference
                if !room.playback.isWorking, !room.playback.store.qualities.isEmpty {
                    let count = room.playback.store.qualities.count
                    let index = preference.index(in: count, lastQualityName: nil, names: [])
                    if index != room.playback.store.selectedQualityIndex { room.playback.chooseQuality(index) }
                }
            }
        }
    }

    func setConstrained(_ value: Bool) {
        guard constrained != value else { return }
        constrained = value
        reconcileResources()
        scheduleQuality()
    }

    func setBackgrounded(_ value: Bool) { backgrounded = value; reconcileResources() }
    func setPiP(_ id: String?) { pipID = id; reconcileResources() }
    func refreshSettings() { reconcileResources() }

    func showsDanmaku(for room: MultiWatchRoom<Player>) -> Bool {
        guard !backgrounded, room.playback.store.isDanmakuVisible else { return false }
        switch danmakuMode {
        case .off: return false
        case .selected: return room.id == selectedID
        case .all: return room.id == selectedID || (!focused && !constrained)
        }
    }

    func danmakuSettings(for room: MultiWatchRoom<Player>) -> DanmakuSettings {
        var result = room.playback.store.danmakuRenderSettings
        if danmakuMode == .all {
            result.areaRatio = min(0.25, result.areaRatio * 0.5)
            result.gap *= 2
        }
        return result
    }

    func setDanmakuVisible(_ visible: Bool, for room: MultiWatchRoom<Player>) {
        room.playback.store.danmakuVisibilityOverride = visible
        room.playback.store.isDanmakuVisible = visible
        reconcileResources()
    }

    private func reconcileResources() {
        for room in rooms {
            room.playback.store.setDanmakuDeliveryLimit(danmakuMode == .all ? 3 : nil)
            let pipDanmaku = room.id == pipID && danmakuMode != .off
                && room.playback.store.isDanmakuVisible && settings?.data.pictureInPictureDanmaku == true
            room.playback.store.setDanmakuDeliveryEnabled(showsDanmaku(for: room) || pipDanmaku)
            let audio = !muted && room.id == audibleID
            let backgroundAllowed = room.id == pipID || (audio && settings?.data.backgroundAudio == true)
            let hidden = focused && room.id != selectedID && !audio
            room.playback.setBackgroundAudio(backgroundAllowed)
            room.playback.setPictureInPictureActive(room.id == pipID)
            room.playback.setSceneBackgrounded(backgrounded)
            // The PiP candidate keeps the session's short grace period so automatic
            // PiP can start before background suspension. Other rooms stop promptly.
            room.playback.setSuspended(hidden || (backgrounded && !backgroundAllowed && room.id != pipCandidate?.id))
        }
    }

    func finish(stopOrigin: Bool = false) {
        startupGeneration += 1
        startupTask?.cancel(); startupTask = nil
        qualityTask?.cancel(); qualityTask = nil
        let returning = origin
        let returningMuted = !hasSound
        let wasBackgrounded = backgrounded
        for room in rooms where room.playback !== returning?.room.playback { room.playback.close() }
        if stopOrigin { returning?.room.playback.stopPlayback() }
        origin = nil
        rooms.removeAll(); started.removeAll()
        selectedID = nil; audibleID = nil; pipID = nil
        isRunning = false; focused = false; audioLocked = false; muted = false
        backgrounded = false
        isPresented = false
        MobilePlaybackInterruption.shared.setActive(false)
        if let returning {
            let playback = returning.room.playback
            playback.store.qualityPreferenceOverride = returning.preference
            playback.store.remembersQuality = returning.remembersQuality
            playback.player.isMuted = returningMuted
            playback.store.danmakuVisibilityOverride = returning.danmakuVisibilityOverride
            playback.store.setDanmakuDeliveryLimit(returning.danmakuMessagesPerSecond)
            playback.store.setDanmakuDeliveryEnabled(true)
            playback.setBackgroundAudio(settings?.data.backgroundAudio ?? false)
            playback.setPictureInPictureActive(false)
            playback.setSceneBackgrounded(wasBackgrounded)
            playback.setSuspended(false)
            playback.setManagedByMultiWatch(false)
        }
    }

    #if DEBUG
    /// Offline geometry/interaction fixture. No connections or synthetic media.
    func showLayoutPreview(count: Int) {
        suppressConnectionsForLayoutPreview = true
        for index in 1...min(4, max(1, count)) { add(id: "layout-\(index)", title: "画面 \(index)") }
        isRunning = true
        present()
    }
    #endif
}
