import SwiftUI

/// One split control in every live/replay toolbar. Keep quick visibility separate
/// from editing so the existing one-tap action is preserved.
struct PlayerDanmakuControl: View {
    @Binding var isVisible: Bool
    var onPresentationChange: (Bool) -> Void = { _ in }
    var onToggle: () -> Void = {}
    @State private var isPresented = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var controlHeight: CGFloat {
        #if os(macOS)
        30
        #else
        44
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isVisible.toggle()
                onToggle()
            } label: {
                Text("弹幕").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(isVisible ? 1 : 0.45))
                    .frame(width: max(36, controlHeight), height: controlHeight).contentShape(.rect)
            }
            .accessibilityLabel(isVisible ? "隐藏弹幕" : "显示弹幕")
            .accessibilityValue(isVisible ? "已开启" : "已关闭")
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 12)
                .accessibilityHidden(true)
            Button { isPresented = true } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: controlHeight == 30 ? 24 : 44, height: controlHeight).contentShape(.rect)
            }
            .accessibilityLabel("弹幕设置")
            .help("字体、字号、可见度与画中画弹幕")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                presentation
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .modifier(DanmakuControlSurface())
        .fixedSize()
        .onChange(of: isPresented) { _, value in onPresentationChange(value) }
        .onDisappear { if isPresented { onPresentationChange(false) } }
    }

    @ViewBuilder private var presentation: some View {
        #if os(macOS)
        PlayerDanmakuPanel(isVisible: $isVisible) { isPresented = false }
            .frame(width: 320, height: 560)
            .preferredColorScheme(.dark)
        #else
        PlayerDanmakuPanel(isVisible: $isVisible) { isPresented = false }
            .frame(idealWidth: 320, maxWidth: 380,
                   idealHeight: 480, maxHeight: 560)
            .presentationCompactAdaptation(verticalSizeClass == .compact ? .popover : .sheet)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        #endif
    }
}

private struct DanmakuControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(.white.opacity(0.09), in: .capsule)
        #else
        content.glassEffect(.regular, in: .capsule)
        #endif
    }
}

private struct PlayerDanmakuPanel: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isVisible: Bool
    let close: () -> Void

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("弹幕设置").font(.headline)
                        Text("直播、录像与小窗共用，自动保存").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 28, height: 28)
                            .background(.primary.opacity(0.06), in: .circle)
                            .contentShape(.circle)
                    }.buttonStyle(.plain).accessibilityLabel("关闭弹幕设置")
                }

                preview

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $isVisible) { Label("画面弹幕", systemImage: "text.bubble") }
                    Toggle(isOn: $settings.data.pictureInPictureDanmaku) {
                        Label("画中画显示弹幕", systemImage: "pip")
                    }
                    Text(pipHint).font(.caption2).foregroundStyle(.secondary)
                }.font(.subheadline).toggleStyle(.switch)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("字体").font(.subheadline.weight(.medium))
                    Picker("字体", selection: $settings.data.danmakuFont) {
                        ForEach(DanmakuFont.allCases) { font in
                            Text(font.label).font(Font(font.makeFont(size: 13))).tag(font)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                }

                adjustment("字号", value: $settings.data.danmakuFontSize, range: 11...32,
                           step: 1, display: "\(Int(settings.data.danmakuFontSize))")
                adjustment("可见度", value: $settings.data.danmakuOpacity, range: 0.2...1,
                           step: 0.05, display: "\(Int((settings.data.danmakuOpacity * 100).rounded()))%")

            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.primary)
        .controlSize(.regular)
        .tint(.accentColor)
        .environment(\.colorScheme, .dark)
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.08, green: 0.15, blue: 0.22), Color(red: 0.04, green: 0.06, blue: 0.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("效果预览").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 10).padding(.top, 7)
            Text("弹幕刚刚好 Aa")
                .font(Font(settings.data.danmakuFont.makeFont(size: settings.data.danmakuFontSize)))
                .foregroundStyle(.white).opacity(settings.data.danmakuOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 12)
        }
        .frame(height: 72).clipShape(.rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .accessibilityLabel("弹幕效果预览，\(settings.data.danmakuFont.label)，字号 \(Int(settings.data.danmakuFontSize))，可见度 \(Int(settings.data.danmakuOpacity * 100))%")
    }

    private var pipHint: String {
        if !isVisible { return "小窗弹幕需同时开启画面弹幕。" }
        #if os(iOS)
        return "小窗弹幕适用于直播和录像，开启后会增加耗电。"
        #else
        return "进入小窗后显示，适用于直播和录像。"
        #endif
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}
