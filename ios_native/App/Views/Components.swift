import SimpleLiveKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - 封面

/// 房间封面。固定 16:9，加载中显示浅底占位，图片到达时淡入一次；失败显示图标而不是空白。
/// `highlighted` 让图片在圆角内轻微放大，用作 Mac 悬停反馈，不改变卡片尺寸。
struct CoverImage: View {
    let url: String
    var cornerRadius: CGFloat = Theme.cardCorner
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Theme.softFill)
            .aspectRatio(Theme.coverAspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url),
                           transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .scaleEffect(highlighted && !reduceMotion ? 1.04 : 1)
                            .transition(.opacity)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    default:
                        Color.clear
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: highlighted)
    }
}

/// 封面角上的说明。只用于例外状态（轮播、分段数、时长），直播是默认，不再标出。
struct CoverTag: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(title).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.5), in: .capsule)
    }
}

// MARK: - 房间卡片

extension LiveRoomStatus {
    var label: String {
        switch self {
        case .unknown, .loopCandidate: "状态待确认"
        case .live: "直播中"
        case .looping: "轮播"
        case .offline: "未开播"
        }
    }

    /// 封面角标：直播是默认状态不标；未确认的不猜。
    var coverSymbol: String? {
        switch self {
        case .looping: "repeat"
        case .offline: "moon.zzz"
        case .unknown, .live, .loopCandidate: nil
        }
    }
}

/// 封面即卡片：不加底板、描边和阴影，文字直接落在页面上。
/// 标题一行，第二行是主播与热度（或观看时间），每张卡高度一致。
struct RoomCard: View {
    let room: LiveRoomItem
    var watchedAt: Date?
    var highlighted = false
    @Environment(AppSettings.self) private var settings
    private var confirmations: RoomStatusConfirmations { .shared }

    var body: some View {
        let status = confirmations.status(of: room)
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(url: room.cover, highlighted: highlighted)
                .overlay(alignment: .topLeading) {
                    if let symbol = status.coverSymbol {
                        CoverTag(title: status.label, symbol: symbol).padding(8)
                    }
                }
                .task(id: room.roomID) { await confirmations.confirmIfNeeded(room) }

            Text(room.title)
                .font(Self.titleFont)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.top, 8)

            HStack(spacing: 6) {
                Text(room.userName).lineLimit(1)
                Spacer(minLength: 4)
                if let watchedAt {
                    Text(watchedAt, style: .relative).lineLimit(1)
                } else if settings.data.showHotBadge, room.online > 0 {
                    Label(Theme.formatHot(room.online), systemImage: "flame")
                        .labelStyle(CompactLabelStyle())
                        .monospacedDigit()
                }
            }
            .font(Self.metaFont)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    static let titleFont = Font.system(size: 14, weight: .medium)
    static let metaFont = Font.system(size: 12)
    #else
    static let titleFont = Font.subheadline.weight(.medium)
    static let metaFont = Font.caption
    #endif
}

/// 图标与文字贴得更近的 Label，用在元信息行里
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// 卡片和图块的按下手感：缩到 0.97 再弹回，按下即时生效
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : Theme.snap, value: configuration.isPressed)
    }
}

// MARK: - 主播

/// 头像。加载前显示名字首字，直播中时外圈一道橙色细环。
struct AvatarImage: View {
    let url: String
    var name: String = ""
    var size: CGFloat = 40
    var live = false

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.softFill
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .padding(live ? 2.5 : 0)
        .overlay {
            if live { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
        }
        .accessibilityHidden(true)
    }
}

/// 正在直播的信号：一个橙点。`pulses` 时外圈缓慢扩散，减少动态效果时静止。
/// 无限动画每帧都要重算，一屏只留一个会动的（分组标题旁），列表行里用静态点。
struct LiveDot: View {
    var size: CGFloat = 7
    var pulses = false
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 0.9)
            }
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulsing = true }
            }
            .accessibilityLabel("直播中")
    }
}

/// 关注按钮属于主播信息行：未关注时是品牌色玻璃按钮，关注后退成普通玻璃，心形轻跳一下。
/// 使用系统玻璃按钮样式，尺寸与形状随平台和控件大小自适应。
struct FollowButton: View {
    let isFollowed: Bool
    let action: () -> Void

