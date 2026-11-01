import Foundation
import SimpleLiveKit

struct LiveHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? { "直播服务器返回 HTTP \(status)" }
    var requiresFreshURL: Bool { status == 401 || status == 403 || status == 410 }
}

/// Compressed media only. No decoded-frame cache and no disk writes.
actor LiveTagBuffer {
    static let targetSeconds = 4.0
    static let maximumSeconds = 8.0
    static let maximumBytes = 16 * 1024 * 1024
    struct Snapshot {
        let seconds: Double
        let bytes: Int
        let count: Int
        let ready: Bool
        let ended: Bool
        let error: Error?
        /// Raw FLV timestamp of the oldest buffered media tag (the start keyframe before consumption).
        let firstTimestamp: UInt32?
        let lastTimestamp: UInt32?
        /// The producer is waiting for room, so silence on the socket is expected.
        let capacityLimited: Bool
    }
    private var queue: [FLVTag] = []
    private var cursor = 0
    private var bytes = 0
    private var videoHeader: FLVTag?
    private var audioHeader: FLVTag?
    private var started = false
    private var firstTimestamp: UInt32?
    /// Newest media timestamp seen, not the last pushed: audio and video interleave
    /// with small inversions, and an unsigned difference would wrap to ~49 days.
    private var lastTimestamp: UInt32?
    private var ended = false
    private var error: Error?
    private var capacityLimited = false
    /// The blocked producer, woken by `pop()` once there is real room, by `finish()` or by cancellation.
    private var spaceWaiter: CheckedContinuation<Void, Never>?
    private var pendingBytes = 0
    /// The consumer idling at the live edge, woken by the next tag or `finish()`.
    private var tagWaiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextWaiterID = 0
    /// Wake a full producer only after this much media has been consumed, not after every tag.
    static let refillMargin = 0.5

    func append(_ tag: FLVTag) async throws {
        try Task.checkCancellation()
        guard tag.type != .script else { return }
        guard tag.payload.count <= Self.maximumBytes else { throw LivePlayerError.network("直播分块过大") }
        if !started {
            if tag.type == .video {
                guard let header = FLVVideoTag.Header(payload: tag.payload) else { return }
                guard header.isAVC else { throw LivePlayerError.unsupportedCodec }
                if header.isSequenceHeader { videoHeader = tag; return }
                guard header.isKeyframe, header.isNALUs, let sequenceHeader = videoHeader else { return }
                started = true
                push(sequenceHeader)
                if let audioHeader { push(audioHeader) }
            } else {
                if tag.payload.first == 0xAF || (tag.payload.first.map { $0 >> 4 == 10 } ?? false),
                   tag.payload.count > 1, tag.payload[1] == 0 { audioHeader = tag }
                return
            }
        }
        if isFull(adding: tag.payload.count) {
            capacityLimited = true
            pendingBytes = tag.payload.count
            defer { pendingBytes = 0 }
            try await withTaskCancellationHandler {
                while !ended && isFull(adding: tag.payload.count) {
                    try Task.checkCancellation()
                    await withCheckedContinuation { spaceWaiter = $0 }
                }
            } onCancel: {
                Task { await self.wakeProducer() }
            }
        }
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        capacityLimited = false
        push(tag)
    }

    private func isFull(adding size: Int) -> Bool {
        seconds >= Self.maximumSeconds || bytes + size > Self.maximumBytes || queue.count - cursor >= 4096
    }

    private func wakeProducer() {
        spaceWaiter?.resume()
        spaceWaiter = nil
    }

    /// Returns when a tag is available, the source ends, or `timeout` passes —
    /// instead of the consumer polling an empty buffer every few milliseconds.
    func waitForTag(timeout: Duration) async {
        guard cursor >= queue.count, !ended, tagWaiter == nil, !Task.isCancelled else { return }
        nextWaiterID += 1
        let id = nextWaiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.wakeConsumer(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { tagWaiter = (id, $0) }
        } onCancel: {
            Task { await self.wakeConsumer(id) }
        }
        timer.cancel()
    }

    private func wakeConsumer(_ id: Int? = nil) {
        guard let waiter = tagWaiter, id == nil || waiter.id == id else { return }
        tagWaiter = nil
        waiter.continuation.resume()
    }

    private func push(_ tag: FLVTag) {
        queue.append(tag)
        bytes += tag.payload.count
        wakeConsumer()
        if isMedia(tag) {
            if firstTimestamp == nil { firstTimestamp = tag.timestamp }
            // A large backward step is a new timeline (publisher restart); restart the maximum there.
            if let last = lastTimestamp, Int64(tag.timestamp) >= Int64(last) - 1000 {
                lastTimestamp = max(last, tag.timestamp)
            } else {
                lastTimestamp = tag.timestamp
            }
        }
    }
    private func isMedia(_ tag: FLVTag) -> Bool {
        tag.payload.count > 1 && tag.payload[1] == 1
    }
    private var seconds: Double {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return Double(max(0, Int64(lastTimestamp) - Int64(firstTimestamp))) / 1000
    }
    func snapshot() -> Snapshot {
        Snapshot(seconds: seconds, bytes: bytes, count: queue.count - cursor,
                 ready: started && (seconds >= Self.targetSeconds || capacityLimited), ended: ended, error: error,
                 firstTimestamp: firstTimestamp, lastTimestamp: lastTimestamp, capacityLimited: capacityLimited)
    }
    func pop() -> FLVTag? {
        guard cursor < queue.count else { return nil }
        let tag = queue[cursor]
        cursor += 1
        bytes -= tag.payload.count
        // Drop consumed payload references promptly; compact once per batch.
        if cursor >= 128 || cursor == queue.count {
            queue.removeFirst(cursor)
            cursor = 0
        }
        firstTimestamp = queue[cursor...].first(where: isMedia)?.timestamp
        if firstTimestamp == nil { lastTimestamp = nil }
        if spaceWaiter != nil, !isFull(adding: pendingBytes),
           seconds <= Self.maximumSeconds - Self.refillMargin || cursor == queue.count {
            wakeProducer()
        }
        return tag
    }
    func finish(_ error: Error?) {
        ended = true
        self.error = error
        wakeProducer()
        wakeConsumer()
    }
}

