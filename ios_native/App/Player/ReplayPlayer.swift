import AVFoundation
import AVKit
import Observation
import SimpleLiveKit
import SwiftUI

/// 录像播放器。
///
/// 录像是标准 HLS（H.264 / AAC），交给系统 AVPlayer 即可：拖动、倍速、
/// 缓冲和画中画都由系统完成，不需要直播那套自研 FLV 链路。
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
    private(set) var isPiPActive = false

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

    /// 等待中的起播位置与是否自动播放，item 就绪后执行
    private var pendingStart: TimeInterval = 0
    private var pendingAutoplay = true
    private var seekTarget: TimeInterval?
    private var timeObserver: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var pip: AVPictureInPictureController?
    private var pipDelegate: ReplayPiPDelegate?
    private var isShutDown = false

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
        // 新 item 就绪前播放器会短暂回报 0 秒，先锁住目标位置，免得被当成拖动
        seekTarget = pendingStart
        currentTime = pendingStart
        bufferedTime = 0
        state = .loading
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: HTTPClient.desktopUserAgent])
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.itemStatusChanged(item) }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    let size = item.presentationSize
                    self?.videoSize = size.width > 0 ? size : nil
                }
            },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state = .ended
                    self?.onEnded?()
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { self?.fail(error?.localizedDescription ?? "播放中断") }
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
            let start = pendingStart
            let finish: () -> Void = { [weak self] in
                guard let self, self.state == .loading else { return }
                self.seekTarget = nil
                self.state = .paused
                if self.pendingAutoplay { self.play() }
            }
            if start > 1 {
                player.seek(to: Self.time(start), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in finish() }
                }
            } else {
                finish()
            }
        case .failed:
            fail(item.error?.localizedDescription ?? "无法播放这段录像")
        default:
            break
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
        if state == .ended { seek(to: 0) }
        player.playImmediately(atRate: rate)
        syncState()
    }

    func pause() {
        player.pause()
        syncState()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to target: TimeInterval) {
        guard player.currentItem != nil else { return }
        let upper = duration > 0 ? max(0, duration - 0.5) : target
        let clamped = min(max(0, target), upper)
        seekTarget = clamped
        currentTime = clamped
        if state == .loading {
            // 还没就绪：改写起播位置，就绪后一次到位
            pendingStart = clamped
            return
        }
        if state == .ended { state = .paused }
        player.seek(to: Self.time(clamped), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.seekTarget == clamped else { return }
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
        pip?.stopPictureInPicture()
        pip = nil
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
        #if os(iOS)
        if backgrounded, keepAudio, !isPiPActive { playerLayer.player = nil }
        else if !backgrounded { playerLayer.player = player }
        #endif
    }

    // MARK: 画中画

    static var isPiPSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// 图层挂进视图树后才能创建画中画控制器
    func preparePiP(automatic: Bool) {
        guard Self.isPiPSupported, playerLayer.superlayer != nil else { return }
        if pip == nil, let controller = AVPictureInPictureController(playerLayer: playerLayer) {
            let delegate = ReplayPiPDelegate { [weak self] active in self?.isPiPActive = active }
            controller.delegate = delegate
            pip = controller
            pipDelegate = delegate
        }
        #if os(iOS)
        pip?.canStartPictureInPictureAutomaticallyFromInline = automatic
        #endif
    }

    func togglePiP() {
        preparePiP(automatic: false)
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

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
    let onChange: @MainActor (Bool) -> Void
    init(onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in onChange(true) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in onChange(false) }
    }
}

// MARK: - SwiftUI 桥接

#if os(iOS)
struct ReplayVideoView: UIViewRepresentable {
    let player: ReplayPlayer
    var onAttach: (() -> Void)?

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
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
        view.layer?.addSublayer(player.playerLayer)
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ nsView: HostView, context: Context) {
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
