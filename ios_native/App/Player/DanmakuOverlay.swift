import SimpleLiveKit
import SwiftUI
import CoreText
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias DanmakuPlatformView = NSView
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias DanmakuPlatformView = UIView
#endif

/// 弹幕渲染设置
struct DanmakuSettings: Equatable {
    var fontSize: CGFloat = 16
    var opacity: CGFloat = 1.0
    /// 弹幕占据画面高度比例
    var areaRatio: CGFloat = 0.5
    /// 横向速度，点/秒
    var speed: CGFloat = 130
    /// 同轨道相邻弹幕最小间隙
    var gap: CGFloat = 26
    var strokeWidth: CGFloat = 1.6
}

/// CoreAnimation 弹幕渲染层。
///
/// 替代 Flutter 版的 `canvas_danmaku`。核心是轨道占用表：
/// 每条轨道记录「尾部何时离开右边缘」，新弹幕只会进入已空出的轨道，
/// 因此同一轨道永不重叠；没有空轨道时直接丢弃，保证高并发下不堆积。
///
/// 动画交给 CoreAnimation 在渲染进程推进，主线程只负责创建图层，
/// 在 120Hz ProMotion 上也不占用主线程预算。
final class DanmakuHostView: DanmakuPlatformView {
    var settings = DanmakuSettings()

    /// 每条轨道下一次可接收弹幕的时间点
    private var trackAvailableAt: [CFTimeInterval] = []
    private var trackCount = 0
    private var lastLayoutSize: CGSize = .zero

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        recalculateTracks()
    }
    private var drawingLayer: CALayer { layer! }
    private var displayScale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    private var drawingLayer: CALayer { layer }
    private var displayScale: CGFloat { traitCollection.displayScale }
    override func layoutSubviews() {
        super.layoutSubviews()
        recalculateTracks()
    }
    #endif

    /// 字号、区域、速度变了要立刻重算轨道。只等下一次 layout 的话，
    /// 从设置页返回时 bounds 没变，飞幕仍按旧行数排，会重叠。
    func apply(_ newSettings: DanmakuSettings) {
        let layoutChanged = settings.fontSize != newSettings.fontSize
            || settings.areaRatio != newSettings.areaRatio
            || settings.speed != newSettings.speed
            || settings.gap != newSettings.gap
        settings = newSettings
        guard layoutChanged else { return }
        trackCount = 0
        recalculateTracks()
    }

    private func recalculateTracks() {
        let lineHeight = settings.fontSize * 1.6
        let usableHeight = bounds.height * settings.areaRatio
        let count = max(1, Int(usableHeight / lineHeight))
        guard count != trackCount || bounds.size != lastLayoutSize else { return }
        // Existing animations use the previous width/speed/track grid. Remove them
        // before marking tracks free so new messages cannot collide with old ones.
        clear()
        trackCount = count
        lastLayoutSize = bounds.size
        trackAvailableAt = Array(repeating: 0, count: count)
    }

    /// 录像暂停时冻结飞行中的弹幕：把图层时间停住，恢复时接着走。
    /// 轨道占用表按绝对时间记录，恢复时整体顺延暂停的时长。
    private var pausedAt: CFTimeInterval?

    func setPaused(_ paused: Bool) {
        guard paused != (pausedAt != nil) else { return }
        let layer = drawingLayer
        let now = CACurrentMediaTime()
        if paused {
            layer.timeOffset = layer.convertTime(now, from: nil)
            layer.speed = 0
            pausedAt = now
        } else if let pausedAt {
            let frozen = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(now, from: nil) - frozen
            let elapsed = now - pausedAt
            trackAvailableAt = trackAvailableAt.map { $0 + elapsed }
            self.pausedAt = nil
        }
    }

    func clear() {
        drawingLayer.sublayers?.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        trackAvailableAt = Array(repeating: 0, count: max(trackCount, 1))
    }

    func emit(text: String, color: PlatformColor) {
        guard bounds.width > 0, !text.isEmpty else { return }
        if trackAvailableAt.isEmpty { recalculateTracks() }

        let now = CACurrentMediaTime()
        guard let track = trackAvailableAt.firstIndex(where: { $0 <= now }) else {
            return  // 所有轨道都忙，丢弃而不是叠字
        }

        let font = PlatformFont.systemFont(ofSize: settings.fontSize, weight: .medium)
        let coreFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        guard let raster = DanmakuTextRasterizer.render(
            text: text, font: coreFont, color: color.cgColor,
            strokeWidth: settings.strokeWidth, scale: displayScale
        ) else { return }
        let width = raster.size.width
        let lineHeight = settings.fontSize * 1.6

        // 走完「自身宽度 + 屏宽」所需时间
        let distance = bounds.width + width
        let duration = distance / settings.speed
        // 尾部离开右边缘所需时间，加间隙后该轨道才可复用
        trackAvailableAt[track] = now + (width + settings.gap) / settings.speed

        let label = CALayer()
        label.contents = raster.image
        label.contentsScale = raster.scale
        label.frame = CGRect(
            x: bounds.width,
            y: CGFloat(track) * lineHeight,
            width: width,
            height: raster.size.height
        )
        label.opacity = Float(settings.opacity)
        drawingLayer.addSublayer(label)

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = bounds.width + width / 2
        animation.toValue = -width / 2
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards

        // 动画结束即回收图层，避免长时间观看后图层无上界增长
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak label] in
            label?.removeFromSuperlayer()
        }
        label.add(animation, forKey: "move")
        CATransaction.commit()
    }

}

