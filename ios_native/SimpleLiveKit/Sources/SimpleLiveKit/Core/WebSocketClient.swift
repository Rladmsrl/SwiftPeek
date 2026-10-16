import Foundation

/// WebSocket 事件
public enum WebSocketEvent: Sendable {
    case opened
    case binary(Data)
    case text(String)
    /// 正在重连，附带第几次
    case reconnecting(Int)
    case closed(String)
}

/// 对应 Dart 版 `WebScoketUtils`：连接、心跳、有限次重连。
///
/// 相比 Dart 版做了两处改进：
/// 1. 用 `AsyncStream` 取代多个可选闭包，消费端可以用 `for await` 线性处理；
/// 2. 重连使用一次性延迟任务而非 `Timer.periodic`，避免 Dart 版里
///    重连定时器只创建一次、后续 5 秒无条件反复触发的问题。
public actor WebSocketClient {
    public enum Status: Sendable {
        case idle, connected, closed, failed
    }

    private let url: URL
    private let backupURL: URL?
    private let heartbeatInterval: Duration
    private let headers: [String: String]
    private let maxReconnectAttempts: Int

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var reconnectAttempts = 0
    private var usedBackup = false
    public private(set) var status: Status = .idle

    private let continuation: AsyncStream<WebSocketEvent>.Continuation
    public let events: AsyncStream<WebSocketEvent>

    /// 心跳回调：由上层站点决定心跳包内容
    private let heartbeatProvider: @Sendable () -> Data?

    public init(
        url: String,
        backupURL: String? = nil,
        heartbeatInterval: Duration,
        headers: [String: String] = [:],
        maxReconnectAttempts: Int = 5,
        heartbeatProvider: @escaping @Sendable () -> Data?
    ) throws {
        guard let parsed = URL(string: url) else {
            throw LiveCoreError("非法 WebSocket 地址：\(url)")
        }
        self.url = parsed
        self.backupURL = backupURL.flatMap(URL.init(string:))
        self.heartbeatInterval = heartbeatInterval
        self.headers = headers
        self.maxReconnectAttempts = maxReconnectAttempts
        self.heartbeatProvider = heartbeatProvider

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)

        var cont: AsyncStream<WebSocketEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.continuation = cont
    }

    public func connect() {
        teardownConnection()

        let target = (usedBackup ? backupURL : nil) ?? url
        var request = URLRequest(url: target)
        request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        status = .connected
        // 不在这里清零重连次数。握手还没证明成功，清零会让
        // 「发起连接 → 立刻失败 → 计数回到 0」永远到不了上限。
        // 收到一帧数据才在 ingest 里清零。
        continuation.yield(.opened)

        startReceiveLoop(socket)
        startHeartbeat()
    }

    private func startReceiveLoop(_ socket: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    await self.ingest(message)
                } catch {
                    guard let self else { return }
                    await self.handleFailure(error)
                    return
                }
            }
        }
    }

    /// 收到一帧才算连接真正建立。原实现在 `connect()` 里把计数清零，
    /// 于是每次重连都从 0 开始，`maxReconnectAttempts` 不会生效。
    private func ingest(_ message: URLSessionWebSocketTask.Message) {
        reconnectAttempts = 0
        switch message {
        case .data(let data):
            continuation.yield(.binary(data))
        case .string(let text):
            continuation.yield(.text(text))
        @unknown default:
            break
        }
    }

    private func startHeartbeat() {
        let interval = heartbeatInterval
        heartbeatLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard let payload = heartbeatProvider() else { return }
        await send(payload)
    }

    public func send(_ data: Data) async {
        guard status == .connected, let task else { return }
        do {
            try await task.send(.data(data))
        } catch {
            await handleFailure(error)
        }
    }

    private func handleFailure(_ error: any Error) async {
        guard status == .connected else { return }
        status = .failed
        teardownConnection()
        scheduleReconnect(reason: error.localizedDescription)
    }

    private func scheduleReconnect(reason: String) {
        guard reconnectAttempts < maxReconnectAttempts else {
            continuation.yield(.closed("重连超过最大次数（\(maxReconnectAttempts) 次），已断开：\(reason)"))
            continuation.finish()
            status = .closed
            return
        }
        reconnectAttempts += 1
        // 首次失败切备用地址，之后固定 5 秒退避
        if backupURL != nil && !usedBackup {
            usedBackup = true
        }
        let attempt = reconnectAttempts
        continuation.yield(.reconnecting(attempt))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            await self.connect()
        }
    }

    private func teardownConnection() {
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func close() {
        status = .closed
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownConnection()
        continuation.finish()
    }
}
