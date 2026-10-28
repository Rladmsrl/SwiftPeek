import Foundation
import Network
import SimpleLiveKit

/// Decides which path updates matter to live recovery. NWPathMonitor also reports
/// cost and constraint changes that leave existing sockets intact.
struct NetworkPathState: Equatable {
    struct Snapshot: Equatable {
        var satisfied = true
        /// Advances when connectivity returns or the active interface changes.
        var generation: UInt64 = 0
    }
    private(set) var snapshot = Snapshot()
    private var interfaces: [String]?

    /// Returns true when the generation advanced.
    mutating func update(satisfied: Bool, interfaces next: [String]) -> Bool {
        defer {
            snapshot.satisfied = satisfied
            interfaces = next
        }
        guard let interfaces else { return false }
        let changed = satisfied != snapshot.satisfied || (satisfied && next != interfaces)
        if changed { snapshot.generation &+= 1 }
        return changed
    }
}

/// Process-wide reachability for live recovery. Detached playback tasks read it,
/// so the state is lock-protected rather than actor-bound.
final class NetworkPathMonitor: @unchecked Sendable {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var state = NetworkPathState()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "SwiftPeek.network-path", qos: .utility))
    }

    func snapshot() -> NetworkPathState.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state.snapshot
    }

    private func update(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name)
        lock.lock()
        let changed = state.update(satisfied: satisfied, interfaces: interfaces)
        let generation = state.snapshot.generation
        lock.unlock()
        if changed {
            LiveDiagnostics.record("network.path", fields: [
                "satisfied": String(satisfied), "interfaces": interfaces.joined(separator: ","),
                "generation": String(generation),
            ])
        }
    }
}
