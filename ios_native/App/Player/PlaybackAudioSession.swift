import Foundation
#if os(iOS)
import AVFAudio
#endif

/// A player releases only its own lease. Stopping one stream must not deactivate
/// the application audio session while another live stream or replay still uses it.
@MainActor
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    private(set) var owners: Set<UUID> = []
    private let activate: () throws -> Void
    private let deactivate: () throws -> Void
    private let setSampleRate: (Double) throws -> Void

    init(activate: @escaping () throws -> Void = {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        #endif
    }, deactivate: @escaping () throws -> Void = {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }, setSampleRate: @escaping (Double) throws -> Void = { rate in
        #if os(iOS)
        try AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
        #endif
    }) {
        self.activate = activate
        self.deactivate = deactivate
        self.setSampleRate = setSampleRate
    }

    func acquire(_ owner: UUID) {
        guard !owners.contains(owner) else { return }
        if owners.isEmpty {
            do { try activate() } catch { return }
        }
        owners.insert(owner)
    }

    func release(_ owner: UUID) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        try? deactivate()
    }

    func preferSampleRate(_ rate: Double, owner: UUID) {
        // A new room must not reconfigure hardware used by another live room.
        guard owners.count == 1, owners.contains(owner) else { return }
        try? setSampleRate(rate)
    }
}

/// Suspend ordinary playback while the multi-watch workspace owns the screen.
/// Callbacks live with the sessions, including pages hidden behind another tab.
@MainActor
final class MobilePlaybackInterruption {
    static let shared = MobilePlaybackInterruption()
    private var callbacks: [UUID: (Bool) -> Void] = [:]
    private(set) var isActive = false

    func observe(_ callback: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        callback(isActive)
        return id
    }
    func remove(_ id: UUID?) {
        if let id { callbacks.removeValue(forKey: id) }
    }
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for callback in Array(callbacks.values) { callback(active) }
    }
}
