import AVFoundation
import CoreMedia
import Observation
import SwiftUI
import SimpleLiveKit
#if os(macOS)
import AppKit
#endif

/// 纯 Apple 框架实现的 HTTP-FLV 直播播放器。
///
/// 背景：斗鱼只下发 HTTP-FLV（`xxx.flv?wsAuth=...`），AVPlayer 完全不支持该容器，
/// 因此不能直接用 AVPlayer / AVPlayerItem。
///
/// 这里自己完成 FLV 解复用，把 H.264 NALU 与 AAC 帧封装成 CMSampleBuffer，
/// 交给 AVSampleBufferDisplayLayer（VideoToolbox 硬解）与 AVSampleBufferAudioRenderer，
/// 由 AVSampleBufferRenderSynchronizer 统一音视频时钟。
///
/// 相比引入 FFmpeg（KSPlayer / ijkplayer）的收益：无 LGPL/GPL 授权问题、
/// 不增加数百 MB 二进制、全程硬解省电。代价是只覆盖 H.264 + AAC，
/// 遇到 HEVC 流需要另行扩展。
@Observable
final class FLVLivePlayer {
    enum State: Equatable {
        case idle
        case connecting
        case buffering
        case playing
        /// 连接中断，正在自动重连。`attempt` 从 1 开始，仅用于提示文案。
        case reconnecting(attempt: Int)
        case failed(String)
    }

    /// 一次拉流尝试的结束原因，决定后续是重试、换地址还是放弃。
    private enum Recovery {
        /// 瞬时中断，同一地址重试即可
        case retrySameURL(reason: String)
        /// 地址或时效票已失效，必须重新取流地址
        case needFreshURL(reason: String)
        /// 重试没有意义（编解码不支持等）
        case giveUp(reason: String)
        /// 用户主动停止
        case cancelled
    }

    // MARK: 可观察状态

    var state: State = .idle {
        didSet {
            if state != oldValue {
                LiveDiagnostics.record("player.state", fields: ["player": diagnosticID, "state": String(describing: state)])
            }
        }
    }
    #if os(macOS)
    /// The display layer has exactly one geometry owner at a time.
    var isInFloatingWindow = false
    #endif
    let diagnosticID = UUID().uuidString
    var videoSize: CGSize?
    var receivedBytes = 0
    var bufferedSeconds: Double = 0
    var bufferedBytes = 0
    var isRenewingStream = false
    var onPrepareStream: (@MainActor (Bool) async throws -> PreparedPlaybackStream)?
    var onCommitStream: (@MainActor (PreparedPlaybackStream) -> Void)?
    var isMuted = false {
        didSet { audioRenderer.isMuted = isMuted }
    }

    /// 播放器音量 0...1。
    ///
    /// 走渲染器自身音量，而不是去改系统音量：后者在 iOS 上没有公开可写 API，
    /// 社区惯用的 MPVolumeView 隐藏 slider 依赖私有视图层级，不可靠。
    var volume: Double = 1.0 {
        didSet {
            let clamped = min(max(volume, 0), 1)
            if clamped != volume {
                volume = clamped  // 触发再次 didSet，下一轮写入渲染器
                return
            }
            audioRenderer.volume = Float(clamped)
        }
    }

