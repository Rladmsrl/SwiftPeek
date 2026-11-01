import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("弹幕连接重连")
struct WebSocketReconnectTests {
    @Test("指数退避到 30 秒封顶，不设次数上限")
    func backoffWithoutCap() {
        let delays = (1...8).map { WebSocketClient.reconnectDelay(attempt: $0) }
        #expect(delays == [2, 4, 8, 16, 30, 30, 30, 30].map { Duration.seconds($0) })
        #expect(WebSocketClient.reconnectDelay(attempt: 10_000) == .seconds(30))
        // 断网半分钟（原先 5 次 × 5 秒就放弃）后仍在退避而不是关闭
        let firstMinute = (1...5).map { WebSocketClient.reconnectDelay(attempt: $0) }.reduce(Duration.zero, +)
        #expect(firstMinute == .seconds(60))
    }

    @Test("超过两个心跳周期没有帧才算半开")
    func silenceDeadline() {
        let now = ContinuousClock.now
        let heartbeat = Duration.seconds(45)
        #expect(!WebSocketClient.isSilent(since: now - .seconds(45), now: now, heartbeat: heartbeat))
        #expect(!WebSocketClient.isSilent(since: now - .seconds(89), now: now, heartbeat: heartbeat))
        #expect(WebSocketClient.isSilent(since: now - .seconds(91), now: now, heartbeat: heartbeat))
    }

    @Test("关闭后不再连接，也不抛出")
    func closedClientStaysClosed() async throws {
        let client = try WebSocketClient(url: "wss://example.invalid/", heartbeatInterval: .seconds(45), heartbeatProvider: { nil })
        await client.close()
        await client.connect()
        #expect(await client.status == .closed)
        // 事件流已结束
        var count = 0
        let events = await client.events
        for await _ in events { count += 1 }
        #expect(count == 0)
    }
}
