import AVFoundation
import AVKit
import Observation
import SimpleLiveKit
import SwiftUI

/// 录像播放器。
///
/// 录像是标准 HLS（H.264 / AAC），交给系统 AVPlayer 即可：拖动、倍速、
/// 缓冲由系统完成；Mac 小窗承载原图层，iOS 可选合成弹幕画中画。
@MainActor
@Observable
final class ReplayPlayer {
    enum State: Equatable {
        case idle, loading, playing, paused, buffering, ended
        case failed(String)
    }

    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()

    private(set) var state: State = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var videoSize: CGSize?
    private(set) var isPiPActive = false {
        didSet { reconcileBackground() }
    }
    var onPiPRestore: (() -> Void)?

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }
    var volume: Double = 1 { didSet { player.volume = Float(min(max(volume, 0), 1)) } }
    var isMuted = false { didSet { player.isMuted = isMuted } }

    /// 播放失败（多半是签名地址过期）。由会话重新取流后调用 `load` 续播。
    var onFailure: ((String) -> Void)?
    var onEnded: (() -> Void)?
    /// 每 0.25 秒回报一次播放进度（拖动期间不回报）
    var onTick: ((TimeInterval) -> Void)?
    /// Includes seeks initiated by the system PiP controls.
    var onSeek: ((TimeInterval) -> Void)?

    /// 等待中的起播位置与是否自动播放，item 就绪后执行
    private var pendingStart: TimeInterval = 0
    private var pendingAutoplay = true
    private var itemGeneration = 0
    private var seekGeneration = 0
    private var seekTarget: TimeInterval?
    private var timeObserver: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var pip: AVPictureInPictureController?
    private var pipDelegate: ReplayPiPDelegate?
    var danmakuSnapshot: (() -> PiPDanmakuSnapshot)?
    private var pipSettings: AppSettings?
    #if os(macOS)
    private let floating = MacFloatingVideoController()
    private(set) var isInFloatingWindow = false
    #else
    private let composite = PiPCompositeSource()
    private let preference = PiPDanmakuPreference()
    private var videoOutput: AVPlayerItemVideoOutput?
    #endif
    private var isShutDown = false
    private var sceneBackgrounded = false
    private var backgroundAudioAllowed = true
    private var resumeAfterBackground = false
    private var backgroundTask: Task<Void, Never>?

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncState() }
        })
    }

    var isPlaying: Bool { state == .playing || state == .buffering }
    /// 拖动进度条时显示目标位置，而不是播放器回报的旧位置
    var displayTime: TimeInterval { seekTarget ?? currentTime }

    // MARK: 加载

    func load(url: URL, at start: TimeInterval, autoplay: Bool) {
        guard !isShutDown else { return }
        clearItem()
        activateAudioSession()
        pendingStart = max(0, start)
        pendingAutoplay = autoplay
        resumeAfterBackground = false
        // 新 item 就绪前播放器会短暂回报 0 秒，先锁住目标位置，免得被当成拖动
        seekTarget = pendingStart
        currentTime = pendingStart
        bufferedTime = 0
        duration = 0
        videoSize = nil
        state = .loading
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: HTTPClient.desktopUserAgent])
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        #if os(iOS)
        if isPiPActive { refreshPiPDanmaku() }
        #endif
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.itemStatusChanged(item) }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, item === self.player.currentItem else { return }
                    let size = item.presentationSize
                    self.videoSize = size.width > 0 ? size : nil
                }
            },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.state = .ended
                    self.onEnded?()
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak item] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.fail(error?.localizedDescription ?? "播放中断")
                }
            },
        ]
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
            guard state == .loading else { return }
            seekToPendingStart(item)
        case .failed:
            fail(item.error?.localizedDescription ?? "无法播放这段录像")
        default:
            break
        }
    }

    private func seekToPendingStart(_ item: AVPlayerItem) {
        let start = duration > 0 ? min(pendingStart, max(0, duration - 0.5)) : pendingStart
        let token = itemGeneration
        seekGeneration += 1
        let seekToken = seekGeneration
        player.seek(to: Self.time(start), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, finished, self.itemGeneration == token,
                      self.seekGeneration == seekToken, item === self.player.currentItem,
                      self.state == .loading else { return }
                self.seekTarget = nil
                self.currentTime = start
                self.state = .paused
                if self.pendingAutoplay { self.play() }
            }
        }
    }

    private func fail(_ message: String) {
        guard state != .idle else { return }
        state = .failed(message)
        LiveDiagnostics.record("replay.playbackFailed", fields: ["error": message, "time": String(Int(currentTime))])
        onFailure?(message)
    }

    // MARK: 控制

    func play() {
        guard player.currentItem != nil else { return }
        pendingAutoplay = true
        if sceneBackgrounded, !backgroundAudioAllowed, !isPiPActive {
            resumeAfterBackground = true
            return
        }
        guard state != .loading else { return }
        if state == .ended { seek(to: 0) }
        player.playImmediately(atRate: rate)
        syncState()
    }

    func pause() {
        pendingAutoplay = false
        resumeAfterBackground = false
        player.pause()
        syncState()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to target: TimeInterval) {
        guard player.currentItem != nil, target.isFinite else { return }
        let upper = duration > 0 ? max(0, duration - 0.5) : max(0, target)
        let clamped = min(max(0, target), upper)
        seekTarget = clamped
        currentTime = clamped
        onSeek?(clamped)
        if state == .loading {
            // 还没就绪：改写起播位置，就绪后一次到位
            pendingStart = clamped
            if let item = player.currentItem, item.status == .readyToPlay { seekToPendingStart(item) }
            return
        }
        if state == .ended { state = .paused }
        seekGeneration += 1
        let seekToken = seekGeneration
        let token = itemGeneration
        player.seek(to: Self.time(clamped), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.itemGeneration == token, self.seekGeneration == seekToken else { return }
                self.seekTarget = nil
                self.currentTime = self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : clamped
            }
        }
    }

    func skip(by delta: TimeInterval) {
        seek(to: displayTime + delta)
    }

    // MARK: 状态

    private func tick(_ time: CMTime) {
        guard seekTarget == nil, time.seconds.isFinite else { return }
        currentTime = time.seconds
        onTick?(currentTime)
        if let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
            let end = range.end.seconds
            if end.isFinite { bufferedTime = end }
        }
    }

    private func syncState() {
        guard player.currentItem != nil else { return }
        switch state {
        case .idle, .loading, .failed: return
        default: break
        }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        case .paused: if state != .ended { state = .paused }
        @unknown default: break
        }
    }

    private func clearItem() {
        itemGeneration += 1
        seekGeneration += 1
        #if os(iOS)
        // Return to the system player layer while the new item gets ready.
        // The compositor must not keep painting the preceding item's last frame.
        if isPiPActive { pip?.contentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer) }
        stopComposite()
        #endif
        itemObservations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        seekTarget = nil
        player.replaceCurrentItem(with: nil)
    }

    /// 关闭窗口 / 离开页面时调用。之后不能再加载。
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        backgroundTask?.cancel()
        backgroundTask = nil
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip = nil
        pipDelegate = nil
        isPiPActive = false
        #if os(macOS)
        floating.stop()
        #else
        stopComposite()
        preference.stop()
        #endif
        danmakuSnapshot = nil
        state = .idle
        clearItem()
        playerObservations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// iOS 进入后台时，带视频图层的 AVPlayer 会被系统暂停。
    /// 允许后台播放时先把图层摘掉，回到前台再挂回去。
    func setBackgrounded(_ backgrounded: Bool, keepAudio: Bool) {
        sceneBackgrounded = backgrounded
        backgroundAudioAllowed = keepAudio
        reconcileBackground()
    }

    private func reconcileBackground() {
        backgroundTask?.cancel()
        backgroundTask = nil
        guard !isShutDown else { return }
        if !sceneBackgrounded || isPiPActive {
        #if os(iOS)
            playerLayer.player = player
        #endif
            if resumeAfterBackground {
                resumeAfterBackground = false
                play()
            }
            return
        }
        // Match live playback's grace period for automatic PiP's willStart.
        backgroundTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !self.isShutDown, self.sceneBackgrounded, !self.isPiPActive else { return }
            if self.backgroundAudioAllowed {
                #if os(iOS)
                self.playerLayer.player = nil
                #endif
                if self.resumeAfterBackground {
                    self.resumeAfterBackground = false
                    self.play()
                }
            } else {
                self.resumeAfterBackground = self.resumeAfterBackground || self.isPlaying
                    || (self.state == .loading && self.pendingAutoplay)
                self.pendingAutoplay = false
                self.player.pause()
                self.syncState()
            }
        }
    }

    // MARK: 画中画

    static var isPiPSupported: Bool {
        #if os(macOS)
        true
        #else
        AVPictureInPictureController.isPictureInPictureSupported()
        #endif
    }

    func configurePiP(settings: AppSettings) {
        pipSettings = settings
        #if os(iOS)
        preference.watch(settings) { [weak self] in self?.refreshPiPDanmaku() }
        #endif
    }

    /// 图层挂进视图树后才能创建画中画控制器
    func preparePiP(automatic: Bool) {
        #if os(iOS)
        guard Self.isPiPSupported, playerLayer.superlayer != nil else { return }
        if pip == nil, let controller = AVPictureInPictureController(playerLayer: playerLayer) {
            let delegate = ReplayPiPDelegate { [weak self] active in
                guard let self, !self.isShutDown else { return }
                self.isPiPActive = active
                if active { self.refreshPiPDanmaku() }
                else {
                    self.pip?.contentSource = AVPictureInPictureController.ContentSource(playerLayer: self.playerLayer)
                    self.stopComposite()
                }
            }
            delegate.player = self
            delegate.onWillStart = { [weak self] in self?.isPiPActive = true }
            controller.delegate = delegate
            pip = controller
            pipDelegate = delegate
        }
        pip?.canStartPictureInPictureAutomaticallyFromInline = automatic
        #endif
    }

    func togglePiP() {
        #if os(macOS)
        if floating.isActive { floating.stop(); return }
        guard let settings = pipSettings, playerLayer.superlayer != nil else { return }
        isInFloatingWindow = true
        floating.onStateChange = { [weak self] in self?.isPiPActive = $0 }
        floating.onFinish = { [weak self] in self?.isInFloatingWindow = false }
        floating.onRestore = { [weak self] in self?.onPiPRestore?() }
        floating.start(layer: playerLayer, size: videoSize, settings: settings,
                       isPlaying: { [weak self] in self?.isPlaying == true },
                       togglePlayback: { [weak self] in self?.togglePlay() },
                       snapshot: { [weak self] in self?.danmakuSnapshot?() ?? PiPDanmakuSnapshot() })
        #else
        preparePiP(automatic: pipSettings?.data.autoPictureInPicture ?? false)
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
        #endif
    }

    #if os(iOS)
    func refreshPiPDanmaku() {
        guard isPiPActive, let pip else { return }
        guard pipSettings?.data.pictureInPictureDanmaku == true, let item = player.currentItem else {
            pip.contentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
            stopComposite()
            return
        }
        if videoOutput == nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)
            videoOutput = output
        }
        composite.snapshot = { [weak self] in self?.danmakuSnapshot?() ?? PiPDanmakuSnapshot() }
        composite.frame = { [weak self] in
            guard let self else { return nil }
            return self.videoOutput?.copyPixelBuffer(forItemTime: self.player.currentTime(), itemTimeForDisplay: nil)
        }
        composite.parent = { [weak self] in self?.playerLayer.superlayer }
        composite.playbackTime = { [weak self] in
            guard let self else { return (.zero, 0) }
            return (self.player.currentTime(), self.player.rate)
        }
        composite.onReady = { [weak self] in
            guard let self, let delegate = self.pipDelegate, self.isPiPActive else { return }
            self.pip?.contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: self.composite.layer, playbackDelegate: delegate)
        }
        composite.start()
    }

    private func stopComposite() {
        composite.stop()
        if let videoOutput { player.currentItem?.remove(videoOutput) }
        videoOutput = nil
    }
    #endif

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private final class ReplayPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var player: ReplayPlayer?
    var onWillStart: (@MainActor () -> Void)?
    let onChange: @MainActor (Bool) -> Void
    init(onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onWillStart?() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in onChange(true) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in onChange(false) }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in onChange(false) }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