    /// 画面填充模式。全屏下允许在「适应」与「填充」之间切换。
    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { displayLayer.videoGravity = videoGravity }
    }

    // MARK: 渲染管线

    /// 可从任意线程 enqueue，我们的解复用循环是串行的
    let displayLayer = AVSampleBufferDisplayLayer()
    #if os(iOS)
    @ObservationIgnored let pipFrames = PiPLiveFrameSource()
    func pictureInPictureFrame() -> CVPixelBuffer? { pipFrames.frame(at: synchronizer.currentTime()) }
    #endif
    let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    /// iOS 18 起图层自身的 enqueue/flush/status 均已废弃，
    /// 统一改用 displayLayer.sampleBufferRenderer
    private var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var streamTask: Task<Void, Never>?
    /// 当前这次拉流。stop() 要能立刻掐掉 socket，不能干等下一个数据块。
    @ObservationIgnored private let streamLock = NSLock()
    @ObservationIgnored private var activeStream: HTTPChunkStream?

    // MARK: 自动重连
    //
    // 直播断流在手机上是常态：切 WiFi / 蜂窝、基站切换、CDN 节点轮换都会断。
    // 分两层处理：
    //   1. 本类内部用同一地址快速重试，覆盖瞬时的连接中断；
    //   2. 同址重试用尽后回调 onNeedsFreshStream，由房间层重新取流——
    //      斗鱼 FLV 地址带 wsAuth 时效票，票据过期后同址重试永远不会成功，
    //      而播放器本身不认识站点，拿不到新地址。

    /// 由房间层注入：同址重试用尽时调用，实现方需重新取流并调用 `resume(url:headers:)`
    var onNeedsFreshStream: (@MainActor () -> Void)?

    /// 仅稳定播放 30 秒或用户主动重新播放时重置，不因首帧到达清零。
    @MainActor private var recoveryPolicy = PlaybackRecoveryPolicy()

    @ObservationIgnored private let generationGate = PlaybackGenerationGate()
    @MainActor private let flushQueue = PlaybackFlushQueue()

    /// Confined to one pull task. MainActor helpers only access it while that task
    /// is suspended awaiting them; teardown never touches an old decode context.
    private final class DecodeContext {
        var videoFormat: CMVideoFormatDescription?
        var audioFormat: CMAudioFormatDescription?
        /// AAC 实际采样率，用于计算每包时长（斗鱼有 48kHz 流，硬编码 44.1k 会导致音画漂移）
        var audioSampleRate: Double = 44100
        /// 音频时间轴以「首帧容器时间 + 已排队帧数 × 1024 采样」生成。
        /// FLV 时间戳只有毫秒，而 AAC 帧长是 1024/采样率（48kHz 为 21.333ms，
        /// 44.1kHz 为 23.220ms），对不齐。AVSampleBufferAudioRenderer 严格按 PTS 排程，
        /// 每帧零点几毫秒的缝或重叠在真机上就是持续卡顿；模拟器音频栈会把这种缝补平。
        var audioTimelineAnchor: CMTime?
        var audioFramesQueued: Int64 = 0
        /// 上一帧的容器时间戳，只用来识别突然的跳变（断流拼接），不拿来当 PTS
        var lastAudioContainerPTS: CMTime?
        /// 首个 tag 时间戳，用于把直播流时间轴重置到 0
        var timestampBase: UInt32?
        var didStartClock = false
        var didReceiveKeyframe = false
        var continuous = false
        var clockNeedsResume = false
        var timeOffset: CMTime = .zero
        var lastQueuedEnd: CMTime = .zero

        func resetAudioTimeline() {
            audioTimelineAnchor = nil
            audioFramesQueued = 0
            lastAudioContainerPTS = nil
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generationGate.isCurrent(generation)
    }

    private static let timescale: CMTimeScale = 1000

    init() {
        displayLayer.videoGravity = .resizeAspect
        // 直播恒为 1 倍速。默认的 timeDomain 算法会做时域拉伸，
        // 真机上会把微小的时间误差放大成爆音和卡顿；varispeed 在 1 倍速是直通。
        audioRenderer.audioTimePitchAlgorithm = .varispeed
        // 这个开关为 true 时，要等音视频都“缓冲够了”时钟才真正跑。
        // 直播 CDN 会先突发一两秒数据，视频队列先满、时钟仍是 0，排空不了，
        // 只能 resync，画面就停在第一帧直到下一个关键帧——开播卡几秒就是这个。
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    /// 兜底：视图被销毁而没走到 stop() 时（例如深链直接替换了房间），
    /// 至少要把拉流任务取消，不能留一个还在下行的孤儿播放器。
    deinit {
        cancelActiveStream()
        streamTask?.cancel()
    }

    /// 是否正在拉流、播放或重连。用于避免重复 start——
    /// 切 Tab 回来时 `.task` 会重跑一次，重连过程中也不该被打断重来。
    var isActive: Bool {
        switch state {
        case .playing, .buffering, .connecting, .reconnecting: return true
        case .idle, .failed: return false
        }
    }

    /// 是否正在自动重连，供 UI 决定显示重连提示而不是错误页。
    var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    // MARK: - 生命周期

    /// 用户主动起播。会重置重连预算。
    @MainActor
    func start(url: String, headers: [String: String]?) {
        teardown(removingImage: true)
        recoveryPolicy = PlaybackRecoveryPolicy()
        launch(url: url, headers: headers)
    }

    /// 重连时用新取到的地址续播。
    ///
    /// 与 `start` 有两点区别：**不重置重连预算**——否则「取新址 → 失败 → 再取新址」
    /// 会变成无限循环，永远走不到放弃分支；以及**保留最后一帧画面**，
    /// 让重连过程表现为画面定格而不是黑屏闪烁。
    @MainActor
    func resume(url: String, headers: [String: String]?) {
        teardown(removingImage: false)
        launch(url: url, headers: headers)
    }

    @MainActor
    private func launch(url: String, headers: [String: String]?) {
        guard let target = URL(string: url) else {
            state = .failed("播放地址非法")
            return
        }

        state = .connecting
        LiveDiagnostics.record("player.connect", fields: ["player": diagnosticID, "host": target.host ?? "unknown"])
        configureAudioSession()
        resetAttemptPresentation()

        var request = URLRequest(url: target)
        request.timeoutInterval = 15
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let generation = generationGate.current
        let buffered = onPrepareStream != nil
        let flush = flushQueue.tail
        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            await flush?.value
            if buffered { await self?.runBufferedPlayback(request: request, generation: generation) }
            else { await self?.runWithReconnect(request: request, generation: generation) }
        }
    }

    @MainActor
    func stop() {
        teardown(removingImage: true)
        recoveryPolicy = PlaybackRecoveryPolicy()
        state = .idle
        deactivateAudioSession()
    }

    /// 重连兜底失败：房间层取不到新地址（例如主播已下播）时调用，结束重连并给出原因。
    @MainActor
    func abortReconnect(reason: String) {
        teardown(removingImage: true)
        state = .failed(reason)
        deactivateAudioSession()
    }

    #if DEBUG
    /// 仅用于验证自动重连：请求接下来的 `count` 次连接各自在首个数据块处断开。
    ///
    /// 伪造的是 `URLError.networkConnectionLost`，走与真实断网完全相同的
    /// `Recovery` 判定路径（→ `retrySameURL`），因此验证到的是真实逻辑，
    /// 而不是另开的一条测试分支。给 >1 的次数可以把「同址重试用尽 →
    /// 向房间层索要新地址」的升级路径也走一遍。
    @MainActor
    func simulateStreamDrops(_ count: Int = 1) {
        dropBudget = count
    }

    private var dropBudget = 0
    #endif

    /// 诊断用：渲染管线还能不能吃数据、同步器时钟是否在走。
    /// 排查「状态仍是 playing 但字节数不再增长」这类静默停滞。
    var pipelineDiagnostics: String {
        let video = videoRenderer.isReadyForMoreMediaData
        let audio = audioRenderer.isReadyForMoreMediaData
        let clock = synchronizer.currentTime().seconds
        let statusText: String
        switch videoRenderer.status {
        case .unknown: statusText = "unknown"
        case .rendering: statusText = "rendering"
        case .failed: statusText = "failed(\(videoRenderer.error?.localizedDescription ?? "?"))"
        @unknown default: statusText = "other"
        }
        return "vRdy=\(video) aRdy=\(audio) "
            + "clock=\(String(format: "%.1f", clock)) rate=\(synchronizer.rate.description) "
            + "vStatus=\(statusText) resync=\(resyncCount.description) "
            + "size=\(videoSize.map { "\(Int($0.width).description)x\(Int($0.height).description)" } ?? "-")"
    }

    /// 拆掉当前拉流与渲染状态，但不改 `state`、不动重连预算。
    @MainActor
    private func teardown(removingImage: Bool) {
        // Invalidate under the render lock before flushing or starting another stream.
        _ = generationGate.advance()
        // 先掐 socket，再取消任务。只取消 Task 的话，for-await 会停在下一个
        // 数据块上，断网时要空等请求超时。
        cancelActiveStream()
        streamTask?.cancel()
        streamTask = nil
        resetRenderPipeline(removingImage: removingImage)
        resetAttemptPresentation()
        bufferedSeconds = 0
        bufferedBytes = 0
        isRenewingStream = false
    }

    private func adopt(stream: HTTPChunkStream) {
        streamLock.lock()
        activeStream = stream
        streamLock.unlock()
    }

    private func release(stream: HTTPChunkStream) {
        streamLock.lock()
        if activeStream === stream {
            activeStream = nil
        }
        streamLock.unlock()
        stream.cancel()
    }

    private func cancelActiveStream() {
        streamLock.lock()
        let stream = activeStream
        streamLock.unlock()
        stream?.cancel()
    }

    /// 重置渲染管线时钟。
    ///
    /// 重连必须做这件事：新连接的 FLV 时间戳会被重新基准化到 0，
    /// 而同步器时钟已经走到了断流那一刻。若不把时钟归零，
    /// 新样本的 PTS 全部落在「过去」，会被直接丢弃 —— 画面永远不恢复。
    @MainActor
    private func resetRenderPipeline(removingImage: Bool) {
        synchronizer.setRate(0, time: .zero)
        scheduleVideoFlush(removingImage: removingImage)
        audioRenderer.flush()
    }

    @MainActor
    @discardableResult
    private func scheduleVideoFlush(removingImage: Bool) -> Task<Void, Never> {
        let renderer = videoRenderer
        return flushQueue.enqueue {
            await withCheckedContinuation { continuation in
                renderer.flush(removingDisplayedImage: removingImage) { continuation.resume() }
            }
        }
    }

    @MainActor
    private func resetAttemptPresentation() {
        recoveryPolicy.beginAttempt()
        receivedBytes = 0
        videoSize = nil
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // 直播场景：后台可继续出声，且不打断他人音频时混音
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // 音频会话失败不应阻塞视频播放，仅记录
            print("[FLVLivePlayer] 音频会话配置失败：\(error.localizedDescription)")
        }
        #endif
    }

    /// 离开播放（用户停止、重连放弃）时把音频会话还回去，否则其他 App 会一直被压声。
    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - 拉流主循环

    /// 包一层自动重连：反复调用 `pump`，按结束原因决定重试、换地址还是放弃。
    private func runWithReconnect(request: URLRequest, generation: UInt64) async {
        while isCurrent(generation) {
            let recovery = await pump(request: request, generation: generation)
            guard isCurrent(generation) else { return }
            LiveDiagnostics.record("player.streamEnded", fields: ["player": diagnosticID, "recovery": String(describing: recovery), "attempt": String(await currentRetryAttempt())])

            switch recovery {
            case .cancelled:
                return

            case .giveUp(let reason):
                await setState(.failed(reason), generation: generation)
                await MainActor.run { if self.isCurrent(generation) { self.deactivateAudioSession() } }
                return

            case .needFreshURL(let reason):
                await requestFreshStream(reason: reason, generation: generation)
                return

            case .retrySameURL(let reason):
                guard let sameURLAttempt = await nextSameURLAttempt(generation: generation) else {
                    await requestFreshStream(reason: reason, generation: generation)
                    return
                }
                await setState(.reconnecting(attempt: sameURLAttempt), generation: generation)
                await resetForRetry(generation: generation)

                // 退避 1s、2s。sleep 可被取消，用户退出房间时立刻结束。
                let backoff = Duration.seconds(1 << (sameURLAttempt - 1))
                do {
                    try await Task.sleep(for: backoff)
                } catch {
                    return
                }
            }
        }
    }

    /// 同址重试用尽，回调房间层重新取流地址；预算也用尽则直接失败。
    @MainActor
    private func requestFreshStream(reason: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        guard let onNeedsFreshStream,
              let cycle = recoveryPolicy.nextFreshStreamCycle() else {
            state = .failed("\(reason)，重连多次仍未成功")
            deactivateAudioSession()
            return
        }
        state = .reconnecting(attempt: PlaybackRecoveryPolicy.maxSameURLAttempts + cycle)
        onNeedsFreshStream()
    }

    @MainActor
    private func currentRetryAttempt() -> Int { recoveryPolicy.sameURLAttempts }

    @MainActor
    private func nextSameURLAttempt(generation: UInt64) -> Int? {
        guard isCurrent(generation) else { return nil }
        let attempt = recoveryPolicy.nextSameURLAttempt(at: ProcessInfo.processInfo.systemUptime)
        LiveDiagnostics.record("player.recoveryBudget", fields: [
            "player": diagnosticID, "sameURLAttempts": String(recoveryPolicy.sameURLAttempts),
            "freshStreamCycles": String(recoveryPolicy.freshStreamCycles), "needsFreshURL": String(attempt == nil),
        ])
        return attempt
    }

    @MainActor
    private func resetForRetry(generation: UInt64) async {
        guard isCurrent(generation) else { return }
        resetRenderPipeline(removingImage: false)
        await flushQueue.tail?.value
        guard isCurrent(generation) else { return }
        resetAttemptPresentation()
    }

    /// 单次拉流尝试。返回结束原因，不直接改成 `.failed`——
    /// 是否算最终失败由 `runWithReconnect` 统一裁决。
    private func pump(request: URLRequest, generation: UInt64) async -> Recovery {
        if !isCurrent(generation) { return .cancelled }
        let stream = HTTPChunkStream(diagnosticID: diagnosticID)
        guard generationGate.withCurrent(generation, { adopt(stream: stream); return true }) == true else {
            stream.cancel()
            return .cancelled
        }
        return await withTaskCancellationHandler {
            defer { release(stream: stream) }
            return await pull(stream, request: request, generation: generation)
        } onCancel: {
            stream.cancel()
        }
    }

    private func pull(_ stream: HTTPChunkStream, request: URLRequest, generation: UInt64) async -> Recovery {
        var parser = FLVParser()
        let context = DecodeContext()

        do {
            await setState(.buffering, generation: generation)
            // 字节计数只给诊断用。每块都跳主线程会把解复用拖在 UI 后面，
            // 音频样本迟到就会被渲染器丢掉，真机上听感就是声音卡。
            var unpublished = 0
            for try await chunk in stream.start(request: request) {
                // 无论中途成功还是抛错，都要把名额还给接收器，否则 delegate 队列会堵死
                defer { stream.acknowledge() }
                if !isCurrent(generation) { return .cancelled }
                parser.append(chunk)
                unpublished += chunk.count
                if unpublished >= 64 * 1024 {
                    let count = unpublished
                    unpublished = 0
                    if await publishReceived(count, generation: generation) {
                        // Debug 伪造断流：抛真实的网络错误，走与线上完全相同的恢复路径
                        throw URLError(.networkConnectionLost)
                    }
                }

                while let tag = try parser.nextTag() {
                    if !isCurrent(generation) { return .cancelled }
                    try await handle(tag, context: context, generation: generation)
                }
            }
            if unpublished > 0 {
                _ = await publishReceived(unpublished, generation: generation)
            }
            if !isCurrent(generation) { return .cancelled }
            // 流被对端正常关闭。直播不该"正常结束"，通常是 CDN 节点轮换或主播下播，
            // 先按瞬时中断同址重试；连不上再交给房间层判断是否已下播。
            return .retrySameURL(reason: "直播流已结束")
        } catch is CancellationError {
            return .cancelled
        } catch {
            if !isCurrent(generation) { return .cancelled }
            return classify(error)
        }
    }

    /// 判断一个错误值不值得重试，以及该怎么重试。
    private func classify(_ error: Error) -> Recovery {
        let message = error.localizedDescription
        if let http = error as? LiveHTTPError, http.requiresFreshURL { return .needFreshURL(reason: message) }

        if let playerError = error as? LivePlayerError {
            switch playerError {
            case .unsupportedCodec, .videoFormatFailed, .audioFormatFailed:
                // 换地址也还是同一路编码，重试没有意义
                return .giveUp(reason: message)
            case .notFLV:
                // 返回的不是 FLV，多半是 CDN 的错误页——同址重试只会拿到同一张错误页
                return .needFreshURL(reason: message)
            case .sampleBufferFailed, .network:
                return .retrySameURL(reason: message)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .badURL, .unsupportedURL:
                return .giveUp(reason: friendlyMessage(for: urlError))
            default:
                return .retrySameURL(reason: friendlyMessage(for: urlError))
            }
        }

        return .retrySameURL(reason: message)
    }

    /// 把 URLError 翻成用户能看懂的话。
    ///
    /// 系统的 localizedDescription 会给出「未能完成操作。（NSURLErrorDomain错误-1005。）」
    /// 这类内容，而重连耗尽后这段文案是直接显示在播放器上的。
    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "网络已断开"
        case .networkConnectionLost:
            return "网络连接中断"
        case .timedOut:
            return "连接超时"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接到直播服务器"
        case .badURL, .unsupportedURL:
            return "播放地址无效"
        case .badServerResponse:
            return "直播服务器返回异常"
        default:
            return error.localizedDescription
        }
    }

    @MainActor
    private func setState(_ new: State, generation: UInt64) {
        guard isCurrent(generation) else { return }
        state = new
    }

    /// 累计已接收字节。返回值是「是否应当在此处中断」——Debug 下用于伪造断流。
    /// 调用方按几十 KB 合并一次，避免每个 HTTP 分块都跳到主线程。
    @MainActor
    private func publishReceived(_ count: Int, generation: UInt64) -> Bool {
        guard isCurrent(generation) else { return false }
        receivedBytes += count
        #if DEBUG
        if dropBudget > 0 {
            dropBudget -= 1
            return true
        }
        #endif
        return false
    }

    @MainActor
    private func setVideoSize(_ size: CGSize, generation: UInt64) {
        guard isCurrent(generation) else { return }
        guard videoSize != size else { return }
        videoSize = size
    }

    // MARK: - Buffered background renewal

    private func runBufferedPlayback(request: URLRequest, generation: UInt64) async {
        let sources = BufferedSourceRegistry()
        await withTaskCancellationHandler {
            await consumeBufferedPlayback(request: request, generation: generation, sources: sources)
        } onCancel: { sources.cancelAll() }
    }

    private func consumeBufferedPlayback(request: URLRequest, generation: UInt64, sources: BufferedSourceRegistry) async {
        guard isCurrent(generation) else { return }
        var source = BufferedLiveSource(request: request, diagnosticID: diagnosticID)
        sources.insert(source)
        var context = DecodeContext()
        context.continuous = true
        var initialized = false
        var policy = LiveHandoffPolicy()
        let mailbox = LiveReplacementMailbox()
        var preparation: Task<Void, Never>?
        var lastDelivery = ProcessInfo.processInfo.systemUptime
        var lastReport: TimeInterval = 0
        var stableSince: TimeInterval?
        var lastError = "等待直播数据"
        var terminalObserved = false
        var unpublished = 0
        defer {
            sources.cancelAll()
            preparation?.cancel()
            // A prepared source may have been published just as cancellation won.
            Task { await mailbox.close() }
        }
        await setState(.buffering, generation: generation)
        while isCurrent(generation) {
            let now = ProcessInfo.processInfo.systemUptime
            var snapshot = await source.buffer.snapshot()
            guard isCurrent(generation) else { return }
            if snapshot.ended, !terminalObserved {
                terminalObserved = true
                lastError = snapshot.error?.localizedDescription ?? "直播连接已结束"
                LiveDiagnostics.record("buffer.sourceEnded", fields: ["player": diagnosticID,
                    "bufferSeconds": String(snapshot.seconds), "error": lastError])
                if let error = snapshot.error, case .giveUp(let reason) = classify(error) {
                    await setState(.failed(reason), generation: generation)
                    return
                }
            }
            if let stableStart = stableSince, now - stableStart >= 30, !snapshot.ended {
                policy.stablePlayback()
                stableSince = nil
            }
            if let outcome = await mailbox.take() {
                preparation = nil
                switch outcome {
                case .ready(let replacement):
                    guard isCurrent(generation) else { replacement.source.cancel(); return }
                    let next = await replacement.source.buffer.snapshot()
                    if next.ready || next.seconds >= replacement.minimumSeconds, !next.ended {
                        let old = source
                        let nextContext = DecodeContext()
                        nextContext.continuous = true
                        nextContext.timeOffset = await handoffOffset(after: context.lastQueuedEnd, generation: generation)
                        nextContext.didStartClock = context.didStartClock
                        nextContext.clockNeedsResume = context.clockNeedsResume
                        context = nextContext
                        source = replacement.source
                        initialized = true
                        terminalObserved = false
                        snapshot = next
                        stableSince = now
                        policy.committed()
                        lastDelivery = now
                        await commitBufferedReplacement(replacement.selection, generation: generation)
                        old.cancel()
                        sources.remove(old)
                        LiveDiagnostics.record("buffer.handoff", fields: ["player": diagnosticID,
                            "readySeconds": String(next.seconds), "timelineOffset": String(context.timeOffset.seconds)])
                    } else {
                        replacement.source.cancel()
                        sources.remove(replacement.source)
                        policy.failed(at: now)
                        lastError = next.error?.localizedDescription ?? "备用直播连接提前结束"
                    }
                case .failed(let reason):
                    lastError = reason
                    policy.failed(at: now)
                    LiveDiagnostics.record("buffer.prepareFailed", fields: ["player": diagnosticID, "error": reason])
                }
            }
            if preparation == nil, policy.begin(now: now, sourceAge: now - source.startedAt,
                                                  ended: snapshot.ended, stalled: now - lastDelivery > 12) {
                let rotate = snapshot.ended || now - lastDelivery > 12 || policy.attempts > 1
                // When the old source is already dead, do not spend its remaining
                // four-second reserve waiting to build another full four seconds.
                let minimumSeconds = snapshot.ended || now - lastDelivery > 12 ? 0.5 : LiveTagBuffer.targetSeconds
                LiveDiagnostics.record("buffer.prepare", fields: ["player": diagnosticID,
                    "sourceAge": String(now - source.startedAt), "attempt": String(policy.attempts),
                    "bufferSeconds": String(snapshot.seconds), "rotate": String(rotate)])
                preparation = Task { [weak self] in
                    guard let self else { return }
                    var candidate: BufferedLiveSource?
                    var published = false
                    defer {
                        if !published, let candidate {
                            candidate.cancel()
                            sources.remove(candidate)
                        }
                    }
                    do {
                        let selection = try await self.prepareBufferedSelection(rotate: rotate, generation: generation)
                        try Task.checkCancellation()
                        guard self.isCurrent(generation), let url = URL(string: selection.url) else { throw CancellationError() }
                        var freshRequest = URLRequest(url: url)
                        freshRequest.timeoutInterval = 15
                        selection.stream.headers?.forEach { freshRequest.setValue($1, forHTTPHeaderField: $0) }
                        let fresh = BufferedLiveSource(request: freshRequest, diagnosticID: self.diagnosticID)
                        candidate = fresh
                        sources.insert(fresh)
                        while self.isCurrent(generation) {
                            let ready = await fresh.buffer.snapshot()
                            if ready.ended { throw ready.error ?? LivePlayerError.network("备用直播连接提前结束") }
                            if ready.ready || ready.seconds >= minimumSeconds {
                                try Task.checkCancellation()
                                await mailbox.put(.ready(ReadyLiveReplacement(source: fresh, selection: selection, minimumSeconds: minimumSeconds)))
                                published = true
                                return
                            }
                            if ProcessInfo.processInfo.systemUptime - fresh.startedAt > LiveHandoffPolicy.preparationTimeout {
                                throw URLError(.timedOut)
                            }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    } catch {
                        guard !Task.isCancelled, self.isCurrent(generation) else { return }
                        await mailbox.put(.failed(error.localizedDescription))
                    }
                }
            }
            if !initialized, snapshot.ready || ((snapshot.ended || now - source.startedAt > 20) && snapshot.count > 0) {
                initialized = true
                stableSince = now
            }
            if initialized, let tag = await source.buffer.pop() {
                guard isCurrent(generation) else { return }
                do {
                    unpublished += tag.payload.count
                    if unpublished >= 64 * 1024 {
                        _ = await publishReceived(unpublished, generation: generation)
                        unpublished = 0
                    }
                    try await handle(tag, context: context, generation: generation)
                    lastDelivery = ProcessInfo.processInfo.systemUptime
                } catch {
                    if isCurrent(generation) { await setState(.failed(error.localizedDescription), generation: generation) }
                    return
                }
            } else {
                if context.didStartClock {
                    if await showRecoveryOnlyWhenDrained(end: context.lastQueuedEnd, attempt: policy.attempts, generation: generation) {
                        context.clockNeedsResume = true
                    }
                }
                if policy.exhausted, preparation == nil, snapshot.count == 0,
                   !context.didStartClock || context.clockNeedsResume,
                   snapshot.ended || now - lastDelivery > 20 {
                    await setState(.failed("\(lastError)，刷新多次仍未成功"), generation: generation)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            if now - lastReport >= 1 {
                lastReport = now
                await reportBuffer(snapshot, renewing: preparation != nil, generation: generation)
            }
        }
    }

    @MainActor
    private func prepareBufferedSelection(rotate: Bool, generation: UInt64) async throws -> PreparedPlaybackStream {
        guard isCurrent(generation), let onPrepareStream else { throw CancellationError() }
        let result = try await onPrepareStream(rotate)
        guard isCurrent(generation) else { throw CancellationError() }
        return result
    }

    @MainActor
    private func commitBufferedReplacement(_ selection: PreparedPlaybackStream, generation: UInt64) {
        guard isCurrent(generation) else { return }
        onCommitStream?(selection)
        isRenewingStream = false
    }

    @MainActor
    private func handoffOffset(after end: CMTime, generation: UInt64) -> CMTime {
        guard isCurrent(generation) else { return .zero }
        return LiveHandoffTimeline.continuationOffset(end: end, clock: synchronizer.currentTime())
    }

    @MainActor
    private func showRecoveryOnlyWhenDrained(end: CMTime, attempt: Int, generation: UInt64) -> Bool {
        guard isCurrent(generation), synchronizer.currentTime() >= end else { return false }
        synchronizer.setRate(0, time: end)
        state = .reconnecting(attempt: max(1, attempt))
        return true
    }

    @MainActor
    private func reportBuffer(_ snapshot: LiveTagBuffer.Snapshot, renewing: Bool, generation: UInt64) {
        guard isCurrent(generation) else { return }
        bufferedSeconds = snapshot.seconds
        bufferedBytes = snapshot.bytes
        isRenewingStream = renewing
    }


    // MARK: - tag 分派

    private func handle(_ tag: FLVTag, context: DecodeContext, generation: UInt64) async throws {
        switch tag.type {
        case .video:
            try await handleVideo(tag, context: context, generation: generation)
        case .audio:
            try await handleAudio(tag, context: context, generation: generation)
        case .script:
            break  // onMetaData 暂不需要
        }
    }

    private func relativeTime(_ timestamp: UInt32, offsetMS: Int32 = 0, context: DecodeContext) -> CMTime {
        let base = context.timestampBase ?? 0
        let relative = Int64(timestamp >= base ? timestamp - base : 0) + Int64(offsetMS)
        return CMTimeAdd(context.timeOffset, CMTime(value: max(0, relative), timescale: Self.timescale))
    }

    private func handleVideo(_ tag: FLVTag, context: DecodeContext, generation: UInt64) async throws {
        guard let video = FLVVideoTag(payload: tag.payload) else {
            // 非 H.264（例如 HEVC）在此被识别
            throw LivePlayerError.unsupportedCodec
        }

        switch video.packet {
        case .sequenceHeader(let record):
            guard let config = AVCConfig(record: record) else {
                throw LivePlayerError.unsupportedCodec
            }
            let format = try config.makeFormatDescription()
            context.videoFormat = format
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            await setVideoSize(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)), generation: generation)

        case .nalus(let avcc):
            guard let format = context.videoFormat else { return }
            // 必须从关键帧起播，否则首屏是花屏。
            // 时间基准也得落在这个关键帧上：前面的音频帧 / P 帧会被丢掉，
            // 若用它们当基准，关键帧的 PTS 会落在时钟的「未来」，画面要空等一个 GOP。
            if !context.didReceiveKeyframe {
                guard video.isKeyframe else { return }
                context.didReceiveKeyframe = true
                if context.timestampBase == nil {
                    context.timestampBase = tag.timestamp
                }
            }
            let dts = relativeTime(tag.timestamp, context: context)
            let pts = relativeTime(tag.timestamp, offsetMS: video.compositionTimeOffset, context: context)
            let sample = try makeSampleBuffer(
                data: avcc,
                format: format,
                pts: pts,
                dts: dts,
                isKeyframe: video.isKeyframe
            )
            await enqueueVideo(sample, context: context, generation: generation)

        case .end:
            break
        }
    }

    private func handleAudio(_ tag: FLVTag, context: DecodeContext, generation: UInt64) async throws {
        guard let audio = FLVAudioTag(payload: tag.payload) else { return }

        switch audio.packet {
        case .sequenceHeader(let config):
            guard let parsed = AACConfig(config: config) else { return }
            if context.audioFormat == nil || context.audioSampleRate != parsed.sampleRate {
                context.audioSampleRate = parsed.sampleRate
                context.resetAudioTimeline()
                await preferHardwareSampleRate(parsed.sampleRate, generation: generation)
            }
            context.audioFormat = try parsed.makeFormatDescription()

        case .raw(let frame):
            guard let format = context.audioFormat, context.didReceiveKeyframe else { return }
            let pts = audioPresentationTime(containerTimestamp: tag.timestamp, context: context)
            let sample = try makeAudioSampleBuffer(data: frame, format: format, pts: pts, sampleRate: context.audioSampleRate)
            await enqueueAudio(sample, context: context, generation: generation)
        }
    }

    /// 生成与帧长严格首尾相接的音频 PTS。
    ///
    /// 容器时间戳只在两处参与：第一帧用它和视频对齐，之后若相邻两帧的容器时间
    /// 突然跳变（向前超过 200ms 或向后超过 50ms）才重新锚定。正常的 ±1ms 取整
    /// 误差留在容器时间上，不写进渲染器。
    private func audioPresentationTime(containerTimestamp: UInt32, context: DecodeContext) -> CMTime {
        let container = relativeTime(containerTimestamp, context: context)
        if let last = context.lastAudioContainerPTS {
            let step = CMTimeSubtract(container, last).seconds
            if step < -0.05 || step > 0.2 {
                context.audioTimelineAnchor = nil
                context.audioFramesQueued = 0
            }
        }
        context.lastAudioContainerPTS = container

        let scale = CMTimeScale(context.audioSampleRate)
        if let anchor = context.audioTimelineAnchor {
            let pts = CMTimeAdd(anchor, CMTime(value: context.audioFramesQueued * 1024, timescale: scale))
            context.audioFramesQueued += 1
            return pts
        }
        context.audioTimelineAnchor = container
        context.audioFramesQueued = 1
        return container
    }

    /// 让硬件采样率尽量跟上流的采样率。
    ///
    /// 真机扬声器/听筒经常锁在 48kHz，44.1kHz 的 AAC 就要在很小的 IO 缓冲里重采样，
    /// 听感是周期性卡顿。模拟器不走这条硬件通路，所以只有真机明显。
    /// 此时还没入队任何音频，改采样率不会打断正在播放的声音。
    @MainActor
    private func preferHardwareSampleRate(_ sampleRate: Double, generation: UInt64) {
        guard isCurrent(generation) else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setPreferredSampleRate(sampleRate)
        #endif
    }

    // MARK: - CMSampleBuffer 构造

    private func makeSampleBuffer(
        data: Data,
        format: CMVideoFormatDescription,
        pts: CMTime,
        dts: CMTime,
        isKeyframe: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: raw, count: data.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: raw,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,  // 由 CMBlockBuffer 接管释放
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            raw.deallocate()
            throw LivePlayerError.sampleBufferFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw LivePlayerError.sampleBufferFailed(status)
        }

        // 缺省值是「同步帧」。非关键帧不写 true 的话，B 帧会被显示层当成关键帧，花屏或抖动。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let notSync: CFBoolean = isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(notSync).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func makeAudioSampleBuffer(
        data: Data,
        format: CMAudioFormatDescription,
        pts: CMTime,
        sampleRate: Double
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: raw, count: data.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: raw,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            raw.deallocate()
            throw LivePlayerError.sampleBufferFailed(status)
        }

        // AAC 每包固定 1024 帧，时长按流的真实采样率计算
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw LivePlayerError.sampleBufferFailed(status)
        }
        return sampleBuffer
    }

    // MARK: - 入队与背压

    private func enqueueVideo(_ sample: CMSampleBuffer, context: DecodeContext, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        let renderer = videoRenderer
        generationGate.withCurrent(generation) {
            if renderer.status == .failed { renderer.flush() }
        }
        await waitForRoom(renderer, generation: generation)
        guard isCurrent(generation) else { return }
        if !renderer.isReadyForMoreMediaData, synchronizer.rate == 0 {
            await startClockIfNeeded(context: context, generation: generation)
            await waitForRoom(renderer, generation: generation, limit: 50)
        }
        guard isCurrent(generation) else { return }
        let enqueued = generationGate.withCurrent(generation) {
            guard !Task.isCancelled, renderer.isReadyForMoreMediaData else { return false }
            renderer.enqueue(sample)
            return true
        } ?? false
        if enqueued {
            #if os(iOS)
            pipFrames.append(sample)
            #endif
            context.lastQueuedEnd = CMTimeMaximum(context.lastQueuedEnd,
                CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(seconds: 1.0 / 60, preferredTimescale: 60000)))
            if context.continuous && context.clockNeedsResume {
                await continueBufferedClock(context: context, generation: generation)
                context.clockNeedsResume = false
            }
            if !context.didStartClock { await startClockIfNeeded(context: context, generation: generation) }
        } else if isCurrent(generation) {
            await resyncToLive(context: context, generation: generation)
        }
    }

    private func enqueueAudio(_ sample: CMSampleBuffer, context: DecodeContext, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        generationGate.withCurrent(generation) {
            if audioRenderer.status == .failed { audioRenderer.flush() }
        }
        await waitForRoom(audioRenderer, generation: generation)
        guard isCurrent(generation) else { return }
        if !audioRenderer.isReadyForMoreMediaData, synchronizer.rate == 0 {
            await startClockIfNeeded(context: context, generation: generation)
            await waitForRoom(audioRenderer, generation: generation, limit: 50)
        }
        guard isCurrent(generation) else { return }
        generationGate.withCurrent(generation) {
            guard !Task.isCancelled else { return }
            guard audioRenderer.isReadyForMoreMediaData else {
                audioRenderer.flush()
                context.resetAudioTimeline()
                return
            }
            audioRenderer.enqueue(sample)
            context.lastQueuedEnd = CMTimeMaximum(context.lastQueuedEnd,
                CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample)))
        }
    }

    private func waitForRoom(_ renderer: any AVQueuedSampleBufferRendering, generation: UInt64, limit: Int = 150) async {
        var spins = 0
        while isCurrent(generation), !renderer.isReadyForMoreMediaData, spins < limit {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            spins += 1
        }
    }

    @MainActor
    private func resyncToLive(context: DecodeContext, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        synchronizer.setRate(0, time: .zero)
        await scheduleVideoFlush(removingImage: false).value
        // A new stream may have started while the renderer's async flush completed.
        guard isCurrent(generation) else { return }
        audioRenderer.flush()
        context.didStartClock = false
        context.didReceiveKeyframe = false
        context.timestampBase = nil
        context.timeOffset = .zero
        context.lastQueuedEnd = .zero
        context.resetAudioTimeline()
        resyncCount += 1
    }

    private(set) var resyncCount = 0

    @MainActor
    private func continueBufferedClock(context: DecodeContext, generation: UInt64) {
        guard isCurrent(generation), context.didStartClock else { return }
        if synchronizer.rate == 0 { synchronizer.setRate(1, time: synchronizer.currentTime()) }
        if state != .playing { state = .playing }
    }

    @MainActor
    private func startClockIfNeeded(context: DecodeContext, generation: UInt64) {
        guard isCurrent(generation) else { return }
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        guard !context.didStartClock else {
            if synchronizer.rate == 0 {
                synchronizer.setRate(1.0, time: synchronizer.currentTime())
            }
            return
        }
        context.didStartClock = true
        recoveryPolicy.playbackStarted(at: ProcessInfo.processInfo.systemUptime)
        synchronizer.setRate(1.0, time: .zero)
        state = .playing
    }

}

