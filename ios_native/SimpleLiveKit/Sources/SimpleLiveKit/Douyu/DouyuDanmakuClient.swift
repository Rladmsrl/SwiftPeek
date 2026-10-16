import Foundation

/// 斗鱼弹幕连接所需载荷
public struct DouyuDanmakuPayload: LiveSitePayload {
    public let roomID: String

    public init(roomID: String) {
        self.roomID = roomID
    }
}

/// 斗鱼弹幕客户端。
///
/// 协议流程：连接 `wss://danmuproxy.douyu.com:8506` →
/// 发送 `loginreq` + `joingroup` → 每 45 秒发 `mrkl` 心跳。
public actor DouyuDanmakuClient: LiveDanmakuClient {
    private static let endpoint = "wss://danmuproxy.douyu.com:8506"
    private static let backupEndpoint = "wss://danmuproxy.douyu.com:8502"
    private static let heartbeat = Duration.seconds(45)

    private let roomID: String
    private let socket: WebSocketClient
    private let continuation: AsyncStream<DanmakuEvent>.Continuation
    public nonisolated let events: AsyncStream<DanmakuEvent>

    private var pumpTask: Task<Void, Never>?

    public init(roomID: String) throws {
        self.roomID = roomID

        var cont: AsyncStream<DanmakuEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        self.socket = try WebSocketClient(
            url: Self.endpoint,
            backupURL: Self.backupEndpoint,
            heartbeatInterval: Self.heartbeat,
            heartbeatProvider: { DouyuPacket.encode("type@=mrkl/") }
        )
    }

    public func start() async {
        guard pumpTask == nil else { return }
        let stream = socket.events
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await socket.connect()
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        await socket.close()
        continuation.finish()
    }

    // MARK: - 内部

    private func handle(_ event: WebSocketEvent) async {
        switch event {
        case .opened:
            await joinRoom()
            continuation.yield(.ready)
        case .binary(let data):
            decode(data)
        case .text(let text):
            // 斗鱼只走二进制帧，出现文本帧说明协议异常
            continuation.yield(.notice("收到非预期文本帧：\(text.prefix(64))"))
        case .reconnecting(let attempt):
            continuation.yield(.notice("与弹幕服务器断开，正在重连（第 \(attempt) 次）"))
        case .closed(let reason):
            continuation.yield(.closed(reason))
        }
    }

    private func joinRoom() async {
        await socket.send(DouyuPacket.encode("type@=loginreq/roomid@=\(roomID)/"))
        await socket.send(DouyuPacket.encode("type@=joingroup/rid@=\(roomID)/gid@=-9999/"))
    }

    private func decode(_ data: Data) {
        for raw in DouyuPacket.decode(data) {
            let value = DouyuSTT.parse(raw)
            guard let type = value.string("type") else { continue }
            switch type {
            case "chatmsg":
                // dms 缺失的是异常弹幕，Dart 版同样直接丢弃
                guard value.has("dms") else { continue }
                let message = LiveMessage(
                    kind: .chat,
                    userName: value.string("nn") ?? "",
                    message: value.string("txt") ?? "",
                    color: Self.color(for: value.int("col") ?? 0)
                )
                continuation.yield(.message(message))
            default:
                continue
            }
        }
    }

    /// 斗鱼弹幕颜色编号 → RGB，取值与 Dart 版一致
    static func color(for code: Int) -> LiveMessageColor {
        switch code {
        case 1: return LiveMessageColor(255, 0, 0)
        case 2: return LiveMessageColor(30, 135, 240)
        case 3: return LiveMessageColor(122, 200, 75)
        case 4: return LiveMessageColor(255, 127, 0)
        case 5: return LiveMessageColor(155, 57, 244)
        case 6: return LiveMessageColor(255, 105, 180)
        default: return .white
        }
    }
}
