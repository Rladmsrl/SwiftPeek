import Foundation
import Network

/// WebSocket 事件
public enum WebSocketEvent: Sendable {
    /// 已发起连接，可以发送握手包。是否真正连通要看之后有没有收到帧。
    case opened
    case binary(Data)
    case text(String)
    /// 正在重连，附带第几次
    case reconnecting(Int)
    case closed(String)
}

/// 对应 Dart 版 `WebScoketUtils`：连接、心跳、自动重连。
///
/// 相比 Dart 版的改进：
/// 1. 用 `AsyncStream` 取代多个可选闭包，消费端可以用 `for await` 线性处理；
/// 2. 重连使用一次性延迟任务而非 `Timer.periodic`，避免 Dart 版里
///    重连定时器只创建一次、后续 5 秒无条件反复触发的问题；
/// 3. 重连不设总次数上限，按指数退避（最长 30 秒）。原先 5 次 × 5 秒用完就永久断开，
///    手机进电梯、地铁断网半分钟，视频能续上而弹幕再也回不来；
/// 4. 网络恢复时立即重连；超过两个心跳周期没收到任何帧视为半开连接，主动重建。
public actor WebSocketClient {
    public enum Status: Sendable {
        case idle, connected, closed, failed
    }

    /// 退避上限
    static let maximumReconnectDelay = 30

    private let url: URL
    private let backupURL: URL?
    private let heartbeatInterval: Duration
    private let headers: [String: String]
    /// nil 表示不限次数。只给测试或一次性工具用。
    private let maxReconnectAttempts: Int?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied = true

    private var reconnectAttempts = 0
    private var usedBackup = false
    private var lastFrameAt = ContinuousClock.now
    public private(set) var status: Status = .idle

    private let continuation: AsyncStream<WebSocketEvent>.Continuation
    public let events: AsyncStream<WebSocketEvent>

    /// 心跳回调：由上层站点决定心跳包内容
    private let heartbeatProvider: @Sendable () -> Data?

    private static let pathQueue = DispatchQueue(label: "SimpleLiveKit.WebSocketClient.path")

    public init(
        url: String,
        backupURL: String? = nil,
        heartbeatInterval: Duration,
        headers: [String: String] = [:],
        maxReconnectAttempts: Int? = nil,
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

    /// 第 n 次重连前的等待：2、4、8、16 秒，之后固定 30 秒，不设次数上限。
    static func reconnectDelay(attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 4)
        return .seconds(min(maximumReconnectDelay, 2 << exponent))
    }

    /// 超过两个心跳周期没有任何帧：连接很可能已经半开（换网、NAT 超时），`receive()` 不会报错。
    static func isSilent(since lastFrame: ContinuousClock.Instant, now: ContinuousClock.Instant, heartbeat: Duration) -> Bool {
        now - lastFrame > heartbeat * 2
    }

    public func connect() {
        // close() 之后会话已失效，不能再从它创建任务
        guard status != .closed else { return }
        teardownConnection()
        startPathMonitorIfNeeded()

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
        lastFrameAt = .now
        // 不在这里清零重连次数。握手还没证明成功，清零会让
        // 「发起连接 → 立刻失败 → 计数回到 0」的退避永远停在最短间隔。
        // 收到一帧数据才在 ingest 里清零。
        continuation.yield(.opened)

        startReceiveLoop(socket)
        startHeartbeat(socket)
    }

    private func startReceiveLoop(_ socket: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    await self.ingest(message, from: socket)
                } catch {
                    // 被 teardown 取消的旧连接不能把新连接判为失败
                    guard let self, !Task.isCancelled else { return }
                    await self.handleFailure(error, from: socket)
                    return
                }
            }
        }
    }

    /// 收到一帧才算连接真正建立，此时才清零退避。
    private func ingest(_ message: URLSessionWebSocketTask.Message, from socket: URLSessionWebSocketTask) {
        guard socket === task else { return }
        reconnectAttempts = 0
        lastFrameAt = .now
        switch message {
        case .data(let data):
            continuation.yield(.binary(data))
        case .string(let text):
            continuation.yield(.text(text))
        @unknown default:
            break
        }
    }

    private func startHeartbeat(_ socket: URLSessionWebSocketTask) {
        let interval = heartbeatInterval
        heartbeatLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.heartbeatTick(socket)
            }
        }
    }

    private func heartbeatTick(_ socket: URLSessionWebSocketTask) async {
        guard socket === task, status == .connected else { return }
        if Self.isSilent(since: lastFrameAt, now: .now, heartbeat: heartbeatInterval) {
            handleFailure(LiveCoreError("弹幕服务器长时间无响应"), from: socket)
            return
        }
        // 协议层 ping：服务器不回应用层心跳时，pong 也能证明连接还活着，
        // 安静的房间不会因为没有弹幕被误判为半开而反复重连。
        socket.sendPing { [weak self] error in
            guard error == nil else { return }
            Task { await self?.markAlive(socket) }
        }
        guard let payload = heartbeatProvider() else { return }
        await send(payload)
    }

    private func markAlive(_ socket: URLSessionWebSocketTask) {
        guard socket === task else { return }
        lastFrameAt = .now
    }

    public func send(_ data: Data) async {
        guard status == .connected, let task else { return }
        do {
            try await task.send(.data(data))
        } catch {
            handleFailure(error, from: task)
        }
    }

    private func handleFailure(_ error: any Error, from socket: URLSessionWebSocketTask) {
        guard status == .connected, socket === task else { return }
        status = .failed
        teardownConnection()
        scheduleReconnect(reason: error.localizedDescription)
    }

    private func scheduleReconnect(reason: String) {
        if let maxReconnectAttempts, reconnectAttempts >= maxReconnectAttempts {
            continuation.yield(.closed("重连超过最大次数（\(maxReconnectAttempts) 次），已断开：\(reason)"))
            close()
            return
        }
        reconnectAttempts += 1
        // 主备地址轮流尝试：某一个端口被网络环境挡住时不会一直撞同一个
        if backupURL != nil { usedBackup.toggle() }
        let attempt = reconnectAttempts
        let delay = Self.reconnectDelay(attempt: attempt)
        continuation.yield(.reconnecting(attempt))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.reconnectNow()
        }
    }

    private func reconnectNow() {
        guard status == .failed else { return }
        reconnectTask = nil
        connect()
    }

    // MARK: 网络路径

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: Self.pathQueue)
        pathMonitor = monitor
    }

    /// 网络从不可用恢复：不等退避，立即用满额预算重连。
    /// 断网前建立的连接多半已经半开，同样重建。
    private func pathChanged(satisfied: Bool) {
        let recovered = satisfied && !pathSatisfied
        pathSatisfied = satisfied
        guard recovered, status == .connected || status == .failed else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .failed
        teardownConnection()
        connect()
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
        guard status != .closed else { return }
        status = .closed
        reconnectTask?.cancel()
        reconnectTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        teardownConnection()
        // 每个客户端一个会话，不失效就一直留着
        session.invalidateAndCancel()
        continuation.finish()
    }
}