/// SwiftUI 包装。只把「新增的」消息投给渲染层，避免重复渲染。
struct DanmakuOverlay {
    let messages: [LiveMessage]
    var settings = DanmakuSettings()
    var isVisible: Bool
    /// 录像拖动进度时自增，清掉屏上旧弹幕
    var clearToken = 0
    /// 录像暂停时冻结弹幕
    var isPaused = false

    private func update(_ uiView: DanmakuHostView, coordinator: Coordinator) {
        uiView.apply(settings)
        uiView.isHidden = !isVisible
        uiView.setPaused(isPaused)
        if coordinator.clearToken != clearToken {
            coordinator.clearToken = clearToken
            coordinator.consumed = nil
            coordinator.didClear = true
            uiView.clear()
        }

        guard isVisible else {
            coordinator.consumed = messages.last?.id
            return
        }

        // 找到上次消费位置之后的新消息
        let pending: [LiveMessage]
        if let consumed = coordinator.consumed,
           let index = messages.lastIndex(where: { $0.id == consumed }) {
            pending = Array(messages[(index + 1)...])
        } else if coordinator.didClear {
            // 清屏后的消息都是新位置之后的，全部投放
            pending = messages
        } else {
            // 首次进入只渲染最近几条，避免一次性灌入历史弹幕
            pending = Array(messages.suffix(5))
        }
        if !messages.isEmpty { coordinator.didClear = false }

        for message in pending {
            uiView.emit(
                text: message.message,
                color: PlatformColor(
                    red: CGFloat(message.color.r) / 255,
                    green: CGFloat(message.color.g) / 255,
                    blue: CGFloat(message.color.b) / 255,
                    alpha: 1
                )
            )
        }
        coordinator.consumed = messages.last?.id
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var consumed: UUID?
        var clearToken = 0
        var didClear = false
    }
}

#if os(macOS)
extension DanmakuOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> DanmakuHostView {
        let view = DanmakuHostView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.settings = settings
        return view
    }
    func updateNSView(_ nsView: DanmakuHostView, context: Context) {
        update(nsView, coordinator: context.coordinator)
    }
}
#else
extension DanmakuOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> DanmakuHostView {
        let view = DanmakuHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.settings = settings
        return view
    }
    func updateUIView(_ uiView: DanmakuHostView, context: Context) {
        update(uiView, coordinator: context.coordinator)
    }
}
#endif
