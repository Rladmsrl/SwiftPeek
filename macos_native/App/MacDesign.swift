import SwiftUI

/// Mac 专用的少量外观。颜色、圆角与动效统一来自 `Theme`；
/// 内容直接落在窗口底色上，Liquid Glass 只留给系统侧栏、工具栏和播放控件。
enum MacDesign {
    static let columns = [GridItem(.adaptive(minimum: 214, maximum: 400), spacing: 20, alignment: .top)]
}

/// 侧栏面板：一层浅底，不加描边和阴影
private struct MacPanel: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.background(Theme.softFill, in: .rect(cornerRadius: radius))
    }
}

/// 列表行、图块的悬停浅底。只改底色，不位移、不加阴影。
private struct MacHoverFill: ViewModifier {
    var radius: CGFloat
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(hovered ? Theme.softFill : .clear, in: .rect(cornerRadius: radius))
            .contentShape(.rect(cornerRadius: radius))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}

extension View {
    func macPanel(radius: CGFloat = 14) -> some View { modifier(MacPanel(radius: radius)) }
    func macHoverFill(radius: CGFloat = 10) -> some View { modifier(MacHoverFill(radius: radius)) }
}

/// 播放器控制条上的按钮：点击区域至少 30pt，悬停和按下时有浅色底，
/// 而不是只有图标那一小块能点中。
struct MacPlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacPlayerButton(configuration: configuration)
    }
}

private struct MacPlayerButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(minWidth: 30, minHeight: 30)
            .background(.white.opacity(configuration.isPressed ? 0.2 : hovered && isEnabled ? 0.12 : 0), in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

struct MacEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}
