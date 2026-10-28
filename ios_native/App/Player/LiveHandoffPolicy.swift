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
    static let maximumAttempts = 3
    let renewalAge: TimeInterval
    private(set) var attempts = 0
    private var nextAttemptAt: TimeInterval = 0

    init(renewalAge: TimeInterval = Self.renewalAge) {
        self.renewalAge = renewalAge
    }

    static func jitteredRenewalAge() -> TimeInterval {
        renewalAge + .random(in: -renewalJitter...renewalJitter)
    }

    /// `healthy` is false while the active buffer is low; proactive renewal then waits
    /// so the second connection does not take bandwidth from a starving one.
    mutating func begin(now: TimeInterval, sourceAge: TimeInterval, ended: Bool, stalled: Bool, healthy: Bool = true) -> Bool {
        let due = sourceAge >= renewalAge && (healthy || sourceAge >= Self.latestRenewalAge)
        guard attempts < Self.maximumAttempts, now >= nextAttemptAt, due || ended || stalled else { return false }
        attempts += 1
        return true
    }
    mutating func failed(at now: TimeInterval) {
        nextAttemptAt = now + TimeInterval(min(4, attempts))
    }
    /// A preparation that failed because the device was offline is not the stream's fault.
    mutating func forgive() {
        attempts = max(0, attempts - 1)
        nextAttemptAt = 0
    }
    /// Connectivity returned or the interface changed: retry immediately with a full budget.
    mutating func networkChanged() { attempts = 0; nextAttemptAt = 0 }
    mutating func committed() { nextAttemptAt = 0 }
    mutating func stablePlayback() { attempts = 0; nextAttemptAt = 0 }
    var exhausted: Bool { attempts >= Self.maximumAttempts }
}
