import Foundation

/// Refresh well before the observed ~300-second expiry; rate-limit failures.
/// These are application defaults, not a claim about the provider's guaranteed TTL.
struct LiveHandoffPolicy {
    static let renewalAge: TimeInterval = 240
    static let preparationTimeout: TimeInterval = 20
    static let maximumAttempts = 3
    private(set) var attempts = 0
    private var nextAttemptAt: TimeInterval = 0

    mutating func begin(now: TimeInterval, sourceAge: TimeInterval, ended: Bool, stalled: Bool) -> Bool {
        guard attempts < Self.maximumAttempts, now >= nextAttemptAt,
              sourceAge >= Self.renewalAge || ended || stalled else { return false }
        attempts += 1
        return true
    }
    mutating func failed(at now: TimeInterval) {
        nextAttemptAt = now + TimeInterval(min(4, attempts))
    }
    mutating func committed() { nextAttemptAt = 0 }
    mutating func stablePlayback() { attempts = 0; nextAttemptAt = 0 }
    var exhausted: Bool { attempts >= Self.maximumAttempts }
}
