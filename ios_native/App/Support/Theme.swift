import SwiftUI

/// 设计令牌，iOS 与 macOS 共用。界面是一张干净的白纸，颜色交给封面和画面；
/// 品牌橙只当"信号"：选中、进度、正在直播。
enum Theme {
    /// 斗鱼品牌橙，略降饱和以适配 Liquid Glass 的折射
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.24)
    /// 选中、当前项的底色
    static let accentSoft = accent.opacity(0.11)
    /// 可点对象的浅底：分区胶囊、分类图标、悬停
    static let softFill = Color.primary.opacity(0.045)
    /// 只在需要分组的地方出现的发丝线
    static let hairline = Color.primary.opacity(0.08)

    static let cardCorner: CGFloat = 12
    static let coverAspect: CGFloat = 16.0 / 9.0

    /// 短促的选中 / 按下手感；大面积移动用 `glide`
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let glide = Animation.spring(response: 0.4, dampingFraction: 0.9)

    /// 热度格式化：斗鱼热度量级大，统一压成「万」
    static func formatHot(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return "\(value)"
    }

    static func formatDuration(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// 加载阶段，替代散落各处的 isLoading / errorMessage 组合
enum LoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var errorText: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
