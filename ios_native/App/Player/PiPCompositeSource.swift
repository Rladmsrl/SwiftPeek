#if os(iOS)
import AVFoundation
import AVKit

/// Supplies composited frames only during a PiP session. If frames are not ready,
/// AVKit keeps its original content source; no black placeholder is substituted.
@MainActor
final class PiPCompositeSource {
    let layer = AVSampleBufferDisplayLayer()
    var snapshot: (() -> PiPDanmakuSnapshot)?
    var frame: (() -> CVPixelBuffer?)?
    var parent: (() -> CALayer?)?
    var playbackTime: (() -> (CMTime, Float))?
    var onReady: (() -> Void)?
    private let compositor = PiPFrameCompositor()
    private var timer: Timer?
    private var ready = false
    private var lastFrame: CVPixelBuffer?
    private var timebase: CMTimebase?

    deinit { timer?.invalidate() }

    init() {
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        layer.controlTimebase = timebase
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        autoreleasepool {
            guard let snapshot = snapshot?() else { return }
            if let timebase, let (time, rate) = playbackTime?(), time.isNumeric {
                CMTimebaseSetRateAndAnchorTime(timebase, rate: Float64(rate), anchorTime: time,
                                              immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            if let fresh = frame?() { lastFrame = fresh }
            guard let lastFrame else { return }
            if layer.superlayer == nil, let parent = parent?() {
                // Keep the original inline video in front; AVKit mirrors this source.
                parent.insertSublayer(layer, at: 0)
            }
            guard layer.superlayer != nil else { return }
            layer.frame = layer.superlayer?.bounds ?? .zero
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            guard renderer.isReadyForMoreMediaData,
                  let sample = compositor.compose(lastFrame, snapshot: snapshot, at: CACurrentMediaTime()) else { return }
            renderer.enqueue(sample)
            if !ready, layer.isReadyForDisplay {
                ready = true
                onReady?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        layer.removeFromSuperlayer()
        layer.sampleBufferRenderer.flush()
        lastFrame = nil
        ready = false
        compositor.reset()
    }
}
#endif
