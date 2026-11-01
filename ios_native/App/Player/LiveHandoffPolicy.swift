import Foundation

/// Refresh well before the observed ~300-second expiry; rate-limit failures.
/// These are application defaults, not a claim about the provider's guaranteed TTL.
struct LiveHandoffPolicy {
    static let renewalAge: TimeInterval = 240
    /// A low buffer may postpone proactive renewal, but not past this age.
    static let latestRenewalAge: TimeInterval = 275
    /// Spreads renewals of simultaneous players so they do not compete for bandwidth together.
    static let renewalJitter: TimeInterval = 15
    static let preparationTimeout: TimeInterval = 20
    /// Consecutive failures needed, together with `failureWindow`, before giving up.
    static let maximumAttempts = 3
    /// Retries back off 1, 2, 4, 8 seconds and then stay at this interval.
    static let maximumBackoff: TimeInterval = 15
    /// A brief API outage (rate limiting, a failed signature) must not end playback:
    /// give up only after failures have persisted this long with nothing left to play.
    static let failureWindow: TimeInterval = 60
    let renewalAge: TimeInterval
    /// Attempts since the last successful preparation, including the one in flight.
    private(set) var attempts = 0
    private var failures = 0
    private var firstFailureAt: TimeInterval?
    private var nextAttemptAt: TimeInterval = 0

    init(renewalAge: TimeInterval = Self.renewalAge) {
        self.renewalAge = renewalAge
    }

    static func jitteredRenewalAge() -> TimeInterval {
        renewalAge + .random(in: -renewalJitter...renewalJitter)
    }

    /// `healthy` is false while the active buffer is low; proactive renewal then waits
    /// so the second connection does not take bandwidth from a starving one.
    /// There is no attempt cap: a source that is still playing keeps getting retries.
    mutating func begin(now: TimeInterval, sourceAge: TimeInterval, ended: Bool, stalled: Bool, healthy: Bool = true) -> Bool {
        let due = sourceAge >= renewalAge && (healthy || sourceAge >= Self.latestRenewalAge)
        guard now >= nextAttemptAt, due || ended || stalled else { return false }
        attempts += 1
        return true
    }
    mutating func failed(at now: TimeInterval) {
        failures += 1
        if firstFailureAt == nil { firstFailureAt = now }
        nextAttemptAt = now + min(Self.maximumBackoff, pow(2, Double(min(failures, 8) - 1)))
    }
    /// A preparation that failed because the device was offline is not the stream's fault.
    mutating func forgive() {
        attempts = max(0, attempts - 1)
        nextAttemptAt = 0
    }
    /// Connectivity returned or the interface changed: retry immediately with a full budget.
    mutating func networkChanged() { reset() }
    /// Any replacement that became playable proves the URL source works again.
    mutating func committed() { reset() }
    mutating func stablePlayback() { reset() }
    /// True only after repeated failures over `failureWindow`; the caller also requires an empty buffer.
    func exhausted(at now: TimeInterval) -> Bool {
        guard failures >= Self.maximumAttempts, let firstFailureAt else { return false }
        return now - firstFailureAt >= Self.failureWindow
    }
    private mutating func reset() {
        attempts = 0
        failures = 0
        firstFailureAt = nil
        nextAttemptAt = 0
    }
}