    var body: some View {
        if isFollowed {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.glassProminent).tint(Theme.accent)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(isFollowed ? "已关注" : "关注", systemImage: isFollowed ? "heart.fill" : "heart")
                .symbolEffect(.bounce, value: isFollowed)
                #if os(iOS)
                .font(.subheadline.weight(.semibold))
                #endif
        }
        .accessibilityLabel(isFollowed ? "取消关注" : "关注")
    }
}

struct AnchorRow: View {
    let anchor: LiveAnchorItem

    var body: some View {
        HStack(spacing: 12) {
            AvatarImage(url: anchor.avatar, name: anchor.userName, size: 44, live: anchor.isLive)

            VStack(alignment: .leading, spacing: 3) {
                Text(anchor.userName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if anchor.status != .unknown {
                    Text(anchor.status.label)
                        .font(.caption)
                        .foregroundStyle(anchor.isLive ? Theme.accent : .secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

// MARK: - 列表自动刷新

extension View {
    /// 列表只在加载那一刻准确。App 长时间开着时，回到前台（Mac 切回本应用）由调用方
    /// 判断是否过期并重新加载。
    func refreshesWhenReturning(_ refresh: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReturningRefresh(refresh: refresh))
    }
}

private struct ReturningRefresh: ViewModifier {
    let refresh: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
            #endif
    }
}

// MARK: - 分区与分类

struct ChipItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

/// 横向分区选择。选中项是一块玻璃，切换时在选项之间形变滑动；字重不变，避免宽度跳动。
struct ChipBar<ID: Hashable>: View {
    let items: [ChipItem<ID>]
    @Binding var selection: ID?
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        let selected = item.id == selection
                        Button {
                            withAnimation(reduceMotion ? nil : Theme.snap) { selection = item.id }
                        } label: {
                            Text(item.title)
                                .font(Self.font)
                                .foregroundStyle(selected ? Theme.accent : .secondary)
                                .padding(.horizontal, Self.height * 0.42)
                                .frame(height: Self.height)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.1)).interactive() : .identity,
                                     in: .capsule)
                        .glassEffectID(selected ? "selection" : "chip-\(String(describing: item.id))", in: glass)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
    }

    #if os(macOS)
    private static var height: CGFloat { 32 }
    private static var font: Font { .system(size: 13, weight: .medium) }
    #else
    private static var height: CGFloat { 40 }
    private static var font: Font { .subheadline.weight(.medium) }
    #endif
}

/// 分类图块：图标在浅底方块里，名字在下面，不再套卡片。
struct CategoryTile: View {
    let category: LiveSubCategory
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// 分类图标大多按浅底设计；深色模式下用一块浅色底板，深色透明 logo 才看得见
    private var plate: Color {
        if highlighted { return Theme.accentSoft }
        return colorScheme == .dark ? Color(white: 0.86) : Theme.softFill
    }

    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: URL(string: category.pic ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: 10))
                        .padding(5)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.icon, height: Self.icon)
            .background(plate, in: .rect(cornerRadius: 14))
            .scaleEffect(highlighted && !reduceMotion ? 1.05 : 1)
            .animation(reduceMotion ? nil : Theme.snap, value: highlighted)

            Text(category.name)
                .font(Self.font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    #if os(macOS)
    private static let icon: CGFloat = 60
    private static let font = Font.system(size: 12.5)
    #else
    private static let icon: CGFloat = 60
    private static let font = Font.footnote
    #endif
}

// MARK: - 高频数据

/// 观察边界：内容在这个视图自己的 body 里求值，读到的 @Observable 属性只让它失效。
/// 用来包住播放进度、当前章节这类每秒变化几次的小块，避免整页跟着重算。
struct ObservationScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// 屏上弹幕层。只在自己的 body 里读 `store.messages`：弹幕每 80ms 合并一批，
/// 放在页面 body 里读会让整页（控制条、信息行、工具栏）跟着每批重算。
struct LiveDanmakuLayer: View {
    let store: RoomStore
    let settings: DanmakuSettings
    let isVisible: Bool

    var body: some View {
        DanmakuOverlay(messages: store.messages, settings: settings, isVisible: isVisible)
            .allowsHitTesting(false)
    }
}

// MARK: - 状态视图

/// 统一的加载 / 失败 / 空态。失败一定给出可重试入口和真实错误文案。
struct PhaseStateView: View {
    let phase: LoadPhase
    let isEmpty: Bool
    var emptyText: String = "暂无内容"
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .loading where isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
        case .failed(let message):
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
            }
        case .loaded where isEmpty:
            ContentUnavailableView(emptyText, systemImage: "tray")
        default:
            EmptyView()
        }
    }
}
