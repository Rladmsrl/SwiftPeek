import SwiftUI

/// Content stays legible; native Liquid Glass is reserved for navigation and controls.
enum MacDesign {
    static let accent = Color(red: 0.98, green: 0.38, blue: 0.20)
    static let green = Color(red: 0.20, green: 0.72, blue: 0.49)
    static let corner: CGFloat = 20
    static let columns = [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 20)]
}

struct MacBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.095) : Color(red: 0.97, green: 0.97, blue: 0.98))
            GeometryReader { geometry in
                RadialGradient(colors: [MacDesign.accent.opacity(scheme == .dark ? 0.11 : 0.06), .clear],
                               center: .topLeading, startRadius: 0, endRadius: geometry.size.width * 0.65)
                RadialGradient(colors: [Color.indigo.opacity(scheme == .dark ? 0.08 : 0.04), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: geometry.size.width * 0.6)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

private struct MacSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.85),
                        in: .rect(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.055), lineWidth: 1) }
    }
}

private struct MacHover: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(MacDesign.accent.opacity(hovered ? 0.4 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 15, y: 6)
            .offset(y: hovered && !reduceMotion ? -2 : 0)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }
}

extension View {
    func macSurface(radius: CGFloat = MacDesign.corner) -> some View { modifier(MacSurface(radius: radius)) }
    func macHover(radius: CGFloat = MacDesign.corner) -> some View { modifier(MacHover(radius: radius)) }
}

struct MacLiveBadge: View {
    var title = "直播中"
    var live = true
    var body: some View {
        HStack(spacing: 5) {
            if live {
                HStack(alignment: .center, spacing: 2) {
                    ForEach([CGFloat(5), 10, 7], id: \.self) { height in
                        Capsule().frame(width: 2, height: height)
                    }
                }.frame(width: 10, height: 12)
            } else {
                Circle().frame(width: 5, height: 5)
            }
            Text(title).font(.system(size: 10, weight: .semibold))
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(live ? .white : .secondary)
            .background(live ? MacDesign.accent : Color.primary.opacity(0.06), in: .capsule)
    }
}

struct MacAvatar: View {
    let url: String
    let name: String
    var size: CGFloat = 40
    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFill() }
            else {
                ZStack {
                    LinearGradient(colors: [MacDesign.accent.opacity(0.2), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(name.prefix(1))).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(MacDesign.accent)
                }
            }
        }.frame(width: size, height: size).clipShape(.circle)
    }
}

struct MacIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 36).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? MacDesign.accent : .primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help).accessibilityLabel(help)
    }
}

struct MacEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(MacDesign.accent)
                .frame(width: 76, height: 76)
                .background(MacDesign.accent.opacity(0.07), in: .rect(cornerRadius: 24))
            VStack(spacing: 7) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}