/// When bytes last arrived from the socket. Read on every consumer iteration,
/// so it avoids an actor hop.
final class LiveReceiptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval?

    func mark() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        last = now
        lock.unlock()
    }

    var lastReceivedAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Producer runs independently of the renderer; EOF/403 is visible while buffered
/// media is still being consumed. A cancelled preparation always closes its socket.
final class BufferedLiveSource: @unchecked Sendable {
    let buffer = LiveTagBuffer()
    let startedAt = ProcessInfo.processInfo.systemUptime
    private let stream: HTTPChunkStream
    private let receipt = LiveReceiptClock()
    private let producer: Task<Void, Never>

    /// nil until the first byte; a silent open socket is detected from this, not from the renderer.
    var lastReceivedAt: TimeInterval? { receipt.lastReceivedAt }

    init(request: URLRequest, diagnosticID: String, configuration: URLSessionConfiguration? = nil) {
        let stream = HTTPChunkStream(diagnosticID: diagnosticID, configuration: configuration)
        self.stream = stream
        let buffer = self.buffer
        let receipt = self.receipt
        producer = Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler {
                defer { stream.cancel() }
                do {
                    var parser = FLVParser()
                    for try await data in stream.start(request: request) {
                        defer { stream.acknowledge() }
                        try Task.checkCancellation()
                        receipt.mark()
                        parser.append(data)
                        while let tag = try parser.nextTag() {
                            // Validate replacement codec configuration before retiring the old source.
                            // Only the two header bytes are read per frame; the body is copied once, by the player.
                            if tag.type == .video, let header = FLVVideoTag.Header(payload: tag.payload) {
                                guard header.isAVC else { throw LivePlayerError.unsupportedCodec }
                                if header.isSequenceHeader {
                                    guard case .sequenceHeader(let record)? = FLVVideoTag(payload: tag.payload)?.packet,
                                          let config = AVCConfig(record: record) else { throw LivePlayerError.unsupportedCodec }
                                    _ = try config.makeFormatDescription()
                                }
                            }
                            try await buffer.append(tag)
                        }
                    }
                    await buffer.finish(nil)
                } catch { await buffer.finish(error) }
            } onCancel: { stream.cancel() }
        }
    }
    func cancel() { producer.cancel(); stream.cancel() }
    deinit { producer.cancel(); stream.cancel() }
}

struct ReadyLiveReplacement: @unchecked Sendable {
    let source: BufferedLiveSource
    let selection: PreparedPlaybackStream
    let minimumSeconds: Double
    init(source: BufferedLiveSource, selection: PreparedPlaybackStream, minimumSeconds: Double = LiveTagBuffer.targetSeconds) {
        self.source = source
        self.selection = selection
        self.minimumSeconds = minimumSeconds
    }
}

actor LiveReplacementMailbox {
    enum Outcome {
        case ready(ReadyLiveReplacement)
        case failed(String)
    }
    private var result: Outcome?
    private var closed = false
    func put(_ value: Outcome) {
        guard !closed else {
            if case .ready(let candidate) = value { candidate.source.cancel() }
            return
        }
        result = value
    }
    func take() -> Outcome? { defer { result = nil }; return result }
    func close() {
        closed = true
        if case .ready(let candidate) = result { candidate.source.cancel() }
        result = nil
    }
}

/// Cancellation must close sockets immediately, even if the rendering task is
/// awaiting an asynchronous flush or the URL resolver has not returned yet.
final class BufferedSourceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [ObjectIdentifier: BufferedLiveSource] = [:]
    private var cancelled = false

    func insert(_ source: BufferedLiveSource) {
        lock.lock()
        let reject = cancelled
        if !reject { sources[ObjectIdentifier(source)] = source }
        lock.unlock()
        if reject { source.cancel() }
    }
    func remove(_ source: BufferedLiveSource) {
        lock.lock()
        sources.removeValue(forKey: ObjectIdentifier(source))
        lock.unlock()
    }
    func cancelAll() {
        lock.lock()
        cancelled = true
        let active = Array(sources.values)
        sources.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }
}
