#if os(macOS)
import AppKit
import AVFoundation

@MainActor
final class PiPController {
    static var isSupported: Bool { true }
    var isActive: Bool { floating.isActive }
    private weak var player: FLVLivePlayer?
    private var settings: AppSettings?
    private let floating = MacFloatingVideoController()
    var danmakuSnapshot: (() -> PiPDanmakuSnapshot)?
    var onRequestPlay: (() -> Void)?
    var onRequestPause: (() -> Void)?
    var onRequestRestore: (() -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var isPossible: Bool { player?.displayLayer.superlayer != nil }

    func attach(player: FLVLivePlayer, automatic: Bool, settings: AppSettings) {
        if let current = self.player, current !== player { stop() }
        self.player = player
        self.settings = settings
    }

    func toggle() {
        if isActive { stop(); return }
        guard let player, let settings, isPossible else { return }
        player.isInFloatingWindow = true
        player.displayLayer.videoGravity = .resizeAspect
        floating.onStateChange = { [weak self] in self?.onStateChange?($0) }
        floating.onRestore = { [weak self] in self?.onRequestRestore?() }
        floating.onFinish = { [weak player] in
            guard let player else { return }
            player.isInFloatingWindow = false
            player.displayLayer.videoGravity = player.videoGravity
        }
        floating.start(layer: player.displayLayer, size: player.videoSize, settings: settings,
                       isPlaying: { [weak player] in player?.isActive == true },
                       togglePlayback: { [weak self] in
                           guard let self else { return }
                           if self.player?.isActive == true { self.onRequestPause?() }
                           else { self.onRequestPlay?() }
                       }, snapshot: { [weak self] in self?.danmakuSnapshot?() ?? PiPDanmakuSnapshot() })
    }

    func stop() { floating.stop() }
    func detach() {
        stop()
        player = nil
        settings = nil
        danmakuSnapshot = nil
        onRequestPlay = nil
        onRequestPause = nil
        onRequestRestore = nil
        onStateChange = nil
    }
}

#endif
