#if os(iOS)
import AVFoundation
import AVKit
import Combine

/// 画中画控制器。
///
/// 常规做法 `AVPictureInPictureController(playerLayer:)` 用不了——那要求 AVPlayerLayer，
/// 而斗鱼只给 FLV，我们的渲染链路是自研的 AVSampleBufferDisplayLayer。
/// 因此走 `ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`，
/// 代价是必须自己实现整套播放控制协议。
@MainActor
final class PiPController: NSObject {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private weak var player: FLVLivePlayer?
    var danmakuSnapshot: (() -> PiPDanmakuSnapshot)?
    private let composite = PiPCompositeSource()
    private let preference = PiPDanmakuPreference()

    /// PiP 小窗点了播放时回调。直播没有缓冲区可续播，只能重新拉流。
    var onRequestPlay: (() -> Void)?
    var onRequestPause: (() -> Void)?
    var isPlaybackRequested: (() -> Bool)?
    /// 小窗状态变化，供 UI 更新按钮
    var onStateChange: ((Bool) -> Void)?

    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    func invalidatePlaybackState() { controller?.invalidatePlaybackState() }

    func refreshDanmaku() {
        guard isActive, let player, let controller else { return }
        if danmakuSnapshot?().isVisible == true {
            player.pipFrames.setEnabled(true)
            composite.snapshot = { [weak self] in self?.danmakuSnapshot?() ?? PiPDanmakuSnapshot() }
            composite.frame = { [weak player] in player?.pictureInPictureFrame() }
            composite.parent = { [weak player] in player?.displayLayer.superlayer }
            composite.onReady = { [weak self] in
                guard let self, let controller = self.controller, self.isActive else { return }
                controller.contentSource = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: self.composite.layer, playbackDelegate: self)
            }
            composite.start()
        } else {
            controller.contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: player.displayLayer, playbackDelegate: self)
            stopComposite()
        }
    }

    private func stopComposite() {
        composite.stop()
        player?.pipFrames.setEnabled(false)
    }

    /// 绑定播放器图层。重复调用只更新自动启动开关。
    func attach(player: FLVLivePlayer, automatic: Bool, settings: AppSettings) {
        guard Self.isSupported else { return }
        self.player = player
        preference.watch(settings) { [weak self] in self?.refreshDanmaku() }

        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: player.displayLayer,
                playbackDelegate: self
            )
            let created = AVPictureInPictureController(contentSource: source)
            created.delegate = self
            controller = created
        }
        // 这一项决定「切到桌面时是否自动进小窗」
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = automatic
        #endif
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// 离开房间时断开，避免小窗指向一个已经停掉的图层
    func detach() {
        stop()
        stopComposite()
        preference.stop()
        controller?.delegate = nil
        controller = nil
        player = nil
        isActive = false
        onRequestPlay = nil
        onRequestPause = nil
        isPlaybackRequested = nil
        onStateChange = nil
        danmakuSnapshot = nil
    }
}

// MARK: - 播放控制协议

/// 这两个协议都没有标注 actor 隔离，而 PiPController 是 @MainActor 的，
/// 直接遵循会「跨入主 actor 隔离代码」——Swift 6 语言模式下是错误。
/// AVKit 实际总在主线程回调，因此显式声明 nonisolated 再用
/// assumeIsolated 跳回来，把这个线程契约写进代码而不是靠默认行为。
extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        MainActor.assumeIsolated {
            if playing {
                onRequestPlay?()
            } else {
                if let onRequestPause { onRequestPause() }
                else { player?.stop() }
            }
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    /// 直播是无限时间轴。
    ///
    /// 返回有限区间会让小窗显示一条毫无意义的进度条，
    /// 拖动还会触发我们兑现不了的 seek 回调。
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        MainActor.assumeIsolated {
            if let isPlaybackRequested { return !isPlaybackRequested() }
            guard let player else { return true }
            return !player.isActive
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 图层尺寸由 LayerHostView 跟随 bounds，无需额外处理
    }

    /// 直播不可 seek，直接返回即视为完成。
    /// 不实现会让小窗的快进快退按钮卡在等待状态。
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {
    }
}

// MARK: - 生命周期回调

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            // Protect playback while automatic PiP is transitioning to the background.
            onStateChange?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            isActive = true
            refreshDanmaku()
            onStateChange?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            isActive = false
            stopComposite()
            if let player {
                controller?.contentSource = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: player.displayLayer, playbackDelegate: self)
            }
            onStateChange?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            isActive = false
            stopComposite()
            onStateChange?(false)
            print("[PiP] 启动失败：\(error.localizedDescription)")
        }
    }

    /// 从小窗点「返回 App」时调用。
    /// 图层始终留在原视图树里（没用 fullScreenCover 那种跨树重挂），
    /// 不需要重建界面，直接告知系统恢复完成。
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

#endif
