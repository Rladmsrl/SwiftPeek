import SwiftUI

/// 设计令牌。集中管理颜色与圆角，避免各视图各写一套。
enum Theme {
    /// 斗鱼品牌橙，降低饱和度以适配 Liquid Glass 的折射
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.21)

    static let cardCorner: CGFloat = 14
    static let coverAspect: CGFloat = 16.0 / 9.0

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

/// 自适应列宽。
///
/// 刻意不读取 `UIScreen.main`（Apple 已声明在双屏设备上语义模糊、将被废弃），
/// 而是用 size class 决定卡片最小宽度，再交给 `.adaptive` 按实际容器宽度排布。
/// 这样在 iPhone 18 Pro 竖屏、横屏、iPhone Duo 内外屏以及 Split View 下都成立。
#if os(iOS)
struct AdaptiveGrid {
    let horizontalSizeClass: UserInterfaceSizeClass?

    var minimumCardWidth: CGFloat {
        horizontalSizeClass == .regular ? 220 : 160
    }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumCardWidth), spacing: 12)]
    }
}
#endif

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