#if os(iOS)
extension ReplayPiPDelegate: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            if playing { player?.play() } else { player?.pause() }
            controller.invalidatePlaybackState()
        }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            CMTimeRange(start: .zero, duration: CMTime(seconds: player?.duration ?? 0, preferredTimescale: 600))
        }
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { player?.isPlaying != true }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime) async {
        await MainActor.run { player?.skip(by: interval.seconds) }
    }
}
#endif

// MARK: - SwiftUI 桥接

#if os(iOS)
struct ReplayVideoView: UIViewRepresentable {
    let player: ReplayPlayer
    var onAttach: (() -> Void)?

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(player.playerLayer)
        view.onAttach = onAttach
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        if player.playerLayer.superlayer !== uiView.layer { uiView.layer.addSublayer(player.playerLayer) }
    }

    final class HostView: UIView {
        var onAttach: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { if $0 is AVPlayerLayer { $0.frame = bounds } }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onAttach?() }
        }
    }
}
#else
struct ReplayVideoView: NSViewRepresentable {
    let player: ReplayPlayer
    var onAttach: (() -> Void)?

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        if !player.isInFloatingWindow { view.layer?.addSublayer(player.playerLayer) }
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        guard !player.isInFloatingWindow else { return }
        if player.playerLayer.superlayer !== nsView.layer { nsView.layer?.addSublayer(player.playerLayer) }
    }

    final class HostView: NSView {
        var onAttach: (() -> Void)?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { if $0 is AVPlayerLayer { $0.frame = bounds } }
            CATransaction.commit()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.onAttach?() } }
        }
    }
}
#endif
