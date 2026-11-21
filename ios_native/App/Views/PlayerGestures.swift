import AVFoundation
import SimpleLiveKit
import SwiftUI
import UIKit

// MARK: - 播放器所在的场景

/// Per-window coordinator that keeps programmatic orientation overrides bounded to
/// outer/phone windowing modes and releases them back to `.all` before a foldable
/// display transitions to the inner screen (where iOS rejects programmatic rotation
/// with `UISceneErrorDomain` code 101).
@MainActor
private final class SceneOrientationCoordinator {
    private static let registry = NSMapTable<UIWindow, SceneOrientationCoordinator>.weakToStrongObjects()

    weak var window: UIWindow?
    private var state = PlayerOrientationState()
    private var observersInstalled = false
    private var traitRegistration: (any UITraitChangeRegistration)?

    static func forWindow(_ window: UIWindow?) -> SceneOrientationCoordinator? {
        guard let window else { return nil }
        if let existing = registry.object(forKey: window) {
            existing.installObserversIfNeeded(on: window)
            return existing
        }
        let coordinator = SceneOrientationCoordinator(window: window)
        registry.setObject(coordinator, forKey: window)
        coordinator.installObserversIfNeeded(on: window)
        return coordinator
    }

    private init(window: UIWindow) {
        self.window = window
    }

    private func installObserversIfNeeded(on window: UIWindow) {
        guard !observersInstalled else { return }
        observersInstalled = true

        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                self?.handleHingeUpdate(update.hinge)
            }
            window.addInteraction(interaction)
        }

        traitRegistration = window.registerForTraitChanges([UITraitHorizontalSizeClass.self]) { [weak self] (win: UIWindow, previous: UITraitCollection) in
            guard previous.horizontalSizeClass == .regular,
                  win.traitCollection.horizontalSizeClass == .compact else { return }
            self?.handleReturnedToCompactMode()
        }
    }

    func requestLandscapeFullscreen() {
        guard let scene = window?.windowScene else { return }
        let current = Self.direction(from: scene.effectiveGeometry.interfaceOrientation)
        guard let request = state.requestLandscapeFullscreen(current: current) else { return }
        submit(request, to: scene)
    }

    func restoreOrientationBeforeFullscreen() {
        guard let scene = window?.windowScene else { return }
        guard let request = state.restoreOrientationBeforeFullscreen() else { return }
        submit(request, to: scene)
    }

    func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = window?.windowScene, let target = Self.targetMask(from: mask) else { return }
        guard let request = state.requestExplicitOrientation(target) else { return }
        submit(request, to: scene)
    }

    @available(iOS 27.1, *)
    private func handleHingeUpdate(_ hinge: UIHinge?) {
        let request: PlayerOrientationState.Request?
        if let hinge {
            request = state.updateHinge(
                isAvailable: true,
                isClosed: hinge.status == .closed,
                isOpen: hinge.status == .partiallyOpen || hinge.status == .fullyOpen,
                angleRadians: Double(hinge.angle)
            )
        } else {
            request = state.updateHinge(isAvailable: false, isClosed: false, isOpen: false, angleRadians: 0)
        }
        guard let request, let scene = window?.windowScene else { return }
        submit(request, to: scene)
    }

    private func handleReturnedToCompactMode() {
        guard let request = state.sceneReturnedToCompactMode(),
              let scene = window?.windowScene else { return }
        submit(request, to: scene)
    }

    private func submit(_ request: PlayerOrientationState.Request, to scene: UIWindowScene) {
        let mask = Self.interfaceMask(from: request.mask)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            let ns = error as NSError
            let deniedByWindowingMode = ns.domain == UISceneError.errorDomain && (
                ns.code == UISceneError.Code.geometryRequestDenied.rawValue ||
                ns.code == UISceneError.Code.geometryRequestUnsupported.rawValue
            )
            LiveDiagnostics.record("ui.orientationRequestFailed", fields: [
                "code": String(ns.code)
            ])
            Task { @MainActor [weak self] in
                self?.state.recordRequestFailure(for: request, deniedByWindowingMode: deniedByWindowingMode)
            }
        }
    }

    private static func direction(from orientation: UIInterfaceOrientation) -> PlayerOrientationState.Direction {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .unknown
        }
    }

    private static func interfaceMask(from target: PlayerOrientationState.TargetMask) -> UIInterfaceOrientationMask {
        switch target {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .landscape: return .landscape
        case .all: return .all
        }
    }

    private static func targetMask(from mask: UIInterfaceOrientationMask) -> PlayerOrientationState.TargetMask? {
        switch mask {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .landscape: return .landscape
        case .all: return .all
        default: return nil
        }
    }
}

/// Each player reads the screen from its own current window, including after a fold.
@MainActor
final class PlayerSceneContext {
    weak var window: UIWindow? {
        didSet {
            // Attach the per-window hinge observer as soon as a player mounts so
            // unfolding releases any active orientation override before display switch.
            _ = SceneOrientationCoordinator.forWindow(window)
        }
    }

    var brightness: Double {
        get { Double(window?.windowScene?.screen.brightness ?? 0.5) }
        set { window?.windowScene?.screen.brightness = CGFloat(min(max(newValue, 0), 1)) }
    }

