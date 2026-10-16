import Foundation

/// A new stream must wait for earlier asynchronous renderer flushes, including a
/// flush initiated by an old stream's resync before it was cancelled.
@MainActor
final class PlaybackFlushQueue {
    private(set) var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}
