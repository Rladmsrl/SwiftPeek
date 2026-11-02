import ImageIO
import SimpleLiveKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - 视图持有的重对象

/// 播放器、会话这类重对象只在第一次用到时创建一次。
/// `State(initialValue:)` 不是惰性的：父视图每次重算都会先造一个完整的播放器再丢掉。
@MainActor
@Observable
final class LazyViewObject<Value: AnyObject> {
    @ObservationIgnored private var stored: Value?
    private var revision = 0

    func callAsFunction(_ make: () -> Value) -> Value {
        _ = revision
        if let stored { return stored }
        let value = make()
        stored = value
        return value
    }

    /// 丢弃当前对象，下次读取时重建；读取过它的视图随之刷新。
    func reset() {
        stored = nil
        revision += 1
    }
}

// MARK: - 远程图片

struct RemoteImageKey: Hashable, Sendable {
    let url: URL
    /// 缩略图最长边的像素数，按 64 取整，尺寸微调时共用同一份缓存
    let pixels: Int
    var name: String { "\(pixels)|\(url.absoluteString)" }
}

/// 封面、头像和分类图标共用：按显示像素用 ImageIO 生成缩略图并留在内存里。
/// 网格回收单元格、切回 Tab 时直接复用，不再重新下载、整图解码和再次淡入。
final class RemoteImageCache: @unchecked Sendable {
    static let shared = RemoteImageCache()
    private let images = NSCache<NSString, CGImage>()
    private let session: URLSession

    init() {
        images.totalCostLimit = 48 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RemoteImages", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, directory: directory)
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func cached(_ key: RemoteImageKey) -> CGImage? { images.object(forKey: key.name as NSString) }

    /// 在调用方之外的执行器上下载与解码，不占主线程。
    func image(for key: RemoteImageKey) async throws -> CGImage {
        if let hit = cached(key) { return hit }
        let (data, response) = try await session.data(from: key.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        guard let image = Self.thumbnail(data, maxPixels: key.pixels) else { throw URLError(.cannotDecodeContentData) }
        images.setObject(image, forKey: key.name as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    private static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 远程图片。缓存命中时直接显示；第一次下载完成时按 `animation` 淡入一次。
/// `placeholder` 的参数表示是否加载失败。
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: String
    var animation: Animation?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: (Bool) -> Placeholder

    private struct Loaded { let url: String; let image: CGImage }
    @State private var loaded: Loaded?
    @State private var failedURL: String?
    @State private var points: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    init(url: String, animation: Animation? = nil,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping (Bool) -> Placeholder) {
        self.url = url
        self.animation = animation
        self.content = content
        self.placeholder = placeholder
    }

    private var key: RemoteImageKey? {
        guard points > 0, let parsed = URL(string: url), parsed.scheme != nil else { return nil }
        let pixels = max(64, Int((points * displayScale / 64).rounded(.up)) * 64)
        return RemoteImageKey(url: parsed, pixels: pixels)
    }

    var body: some View {
        let key = key
        let image = key.flatMap(RemoteImageCache.shared.cached) ?? (loaded?.url == url ? loaded?.image : nil)
        ZStack {
            if let image {
                content(Image(decorative: image, scale: displayScale)).transition(.opacity)
            } else {
                placeholder(failedURL == url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { max($0.size.width, $0.size.height) } action: { points = $0 }
        .task(id: key) {
            guard let key, RemoteImageCache.shared.cached(key) == nil else { return }
            // 已有同一地址、足够大的图（例如窗口缩小）就不再重新解码
            if let loaded, loaded.url == url, max(loaded.image.width, loaded.image.height) >= key.pixels { return }
            let url = url
            do {
                let image = try await RemoteImageCache.shared.image(for: key)
                guard !Task.isCancelled else { return }
                withAnimation(animation) { loaded = Loaded(url: url, image: image) }
            } catch {
                guard !Task.isCancelled, loaded?.url != url else { return }
                failedURL = url
            }
        }
    }
}

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
                RemoteImage(url: url, animation: reduceMotion ? nil : .easeOut(duration: 0.25)) { image in
                    image.resizable().scaledToFill()
                        .scaleEffect(highlighted && !reduceMotion ? 1.04 : 1)
                } placeholder: { failed in
                    if failed {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    } else {
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
        RemoteImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: { _ in
            ZStack {
                Theme.softFill
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
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
                // 窄侧栏里由左侧的主播名和统计让位，按钮文字不折行
                .lineLimit(1)
                .fixedSize()
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
            RemoteImage(url: category.pic ?? "") { image in
                image.resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 10))
                    .padding(5)
            } placeholder: { _ in
                Image(systemName: "gamecontroller")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
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
