import AVFoundation
import QuartzCore
import SimpleLiveKit

/// One latest-input slot and one serial compositor. Missed deadlines are dropped,
/// never queued for catch-up; a slow UI must not turn the PiP animation into a slideshow.
final class PiPFramePump: @unchecked Sendable {
    struct Input {
        let frame: CVPixelBuffer
        let snapshot: PiPDanmakuSnapshot
        let hostTime: TimeInterval
        let mediaTime: CMTime
        let rate: Float
    }

    private let queue = DispatchQueue(label: "com.simplelive.pip.compose", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var requestPending = false
    private var latest: Input?
    // Everything below is confined to queue, including CPU pixel composition and renderer operations.
    private let compositor = PiPFrameCompositor()
    private var timer: DispatchSourceTimer?
    private let timebase: CMTimebase?
    private let isReady: () -> Bool
    private let enqueue: (CMSampleBuffer) -> Void
    private let flush: () -> Void
    private var lastInput: Input?
    private var nextRequest: TimeInterval = -.infinity
    private var lastRender: TimeInterval = -.infinity
    private var reportStart: TimeInterval = 0
    private var enqueued = 0
    private var dropped = 0
    private var sourceFrames = 0
    private var maximumInputAge: Double = 0
    private var renderMilliseconds: Double = 0

    init(timebase: CMTimebase?, isReady: @escaping () -> Bool,
         enqueue: @escaping (CMSampleBuffer) -> Void, flush: @escaping () -> Void) {
        self.timebase = timebase
        self.isReady = isReady
        self.enqueue = enqueue
        self.flush = flush
    }

    func start(generation token: Int, requestInput: @escaping @Sendable (Int) -> Void) {
        lock.lock()
        generation = token
        active = true
        requestPending = false
        latest = nil
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.timer?.cancel()
            self.compositor.reset()
            self.lastInput = nil
            self.nextRequest = -.infinity
            self.lastRender = -.infinity
            self.reportStart = CACurrentMediaTime()
            self.enqueued = 0
            self.dropped = 0
            self.sourceFrames = 0
            self.maximumInputAge = 0
            self.renderMilliseconds = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick(token: token, requestInput: requestInput) }
            self.timer = timer
            timer.resume()
        }
    }

    func submit(_ input: Input?, generation token: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard active, generation == token else { return }
        latest = input
        requestPending = false
    }

    func stop() {
        lock.lock()
        active = false
        latest = nil
        requestPending = false
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.lastInput = nil
            self.compositor.reset()
            self.flush()
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && generation == token
    }

    private func tick(token: Int, requestInput: (Int) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard active, generation == token else { lock.unlock(); return }
        let input = latest
        let shouldRequest = !requestPending && (input == nil || now + 0.000_01 >= nextRequest)
        if shouldRequest {
            requestPending = true
            let step = 1 / 30.0
            nextRequest = nextRequest.isFinite ? nextRequest + (floor(max(0, now - nextRequest) / step) + 1) * step : now + step
        }
        lock.unlock()
        if shouldRequest { requestInput(token) }
        guard let input else { return }
        // Pause freezes the timeline; still allow settings/seek updates at a modest cadence.
        if input.snapshot.isPaused, now - lastRender < 0.1 { return }

        autoreleasepool {
            maximumInputAge = max(maximumInputAge, max(0, now - input.hostTime))
            if lastInput?.hostTime != input.hostTime {
                if lastInput?.frame !== input.frame { sourceFrames += 1 }
                if let previous = lastInput {
                    let expected = previous.mediaTime.seconds + (input.hostTime - previous.hostTime) * Double(previous.rate)
                    if input.snapshot.sourceID != previous.snapshot.sourceID
                        || input.snapshot.clearToken != previous.snapshot.clearToken
                        || abs(input.mediaTime.seconds - expected) > 0.5 {
                        flush()
                    }
                }
                if let timebase {
                    CMTimebaseSetRateAndAnchorTime(timebase, rate: Double(input.rate), anchorTime: input.mediaTime,
                        immediateSourceTime: CMTime(seconds: input.hostTime, preferredTimescale: 60_000))
                }
                lastInput = input
            }
            if input.rate == 0 { flush() } // Replace a paused frame; don't accumulate identical timestamps.
            guard isReady() else { dropped += 1; report(at: now); return }
            let pts = CMTimeAdd(input.mediaTime,
                CMTime(seconds: max(0, now - input.hostTime) * Double(input.rate), preferredTimescale: 60_000))
            let start = CACurrentMediaTime()
            guard let sample = compositor.compose(input.frame, snapshot: input.snapshot, at: now,
                                                   presentationTimeStamp: pts) else {
                dropped += 1
                report(at: now)
                return
            }
            renderMilliseconds += (CACurrentMediaTime() - start) * 1000
            // Serialize the final enqueue with stop. An old render must never arrive
            // after a session has been disabled or replaced by a newer generation.
            lock.lock()
            if active, generation == token {
                enqueue(sample)
                enqueued += 1
                lastRender = now
            }
            lock.unlock()
            report(at: now)
        }
    }

    private func report(at now: TimeInterval) {
        let elapsed = now - reportStart
        guard elapsed >= 5 else { return }
        LiveDiagnostics.record("pip.composite.stats", fields: [
            "targetFPS": "60", "enqueuedFPS": String(format: "%.1f", Double(enqueued) / elapsed),
            "sourceFPS": String(format: "%.1f", Double(sourceFrames) / elapsed),
            "maxInputAgeMS": String(format: "%.1f", maximumInputAge * 1000),
            "meanRenderMS": String(format: "%.2f", renderMilliseconds / Double(max(1, enqueued))),
            "dropped": String(dropped)
        ])
        reportStart = now
        enqueued = 0
        dropped = 0
        sourceFrames = 0
        maximumInputAge = 0
        renderMilliseconds = 0
    }

    deinit { timer?.cancel() }
}