    func requestLandscapeFullscreen() {
        SceneOrientationCoordinator.forWindow(window)?.requestLandscapeFullscreen()
    }

    func restoreOrientationBeforeFullscreen() {
        SceneOrientationCoordinator.forWindow(window)?.restoreOrientationBeforeFullscreen()
    }

    func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        SceneOrientationCoordinator.forWindow(window)?.requestOrientation(mask)
    }
}

struct PlayerSceneReader: UIViewRepresentable {
    let context: PlayerSceneContext

    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.playerContext = self.context
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SceneView, context: Context) {
        view.playerContext = self.context
        self.context.window = view.window
    }

    final class SceneView: UIView {
        weak var playerContext: PlayerSceneContext?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            playerContext?.window = window
        }
    }
}

// MARK: - HUD 数据

struct PlayerHUD: Equatable {
    enum Kind: Equatable {
        case brightness
        case volume

        var icon: String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .volume: return "speaker.wave.2.fill"
            }
        }

        var mutedIcon: String {
            switch self {
            case .brightness: return "sun.min"
            case .volume: return "speaker.slash.fill"
            }
        }

        var label: String {
            switch self {
            case .brightness: return "亮度"
            case .volume: return "音量"
            }
        }
    }

    var kind: Kind
    var value: Double
}

/// 亮度 / 音量调节时居中显示的指示条
struct PlayerHUDView: View {
    let hud: PlayerHUD

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hud.value <= 0.001 ? hud.kind.mutedIcon : hud.kind.icon)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(2, 120 * hud.value))
            }
            .frame(width: 120, height: 4)

            Text("\(hud.kind.label) \(Int(hud.value * 100))%")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 16))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }
}

// MARK: - 浮层按钮

/// 播放器浮层上的玻璃按钮。视觉与触控区域都不小于 44pt：
/// 图标是圆形，文字按内容加宽成胶囊。系统 small 玻璃按钮只有约 28pt，
/// 全屏时贴近屏幕边缘很难点中。前景与菜单统一为白色，不随全局橙色着色。
struct PlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.playerControlChrome()
    }
}

extension View {
    /// 菜单不走 ButtonStyle，单独套用同一外观
    func playerControlChrome() -> some View {
        modifier(PlayerControlChrome())
    }
}

private struct PlayerControlChrome: ViewModifier {
    static let minimumSide: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .tint(.white)
            .lineLimit(1)
            .fixedSize()
            // 20pt 以内的图标恰好落成 44pt 正圆
            .padding(.horizontal, 12)
            .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - 手势捕获层

/// 全屏播放手势。
///
/// 直播没有可 seek 的时间轴，因此**不做横向拖动进度**——
/// 这一点与点播播放器不同，硬套会给出无法兑现的交互暗示。
struct PlayerGestureSurface: View {
    @Binding var volume: Double
    @Binding var hud: PlayerHUD?
    let sceneContext: PlayerSceneContext
    let isLocked: Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void

    /// 本次拖动锁定的调节类型。一次拖动只调一个量，
    /// 避免手指斜着滑时亮度和音量同时乱跳。
    @State private var activeKind: PlayerHUD.Kind?
    /// 起手偏横向时拒绝本次拖动，避免斜滑中段突然接管亮度 / 音量。
    @State private var dragRejected = false
    @State private var startValue: Double = 0
    /// 手势被识别那一刻已累积的位移。后续增量要从这里算起，
    /// 否则识别成功的瞬间数值会先跳一格（minimumDistance 那 8pt 会被算进去）。
    @State private var anchorTranslation: CGFloat = 0
    @State private var hudDismissTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(.rect)
                .simultaneousGesture(dragGesture(in: geo.size))
                .onTapGesture(count: 2) {
                    guard !isLocked else { return }
                    onDoubleTap()
                }
                .onTapGesture {
                    // 锁定时单击仍然放行，否则没有入口唤出解锁按钮
                    onSingleTap()
                }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isLocked, size.height > 0 else { return }

                if activeKind == nil {
                    guard !dragRejected else { return }
                    let t = value.translation
                    // 纵向分量明显占优才认定为调节手势；起手横向则整次拖动忽略
                    guard abs(t.height) > abs(t.width) else {
                        dragRejected = true
                        return
                    }
                    let isLeftHalf = value.startLocation.x < size.width / 2
                    let kind: PlayerHUD.Kind = isLeftHalf ? .brightness : .volume
                    activeKind = kind
                    startValue = kind == .brightness ? sceneContext.brightness : volume
                    anchorTranslation = t.height
                }

                guard let kind = activeKind else { return }
                // 纵向划过 70% 屏高对应满量程
                let moved = value.translation.height - anchorTranslation
                let delta = -moved / (size.height * 0.7)
                let newValue = min(max(startValue + delta, 0), 1)

                switch kind {
                case .brightness: sceneContext.brightness = newValue
                case .volume: volume = newValue
                }
                hudDismissTask?.cancel()
                hud = PlayerHUD(kind: kind, value: newValue)
            }
            .onEnded { _ in
                activeKind = nil
                dragRejected = false
                scheduleHUDDismiss()
            }
    }

    private func scheduleHUDDismiss() {
        hudDismissTask?.cancel()
        hudDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { hud = nil }
        }
    }
}