// MARK: - SwiftUI 桥接

/// 把 AVSampleBufferDisplayLayer 挂到 SwiftUI 视图树
#if os(iOS)
struct FLVVideoLayerView: UIViewRepresentable {
    let player: FLVLivePlayer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.hostedLayer = player.displayLayer
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.hostedLayer = player.displayLayer
    }

    final class LayerHostView: UIView {
        var hostedLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard oldValue !== hostedLayer else { return }
                oldValue?.removeFromSuperlayer()
                if let hostedLayer {
                    layer.addSublayer(hostedLayer)
                    setNeedsLayout()
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 不依赖任何屏幕尺寸假设，始终跟随自身 bounds
            hostedLayer?.frame = bounds
        }
    }
}
#else
struct FLVVideoLayerView: NSViewRepresentable {
    let player: FLVLivePlayer
    var floating = false

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        if floating == player.isInFloatingWindow { view.hostedLayer = player.displayLayer }
        return view
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        guard floating == player.isInFloatingWindow else { return }
        nsView.hostedLayer = player.displayLayer
    }

    final class LayerHostView: NSView {
        var hostedLayer: AVSampleBufferDisplayLayer? {
            didSet {
                if oldValue === hostedLayer, hostedLayer?.superlayer === layer { return }
                if oldValue?.superlayer === layer { oldValue?.removeFromSuperlayer() }
                if let hostedLayer { layer?.addSublayer(hostedLayer) }
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            // A hidden inline view must not overwrite the floating view's geometry.
            guard let hostedLayer, let layer else { return }
            VideoLayerLayout.resize(hostedLayer, ownedBy: layer, bounds: bounds)
        }
    }
}
#endif
