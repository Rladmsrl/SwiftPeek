import Foundation
import SimpleLiveKit
import CoreMedia

final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.path == "/403" ? 403 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if status == 403 { client?.urlProtocolDidFinishLoading(self) }
        // /waiting intentionally provides no bytes: cancellation must close it.
    }
    override func stopLoading() {}
}

@main
struct BufferedPlaybackCheck {
    static func tag(_ ms: UInt32, key: Bool = false, header: Bool = false, bytes: Int = 5) -> FLVTag {
        var data = Data([key || header ? 0x17 : 0x27, header ? 0 : 1, 0, 0, 0])
        if bytes > data.count { data.append(Data(repeating: 0, count: bytes - data.count)) }
        return FLVTag(type: .video, timestamp: ms, payload: data)
    }
    static func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return config
    }
    static func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Offline fixture timed out")
    }
    static func main() async throws {
        let buffer = LiveTagBuffer()
        try await buffer.append(tag(0)) // no keyframe or sequence header
        let empty = await buffer.snapshot()
        precondition(empty.count == 0 && !empty.ready)
        try await buffer.append(tag(0, header: true))
        try await buffer.append(tag(0, key: true))
        for i in 1...3 { try await buffer.append(tag(UInt32(i * 1000))) }
        let short = await buffer.snapshot()
        precondition(!short.ready)
        try await buffer.append(tag(4000))
        let ready = await buffer.snapshot()
        precondition(ready.ready && ready.seconds == 4)
        await buffer.finish(LiveHTTPError(status: 403))
        var delivered = 0
        while await buffer.pop() != nil { delivered += 1 }
        precondition(delivered == 6, "A 403/EOF discarded playable buffered media")
        print("PASS: start at a keyframe with 4 seconds; EOF preserves all buffered tags")

        let bounded = LiveTagBuffer()
        try await bounded.append(tag(0, header: true))
        try await bounded.append(tag(0, key: true))
        for i in 1...8 { try await bounded.append(tag(UInt32(i * 1000))) }
        let producer = Task { try await bounded.append(tag(9000)) }
        try await Task.sleep(for: .milliseconds(50))
        let full = await bounded.snapshot()
        precondition(full.seconds == 8 && full.bytes <= LiveTagBuffer.maximumBytes)
        producer.cancel()
        do { try await producer.value; fatalError("Cancelled buffer append completed") }
        catch is CancellationError {}
        print("PASS: buffer duration is bounded and a blocked producer is cancellable")

        let highBitrate = LiveTagBuffer()
        try await highBitrate.append(tag(0, header: true))
        try await highBitrate.append(tag(0, key: true, bytes: 9 * 1024 * 1024))
        let limited = Task { try await highBitrate.append(tag(1000, bytes: 9 * 1024 * 1024)) }
        try await waitFor { await highBitrate.snapshot().ready }
        let limitedSnapshot = await highBitrate.snapshot()
        precondition(limitedSnapshot.bytes <= LiveTagBuffer.maximumBytes && limitedSnapshot.seconds < 4)
        limited.cancel()
        _ = try? await limited.value
        print("PASS: memory cap starts with less buffer instead of deadlocking on 4-second target")

        let expired = BufferedLiveSource(request: URLRequest(url: URL(string: "https://fixture.invalid/403")!),
                                         diagnosticID: "fixture", configuration: config())
        try await waitFor { await expired.buffer.snapshot().ended }
        let denied = await expired.buffer.snapshot()
        precondition((denied.error as? LiveHTTPError)?.requiresFreshURL == true)
        expired.cancel()
        let waiting = BufferedLiveSource(request: URLRequest(url: URL(string: "https://fixture.invalid/waiting")!),
                                         diagnosticID: "fixture", configuration: config())
        let mailbox = LiveReplacementMailbox()
        await mailbox.close()
        let selection = PreparedPlaybackStream(stream: LivePlayURL(urls: ["https://fixture.invalid/waiting"]), lineIndex: 0, qualityName: "fixture")
        await mailbox.put(.ready(ReadyLiveReplacement(source: waiting, selection: selection)))
        try await waitFor { await waiting.buffer.snapshot().ended }
        let late = await mailbox.take()
        precondition(late == nil)
        print("PASS: real HTTP callback classifies 403; cancelled handoff closes late replacement socket")
        let registry = BufferedSourceRegistry()
        let active = BufferedLiveSource(request: URLRequest(url: URL(string: "https://fixture.invalid/waiting")!),
                                        diagnosticID: "active", configuration: config())
        registry.insert(active)
        registry.cancelAll()
        let lateSource = BufferedLiveSource(request: URLRequest(url: URL(string: "https://fixture.invalid/waiting")!),
                                            diagnosticID: "late", configuration: config())
        registry.insert(lateSource)
        try await waitFor { await active.buffer.snapshot().ended }
        try await waitFor { await lateSource.buffer.snapshot().ended }
        print("PASS: stop cancels both registered sockets and sources arriving after cancellation")

        var policy = LiveHandoffPolicy()
        precondition(!policy.begin(now: 239, sourceAge: 239, ended: false, stalled: false))
        precondition(policy.begin(now: 240, sourceAge: 240, ended: false, stalled: false))
        policy.failed(at: 240)
        precondition(!policy.begin(now: 240.5, sourceAge: 240.5, ended: true, stalled: false))
        precondition(policy.begin(now: 241, sourceAge: 241, ended: true, stalled: false))
        policy.failed(at: 241)
        precondition(policy.begin(now: 243, sourceAge: 243, ended: true, stalled: false))
        policy.failed(at: 243)
        precondition(!policy.begin(now: 300, sourceAge: 300, ended: true, stalled: false))
        policy.stablePlayback()
        precondition(policy.begin(now: 301, sourceAge: 301, ended: true, stalled: false))
        var immediate = LiveHandoffPolicy()
        precondition(immediate.begin(now: 1, sourceAge: 1, ended: true, stalled: false))
        print("PASS: proactive 240-second refresh, immediate EOF/403 recovery, bounded retry backoff")
        for seconds in [1.0, 240.0, 300.0, 3600.0] {
            let end = CMTime(seconds: seconds + 0.8, preferredTimescale: 1000)
            let clock = CMTime(seconds: seconds, preferredTimescale: 1000)
            let offset = LiveHandoffTimeline.continuationOffset(end: end, clock: clock)
            precondition(offset >= end && offset > clock)
            let starved = LiveHandoffTimeline.continuationOffset(end: clock, clock: end)
            precondition(starved > end)
        }
        print("PASS: replacement timestamps follow old queued media without resetting the clock")
    }
}
