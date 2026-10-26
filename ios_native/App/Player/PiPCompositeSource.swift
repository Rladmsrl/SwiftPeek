#if os(iOS)
import AVFoundation
import AVKit

/// The main actor only snapshots UI-owned state and attaches the layer.
/// A bounded background pump animates and submits PiP frames independently.
@MainActor
final class PiPCompositeSource {
    let layer = AVSampleBufferDisplayLayer()
    var snapshot: (() -> PiPDanmakuSnapshot)?
    var frame: (() -> CVPixelBuffer?)?
    var parent: (() -> CALayer?)?
    var playbackTime: (() -> (CMTime, Float))?
    var onReady: (() -> Void)?
    private let pump: PiPFramePump
    private var generation = 0
    private var running = false
    private var ready = false
    private var lastFrame: CVPixelBuffer?
    private var lastSourceID: String?
    private var lastClearToken: Int?

    init() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        layer.controlTimebase = timebase
        let renderer = layer.sampleBufferRenderer
        pump = PiPFramePump(timebase: timebase, isReady: {
            if renderer.status == .failed { renderer.flush() }
            return renderer.isReadyForMoreMediaData
        }, enqueue: { renderer.enqueue($0) }, flush: { renderer.flush() })
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        pump.start(generation: generation) { [weak self] token in
            Task { @MainActor [weak self] in self?.capture(generation: token) }
        }
    }

    private func capture(generation token: Int) {
        guard running, generation == token else { return }
        guard let snapshot = snapshot?() else { pump.submit(nil, generation: token); return }
        if snapshot.sourceID != lastSourceID || snapshot.clearToken != lastClearToken {
            lastFrame = nil
            lastSourceID = snapshot.sourceID
            lastClearToken = snapshot.clearToken
        }
        if let fresh = frame?() { lastFrame = fresh }
        if layer.superlayer == nil, let parent = parent?() {
            // The original inline video stays in front; AVKit mirrors this source.
            parent.insertSublayer(layer, at: 0)
        }
        guard layer.superlayer != nil, let lastFrame else { pump.submit(nil, generation: token); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = layer.superlayer?.bounds ?? .zero
        CATransaction.commit()
        let now = CACurrentMediaTime()
        let (mediaTime, rate) = playbackTime?() ?? (CMTime(seconds: now, preferredTimescale: 60_000), 1)
        guard mediaTime.isNumeric, rate.isFinite else { pump.submit(nil, generation: token); return }
        pump.submit(.init(frame: lastFrame, snapshot: snapshot, hostTime: now, mediaTime: mediaTime, rate: rate), generation: token)
        if !ready, layer.isReadyForDisplay {
            ready = true
            onReady?()
        }
    }

    func stop() {
        running = false
        generation += 1
        pump.stop()
        layer.removeFromSuperlayer()
        lastFrame = nil
        lastSourceID = nil
        lastClearToken = nil
        ready = false
    }

    deinit { pump.stop() }
}
#endif
