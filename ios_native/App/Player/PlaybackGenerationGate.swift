import Foundation

/// A synchronous render operation and generation invalidation share one lock.
/// Once advance() returns, no operation from the old session can still enqueue.
final class PlaybackGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool { current == candidate }

    /// body must be synchronous and must not reenter this gate.
    @discardableResult
    func withCurrent<T>(_ candidate: UInt64, _ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == candidate else { return nil }
        return body()
    }
}
