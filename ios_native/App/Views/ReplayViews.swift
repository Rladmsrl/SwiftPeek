import SimpleLiveKit
import SwiftUI

// MARK: - 导航目的地

extension View {
    /// 直播间与录像的导航目的地。每个 NavigationStack 注册一次。
    func liveDestinations() -> some View {
        navigationDestination(for: RoomRoute.self) { route in
            RoomView(roomID: route.roomID, fallbackTitle: route.title)
        }
        .navigationDestination(for: ReplayRoute.self) { route in
            if route.hashID == nil, let roomID = route.roomID {
                ReplayListView(roomID: roomID)
            } else {
                ReplayView(route: route)
            }
        }
    }
}

// MARK: - 录像列表

struct ReplayListView: View {
    @State private var store: ReplayListStore
    @State private var progress = ReplayProgressStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(roomID: String) {
        _store = State(initialValue: ReplayListStore(roomID: roomID))
    }

    var body: some View {
        ScrollView {
            if let author = store.author {
                HStack(spacing: 12) {
                    AvatarImage(url: author.avatar, name: author.name, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(author.name).font(.headline)
                        Text("直播录像 · 弹幕随进度回放").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            ResponsiveMediaGrid(minimumWidth: horizontalSizeClass == .regular ? 300 : 280, spacing: 16) {
                ForEach(store.shows) { show in
                    if let first = show.videos.first {
                        NavigationLink(value: ReplayRoute(hashID: first.hashID, roomID: store.author?.roomID ?? store.roomID)) {
                            ReplayShowCard(show: show, fraction: progress.fraction(for: first.hashID))
                        }
                        .buttonStyle(PressableStyle())
                        .task { await store.loadMoreIfNeeded(current: show) }
                    }
                }
            }
            .padding(16)
            if store.isLoadingMore { ProgressView().padding(.bottom, 24) }
            PhaseStateView(phase: store.phase, isEmpty: store.shows.isEmpty, emptyText: "这位主播还没有公开录像") {
                Task { await store.refresh() }
            }
        }
        .navigationTitle("录像")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { if store.shows.isEmpty { await store.refresh() } }
    }
}

/// 一场直播的卡片：封面上标出总时长与分段数，底部是上次看到的位置
struct ReplayShowCard: View {
    let show: DouyuReplayShow
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(url: show.videos.first?.cover ?? "")
                .overlay(alignment: .bottomTrailing) {
                    if !show.totalDuration.isEmpty {
                        CoverTag(title: show.totalDuration).padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if show.partCount > 1 {
                        CoverTag(title: "\(show.partCount) 段", symbol: "square.stack").padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.3))
                                Rectangle().fill(Theme.accent).frame(width: geometry.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(.rect(bottomLeadingRadius: Theme.cardCorner, bottomTrailingRadius: Theme.cardCorner))
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(show.sessionLabel.isEmpty ? show.title : show.sessionLabel)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text([show.relativeDate, show.startClock].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 8)
            if !show.title.isEmpty {
                Text(show.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .contentShape(.rect)
    }
}

// MARK: - 录像播放

private enum ReplayPanel: String, CaseIterable, Identifiable {
    case danmaku = "弹幕", chapters = "章节", episodes = "选集"
    var id: Self { self }
}

struct ReplayView: View {
    let route: ReplayRoute

    @State private var session = ReplaySession()
    @State private var list: ReplayListStore?
    @State private var progress = ReplayProgressStore.shared
    @State private var panel: ReplayPanel = .danmaku
    @State private var controlsVisible = true
    @State private var showingDanmakuSettings = false
    @State private var hideTask: Task<Void, Never>?
    @State private var wantsFullscreen = false
    @State private var hud: PlayerHUD?
    @State private var homeTab: AppTab?
    @State private var started = false

    @State private var sceneContext = PlayerSceneContext()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    init(route: ReplayRoute) {
        self.route = route
        _list = State(initialValue: route.roomID.map { ReplayListStore(roomID: $0) })
    }

    private var player: ReplayPlayer { session.player }
    private var detail: DouyuReplayDetail? { session.detail }
    private var isFullscreen: Bool { wantsFullscreen }
    private var roomID: String? {
        if let id = detail?.roomID, !id.isEmpty { return id }
        return route.roomID
    }

    var body: some View {
        AdaptivePlaybackContainer(fullscreen: isFullscreen) {
            playerSurface(fullscreen: isFullscreen)
        } companion: {
            PlaybackCompanion {
                infoSection
            } content: {
                VStack(spacing: 0) {
                    panelPicker
                    panelContent
                }
            }
        }
        .background(PlayerSceneReader(context: sceneContext))
        .navigationTitle(detail?.authorName ?? "录像")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar, .tabBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .defersSystemGestures(on: isFullscreen ? .vertical : [])
        .toolbar {
            if let roomID {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: RoomRoute(roomID: roomID, title: detail?.authorName ?? "直播间")) {
                        Label("直播间", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("进入直播间")
                }
            }
        }
        .task { start() }
        .onDisappear {
            hideTask?.cancel()
            if MobilePlaybackInterruption.shared.isActive { return }
            // 切 Tab 只是被盖住，不打断播放；真正离开时暂停并记住进度
            let isTabSwitch = homeTab != nil && router.selectedTab != homeTab
            guard !isTabSwitch, !player.isPiPActive else { return }
            if isFullscreen { exitFullscreen() }
            player.pause()
        }
        .onChange(of: detail?.roomID) { _, id in
            guard list == nil, let id, !id.isEmpty else { return }
            let store = ReplayListStore(roomID: id)
            list = store
            Task { await store.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: player.setBackgrounded(true, keepAudio: settings.data.backgroundAudio)
            case .active: player.setBackgrounded(false, keepAudio: true)
            default: break
            }
        }
        .onChange(of: settings.data.backgroundAudio) { _, enabled in
            player.setBackgrounded(scenePhase == .background, keepAudio: enabled)
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleHide() } else { controlsVisible = true }
        }
        .onChange(of: settings.data.autoPictureInPicture) { player.preparePiP(automatic: settings.data.autoPictureInPicture) }
    }

    private func start() {
        if homeTab == nil { homeTab = router.selectedTab }
        guard !started else { return }
        started = true
        session.configure(settings: settings)
        player.setBackgrounded(scenePhase == .background, keepAudio: settings.data.backgroundAudio)
        if let hashID = route.hashID { session.open(hashID: hashID, start: route.start) }
        if let list { Task { await list.refresh() } }
    }

    // MARK: 播放区

    private func playerSurface(fullscreen: Bool) -> some View {
        @Bindable var player = player
        return ZStack {
            Color.black
            ReplayVideoView(player: player) { player.preparePiP(automatic: settings.data.autoPictureInPicture) }
                .allowsHitTesting(false)
            if let feed = session.feed {
                DanmakuOverlay(messages: feed.messages, settings: settings.danmakuSettings,
                               isVisible: session.isDanmakuVisible,
                               clearToken: feed.clearToken, isPaused: !player.isPlaying)
                    .id(session.hashID)
                    .allowsHitTesting(false)
            }
            if fullscreen {
                PlayerGestureSurface(volume: $player.volume, hud: $hud, sceneContext: sceneContext, isLocked: false,
                                     onSingleTap: toggleControls, onDoubleTap: { player.togglePlay() })
            } else {
                Color.clear.contentShape(.rect)
                    .onTapGesture(count: 2) { player.togglePlay() }
                    .onTapGesture { toggleControls() }
            }
            statusOverlay
            if let hud { PlayerHUDView(hud: hud) }
            if controlsVisible || !player.isPlaying {
                controlsOverlay(fullscreen: fullscreen).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private var showsTransport: Bool {
        guard session.phase == .loaded else { return false }
        switch player.state {
        case .loading, .failed, .ended, .idle: return false
        default: return true
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if case .failed(let message) = session.phase {
            statusCard(text: message, action: "重试") { session.retry() }
        } else if session.phase == .loading || player.state == .loading {
            ProgressView().controlSize(.large).tint(.white)
        } else {
            switch player.state {
            case .failed(let message):
                statusCard(text: "播放中断：\(message)", action: "重新连接") { session.retry() }
            case .buffering:
                ProgressView().tint(.white)
            case .ended:
                VStack(spacing: 12) {
                    Text("这段录像已播完").font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        Button("重新播放", systemImage: "arrow.counterclockwise") { session.seek(to: 0); player.play() }
                            .buttonStyle(.glass)
                        if let next = session.nextSegment {
                            Button("下一段", systemImage: "forward.end.fill") { session.open(hashID: next.hashID, start: 0) }
                                .buttonStyle(.glassProminent)
                        }
                    }.font(.caption)
                }.foregroundStyle(.white)
            case .idle where session.hashID == nil:
                Text("选择一段录像").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            default:
                EmptyView()
            }
        }
    }

    private func statusCard(text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title3)
            Text(text).font(.caption).multilineTextAlignment(.center).padding(.horizontal, 24)
            Button(action, action: perform).buttonStyle(.glass).font(.caption)
        }.foregroundStyle(.white)
    }

    private func controlsOverlay(fullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if fullscreen {
                    Button { exitFullscreen() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel("退出全屏")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(detail?.title ?? "录像").font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(session.currentChapter?.title ?? detail?.authorName ?? "")
                            .font(.caption2).opacity(0.75).lineLimit(1)
                    }.foregroundStyle(.white).shadow(radius: 3)
                }
                Spacer(minLength: 0)
                topButtons
            }
            Spacer(minLength: 0)
            if showsTransport {
                HStack(spacing: fullscreen ? 56 : 36) {
                    transportButton("gobackward.10", size: 18, label: "后退 10 秒") { session.skip(by: -10) }
                    transportButton(player.isPlaying ? "pause.fill" : "play.fill", size: 24, label: player.isPlaying ? "暂停" : "播放") {
                        player.togglePlay()
                    }
                    transportButton("goforward.10", size: 18, label: "前进 10 秒") { session.skip(by: 10) }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                HStack {
                    Text("\(ReplayPlayer.format(player.displayTime)) / \(ReplayPlayer.format(session.duration))")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                    Spacer()
                    if let next = session.nextSegment, fullscreen {
                        Button { session.open(hashID: next.hashID, start: 0) } label: {
                            Label("下一段", systemImage: "forward.end.fill")
                                .font(.footnote.weight(.medium)).foregroundStyle(.white)
                                .frame(minHeight: 44).padding(.horizontal, 8).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    // 贴着进度条，不加玻璃底；热区仍保证 44pt
                    Button { fullscreen ? exitFullscreen() : enterFullscreen() } label: {
                        Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -10)
                    .accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
                }
                ReplayScrubber(time: player.displayTime, duration: session.duration, buffered: player.bufferedTime,
                               heat: session.heat.bins, chapters: session.chapters) { target in
                    session.seek(to: target)
                    scheduleHide()
                }
                .disabled(session.phase != .loaded)
            }
        }
        .padding(.horizontal, fullscreen ? 20 : 12)
        .padding(.top, fullscreen ? 12 : 10)
        .padding(.bottom, fullscreen ? 6 : 2)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 70)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 90)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var topButtons: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                PlayerDanmakuControl(isVisible: Binding(get: { session.isDanmakuVisible }, set: { session.isDanmakuVisible = $0 }),
                                     onPresentationChange: { shown in
                                         showingDanmakuSettings = shown
                                         if shown { hideTask?.cancel(); controlsVisible = true }
                                         else { scheduleHide() }
                                     }, onToggle: scheduleHide)
                Menu {
                    Section("播放速度") {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button { player.rate = Float(value) } label: {
                                if Float(value) == player.rate { Label(speedName(value), systemImage: "checkmark") }
                                else { Text(speedName(value)) }
                            }
                        }
                    }
                    Section("清晰度") {
                        ForEach(Array(session.qualities.enumerated()), id: \.element.id) { index, quality in
                            Button { session.chooseQuality(index) } label: {
                                if index == session.selectedQualityIndex { Label(quality.name, systemImage: "checkmark") }
                                else { Text(quality.name) }
                            }
                        }
                    }
                } label: {
                    Text(player.rate == 1 ? (session.currentQuality?.name ?? "设置") : speedName(Double(player.rate)))
                        .font(.subheadline.weight(.medium))
                        .playerControlChrome()
                }
                .buttonStyle(.plain)
                if ReplayPlayer.isPiPSupported {
                    Button { player.togglePiP() } label: {
                        Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter")
                    }
                    .accessibilityLabel("画中画")
                }
            }
            .buttonStyle(PlayerControlButtonStyle())
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2.4, height: size * 2.4)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    private func speedName(_ value: Double) -> String {
        value == 1 ? "正常" : String(format: "%g×", value)
    }

    // MARK: 信息与侧栏

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail?.title ?? (session.phase == .loading ? "正在打开录像…" : "录像"))
                .font(.headline).lineLimit(2)
            if let detail {
                HStack(spacing: 12) {
                    if let date = detail.recordedAt {
                        Label { Text(date, format: .dateTime.month().day().hour().minute()) } icon: { Image(systemName: "calendar") }
                    }
                    if detail.viewCount > 0 { Label(Theme.formatHot(detail.viewCount), systemImage: "play") }
                    if detail.danmakuCount > 0 { Label(Theme.formatHot(detail.danmakuCount), systemImage: "text.bubble") }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(CompactLabelStyle())
            }
            if let chapter = session.currentChapter {
                Label(chapter.title, systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: chapter.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private var panelPicker: some View {
        Picker("内容", selection: $panel) {
            ForEach(ReplayPanel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ViewBuilder private var panelContent: some View {
        switch panel {
        case .danmaku: danmakuList
        case .chapters: chapterList
        case .episodes: episodeList
        }
    }

    private var danmakuList: some View {
        let recent = session.feed?.recent ?? []
        return ScrollViewReader { proxy in
            List {
                if let notice = session.feed?.notice {
                    Text(notice).font(.caption2).foregroundStyle(.orange)
                }
                ForEach(recent) { item in
                    Button { session.seek(to: item.offset) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ReplayPlayer.format(item.offset))
                                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .leading)
                            Text(item.userName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: 80, alignment: .leading)
                            Text(item.text).font(.callout).foregroundStyle(item.color.listForeground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(item.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.plain)
            .overlay {
                if recent.isEmpty {
                    ContentUnavailableView {
                        Label(session.feed?.isLoading == true ? "正在加载弹幕" : "弹幕会随进度出现", systemImage: "text.bubble")
                    } description: {
                        Text("点一条弹幕可以跳到它出现的时刻")
                    }
                }
            }
            .onChange(of: recent.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var chapterList: some View {
        let current = session.currentChapter?.id
        return List(session.chapters) { chapter in
            Button { session.seek(to: chapter.start); player.play() } label: {
                HStack(alignment: .top, spacing: 12) {
                    // 只有当前章节用品牌色胶囊，其余时间戳安静地对齐成一列
                    Text(ReplayPlayer.format(chapter.start))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(chapter.id == current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(chapter.id == current ? Theme.accent : Theme.softFill, in: .capsule)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chapter.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                        if !chapter.summary.isEmpty {
                            Text(chapter.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        HStack(spacing: 6) {
                            if !chapter.tag.isEmpty { Text(chapter.tag) }
                            if chapter.isContinued { Text("接上段") }
                        }.font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(chapter.id == current ? Theme.accentSoft.opacity(0.6) : nil)
        }
        .listStyle(.plain)
        .overlay {
            if session.chapters.isEmpty {
                ContentUnavailableView("暂无章节", systemImage: "sparkles", description: Text("这段录像还没有斗鱼 AI 章节"))
            }
        }
    }

    private var episodeList: some View {
        List {
            if session.segments.count > 1 {
                Section("本场分段") {
                    ForEach(Array(session.segments.enumerated()), id: \.element.id) { index, video in
                        Button {
                            if video.hashID != session.hashID { session.open(hashID: video.hashID) }
                        } label: {
                            episodeRow(cover: video.cover, title: video.title,
                                       subtitle: "第 \(index + 1) 段 · \(ReplayPlayer.format(video.duration))",
                                       fraction: progress.fraction(for: video.hashID),
                                       playing: video.hashID == session.hashID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("全部录像") {
                if let list {
                    ForEach(list.shows) { show in
                        Button {
                            if let first = show.videos.first, show.showID != detail?.showID { session.open(hashID: first.hashID) }
                        } label: {
                            episodeRow(cover: show.videos.first?.cover ?? "",
                                       title: show.sessionLabel.isEmpty ? show.title : show.sessionLabel,
                                       subtitle: [show.relativeDate, show.totalDuration, show.partCount > 1 ? "\(show.partCount) 段" : ""]
                                           .filter { !$0.isEmpty }.joined(separator: " · "),
                                       fraction: show.videos.first.flatMap { progress.fraction(for: $0.hashID) },
                                       playing: show.showID == detail?.showID)
                        }
                        .buttonStyle(.plain)
                        .task { await list.loadMoreIfNeeded(current: show) }
                    }
                    if list.phase == .loading { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.plain)
    }

    private func episodeRow(cover: String, title: String, subtitle: String, fraction: Double?, playing: Bool) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: cover, cornerRadius: 8)
                .frame(width: 104)
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        GeometryReader { geometry in
                            Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction, height: 3)
                        }.frame(height: 3).padding(.horizontal, 5).padding(.bottom, 4)
                    }
                }
                .overlay { if playing { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1.5) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if playing {
                    Label("正在播放", systemImage: "waveform").font(.caption2.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    // MARK: 动作

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    /// 播放中 3 秒无操作隐藏控件
    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        guard !showingDanmakuSettings else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "keepControls") { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private func enterFullscreen() {
        LiveDiagnostics.record("ui.fullscreen", fields: ["page": "replay", "enabled": "true"])
        wantsFullscreen = true
        sceneContext.requestLandscapeFullscreen()
        scheduleHide()
    }

    private func exitFullscreen() {
        LiveDiagnostics.record("ui.fullscreen", fields: ["page": "replay", "enabled": "false"])
        wantsFullscreen = false
        sceneContext.restoreOrientationBeforeFullscreen()
        hud = nil
        controlsVisible = true
    }
}
