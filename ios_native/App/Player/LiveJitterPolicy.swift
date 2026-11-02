import Foundation

/// Startup, rebuffering and weak-network decisions for buffered live playback.
///
/// A live stream arrives at real-time rate, so the buffer level at the moment the
/// clock starts is roughly the jitter it can absorb from then on. Resuming the
/// instant one frame arrives leaves zero reserve and turns one stall into a
/// play-freeze-play cycle; each stall therefore raises the refill target.
struct LiveJitterPolicy {
    /// Refill target after the first, second, third and later stalls. Stays below
    /// `LiveTagBuffer.maximumSeconds` so a refill never blocks the socket.
    static let resumeLevels: [Double] = [2, 3, 4.5, 6]
    /// One level is forgiven per stable interval.
    static let decayInterval: TimeInterval = 60
    /// A refill that cannot reach its target resumes with what it has.
    static let rebufferTimeout: TimeInterval = 10
    /// First frame: full target on a good network, progressively less on a slow one.
    static let startupSteps: [(waited: TimeInterval, seconds: Double)] = [(3, 2), (6, 1)]
    static let startupFallback: TimeInterval = 10
    /// Silence on an open socket longer than this is treated as a dead connection.
    /// Mobile TCP connections often resume on their own after a few seconds of radio loss.
    /// At 4 s such a hiccup opened a second connection on another CDN line, which competed
    /// for the bandwidth the recovering one needed and then replaced it.
    static let receiveStallTimeout: TimeInterval = 8
    /// Before the first byte (DNS, TLS and the CDN's first response) on a weak network.
    static let connectTimeout: TimeInterval = 8
    /// No tag reached the renderer for this long: the source is treated as stalled.
    static let deliveryStallTimeout: TimeInterval = 12
    /// Proactive renewal is postponed while the tag buffer (excluding what the
    /// renderer already holds) is below this.
    static let healthyRenewalSeconds = 1.0
    /// Repeated bandwidth-limited stalls within the window ask for a lower quality.
    static let downgradeWindow: TimeInterval = 90
    static let downgradeStalls = 3

    private(set) var level = 0
    private var lastStallAt: TimeInterval?
    private var underruns: [TimeInterval] = []

    static func shouldStart(seconds: Double, ready: Bool, count: Int, ended: Bool, waited: TimeInterval) -> Bool {
        if ready { return true }
        guard count > 0 else { return false }
        if ended || waited >= startupFallback { return true }
        return startupSteps.contains { waited >= $0.waited && seconds >= $0.seconds }
    }

    /// `holding`: startup or a refill is deliberately keeping buffered tags back. That wait
    /// is bounded by `startupFallback` / `rebufferTimeout` and says nothing about the source,
    /// so it must not count as a stall; only a hold with nothing buffered (starving) does.
    static func deliveryStalled(sinceDelivery: TimeInterval, holding: Bool, buffered count: Int) -> Bool {
        guard !(holding && count > 0) else { return false }
        return sinceDelivery > deliveryStallTimeout
    }

    /// `capacityLimited`: the buffer cannot grow (memory cap), so waiting longer gains nothing.
    /// The 4-second startup readiness is deliberately not an escape: the 4.5 and 6 second
    /// refill levels must be reachable.
    static func shouldResume(seconds: Double, target: Double, capacityLimited: Bool, count: Int, ended: Bool, waited: TimeInterval) -> Bool {
        guard count > 0 else { return false }
        return capacityLimited || seconds >= target || ended || waited >= rebufferTimeout
    }

    /// The renderer drained. Returns how much media to buffer before resuming.
    mutating func stalled(at now: TimeInterval) -> Double {
        decay(at: now)
        let target = Self.resumeLevels[level]
        level = min(level + 1, Self.resumeLevels.count - 1)
        lastStallAt = now
        return target
    }

    /// Records a stall caused by throughput rather than a dead connection.
    /// Returns true once when stalls are frequent enough to justify a lower quality.
    mutating func recordUnderrun(at now: TimeInterval) -> Bool {
        underruns = underruns.filter { now - $0 < Self.downgradeWindow } + [now]
        guard underruns.count >= Self.downgradeStalls else { return false }
        underruns.removeAll()
        return true
    }

    private mutating func decay(at now: TimeInterval) {
        guard let last = lastStallAt, level > 0 else { return }
        let steps = Int((now - last) / Self.decayInterval)
        guard steps > 0 else { return }
        level = max(0, level - steps)
        lastStallAt = last + TimeInterval(steps) * Self.decayInterval
    }
}

extension LiveJitterPolicy {
    /// A replacement arriving during a refill gets a short window to reach the
    /// target, not a fresh full timeout on top of the time already spent frozen.
    static let handoffRefillGrace: TimeInterval = 3

    static func refillStart(afterHandoff since: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(since, now - rebufferTimeout + handoffRefillGrace)
    }
}
