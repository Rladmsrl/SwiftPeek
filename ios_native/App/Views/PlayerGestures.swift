import AVFoundation
import SwiftUI
import UIKit

// MARK: - 场景桥接

/// 需要触达 UIKit 场景的能力集中在这里。
///
/// 亮度刻意走 `windowScene.screen` 而不是 `UIScreen.main`：
/// 后者在双屏设备上语义模糊，Apple 已明示将废弃。
@MainActor
enum SceneBridge {
    static var windowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static var brightness: Double {
        get { Double(windowScene?.screen.brightness ?? 0.5) }
        set { windowScene?.screen.brightness = CGFloat(min(max(newValue, 0), 1)) }
    }

    /// 请求界面旋转。iOS 16 起的官方做法，替代已废弃的
    /// `UIDevice.setValue(_:forKey:"orientation")` 私有写法。
    static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = windowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("[SceneBridge] 旋转请求被拒绝：\(error.localizedDescription)")
        }
    }

    // MARK: - 方向闸门

    /// AppDelegate 每次旋转都来读这个值。
    ///
    /// 默认值按设备族区分：这是设备能力差异（iPad 支持倒置竖屏），
    /// 与布局决策无关，因此这里用 idiom 判断不违反「布局只看 size class」的原则。
    static var allowedOrientations: UIInterfaceOrientationMask = defaultOrientations

    private static var defaultOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private static var orientationObserver: (any NSObjectProtocol)?

    /// 进入全屏：放开横屏并立即转过去
    static func enterLandscape() {
        allowedOrientations = .landscape
        requestOrientation(.landscapeRight)
    }

    /// 退出全屏。
    ///
    /// 只 `requestOrientation(.portrait)` 是不够的——那只是一次性请求，
    /// 之后系统仍按允许方向跟随重力：用户横握时会被立刻转回横屏，
    /// 而横屏又重新满足 compact 高度、再次进入全屏，结果是退不出来。
    /// 所以先把允许方向压到竖屏，等设备真的回到竖屏再放开。
    static func returnToPortrait() {
        allowedOrientations = .portrait
        requestOrientation(.portrait)
        releaseGateWhenDeviceReturnsToPortrait()
    }

    private static func releaseGateWhenDeviceReturnsToPortrait() {
        // 本来就竖着拿（用按钮进的全屏），无需等待
        if UIDevice.current.orientation.isPortrait {
            allowedOrientations = defaultOrientations
            return
        }
        guard orientationObserver == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard UIDevice.current.orientation.isPortrait else { return }
                allowedOrientations = defaultOrientations
                if let observer = orientationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    orientationObserver = nil
                    UIDevice.current.endGeneratingDeviceOrientationNotifications()
                }
            }
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

// MARK: - 手势捕获层

/// 全屏播放手势。
///
/// 直播没有可 seek 的时间轴，因此**不做横向拖动进度**——
/// 这一点与点播播放器不同，硬套会给出无法兑现的交互暗示。
struct PlayerGestureSurface: View {
    @Binding var volume: Double
    @Binding var hud: PlayerHUD?
    let isLocked: Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void

    /// 本次拖动锁定的调节类型。一次拖动只调一个量，
    /// 避免手指斜着滑时亮度和音量同时乱跳。
    @State private var activeKind: PlayerHUD.Kind?
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
                    let t = value.translation
                    // 纵向分量明显占优才认定为调节手势
                    guard abs(t.height) > abs(t.width) else { return }
                    let isLeftHalf = value.startLocation.x < size.width / 2
                    let kind: PlayerHUD.Kind = isLeftHalf ? .brightness : .volume
                    activeKind = kind
                    startValue = kind == .brightness ? SceneBridge.brightness : volume
                    anchorTranslation = t.height
                }

                guard let kind = activeKind else { return }
                // 纵向划过 70% 屏高对应满量程
                let moved = value.translation.height - anchorTranslation
                let delta = -moved / (size.height * 0.7)
                let newValue = min(max(startValue + delta, 0), 1)

                switch kind {
                case .brightness: SceneBridge.brightness = newValue
                case .volume: volume = newValue
                }
                hudDismissTask?.cancel()
                hud = PlayerHUD(kind: kind, value: newValue)
            }
            .onEnded { _ in
                activeKind = nil
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
