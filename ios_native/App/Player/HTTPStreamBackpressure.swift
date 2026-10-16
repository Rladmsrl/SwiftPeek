import Foundation

/// Bounded admission for HTTP delegate callbacks. Cancellation discards queued
/// chunks, so outstanding admissions need not be released by the consumer.
/// Unlike DispatchSemaphore, this counter can safely die with unused admissions.
final class HTTPStreamBackpressure: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var available: Int
    private var cancelled = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.available = capacity
    }

    /// Blocks only the URLSession delegate queue, never a cooperative async task.
    func acquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while available == 0 && !cancelled {
            condition.wait()
        }
        guard !cancelled else { return false }
        available -= 1
        return true
    }

    func release() {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, available < capacity else { return }
        available += 1
        condition.signal()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
