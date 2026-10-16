import Foundation

/// A first frame proves only that a CDN returned some media, not that the stream
/// recovered. Preserve both retry budgets through short-lived connections.
struct PlaybackRecoveryPolicy {
    static let maxSameURLAttempts = 2
    static let maxFreshStreamCycles = 3
    static let stablePlaybackSeconds: TimeInterval = 30
    private(set) var sameURLAttempts = 0
    private(set) var freshStreamCycles = 0
    private var playbackStartedAt: TimeInterval?

    mutating func beginAttempt() { playbackStartedAt = nil }

    mutating func playbackStarted(at uptime: TimeInterval) {
        if playbackStartedAt == nil { playbackStartedAt = uptime }
    }

    mutating func nextSameURLAttempt(at uptime: TimeInterval) -> Int? {
        if let started = playbackStartedAt, uptime - started >= Self.stablePlaybackSeconds {
            sameURLAttempts = 0
            freshStreamCycles = 0
        }
        playbackStartedAt = nil
        guard sameURLAttempts < Self.maxSameURLAttempts else { return nil }
        sameURLAttempts += 1
        return sameURLAttempts
    }

    mutating func nextFreshStreamCycle() -> Int? {
        guard freshStreamCycles < Self.maxFreshStreamCycles else { return nil }
        freshStreamCycles += 1
        sameURLAttempts = 0
        playbackStartedAt = nil
        return freshStreamCycles
    }
}
