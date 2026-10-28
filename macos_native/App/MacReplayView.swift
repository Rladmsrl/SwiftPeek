import AppKit
import SimpleLiveKit
import SwiftUI

private enum ReplayPanel: String, CaseIterable, Identifiable {
    case danmaku = "弹幕", chapters = "章节", episodes = "选集"
    var id: Self { self }
}

/// 录像窗口：左侧播放器（弹幕飞屏 + 热度进度条），右侧弹幕回放 / AI 章节 / 选集。
struct MacReplayView: View {
    let route: ReplayRoute
    @State private var session = ReplaySession()
    @State private var list: ReplayListStore?
    @State private var progress = ReplayProgressStore.shared
    @State private var panel: ReplayPanel
    @State private var showPanel = true
    @State private var pointerActive = true
    @State private var showingDanmakuSettings = false
    @State private var hideTask: Task<Void, Never>?
    @State private var followDanmaku = true
    @State private var window: NSWindow?
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(route: ReplayRoute) {
        self.route = route
        _panel = State(initialValue: route.hashID == nil ? .episodes : .danmaku)
        _list = State(initialValue: route.roomID.map { ReplayListStore(roomID: $0) })
    }

    private var player: ReplayPlayer { session.player }
    private var detail: DouyuReplayDetail? { session.detail }
    private var roomID: String? {
        if let id = detail?.roomID, !id.isEmpty { return id }
        return list?.author?.roomID ?? route.roomID
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                video.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPanel {
                    sidePanel.frame(width: geometry.size.width < 1000 ? 280 : 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(12)
        .navigationTitle(detail?.authorName ?? list?.author?.name ?? "录像")
        .navigationSubtitle(detail?.authorName ?? list?.author?.name == nil ? "" : "直播录像")
        .toolbar {
            if let roomID {
                ToolbarItem(placement: .primaryAction) {
                    Button { openWindow(id: "room", value: roomID) } label: {
                        Label("进入直播间", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .help("进入直播间")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : Theme.glide) { showPanel.toggle() }
                } label: { Label("侧栏", systemImage: "sidebar.right") }
                    .help("显示 / 隐藏侧栏")
            }
        }
        .background(WindowReader { resolved in
            window = resolved
            resolved?.isReleasedWhenClosed = false
            player.onPiPRestore = { [weak resolved] in
                resolved?.deminiaturize(nil)
                resolved?.makeKeyAndOrderFront(nil)
            }
        })
        .task { start() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let closing = notification.object as? NSWindow, closing === window { session.close() }
        }
        .onDisappear {
            hideTask?.cancel()
            session.close()
        }
        .onChange(of: detail?.roomID) { _, id in
            guard list == nil, let id, !id.isEmpty else { return }
            let store = ReplayListStore(roomID: id)
            list = store
            Task { await store.refresh() }
        }
        .onChange(of: settings.data.danmakuVisibleByDefault) { _, value in session.isDanmakuVisible = value }
        .background { shortcuts }
    }

    private func start() {
        session.configure(settings: settings)
        if let hashID = route.hashID { session.open(hashID: hashID, start: route.start) }
        guard let list else { return }
        Task {
            await list.refresh()
            // 从直播间进来：默认选中最新一场，等用户点播放
            if route.hashID == nil, session.hashID == nil, let first = list.shows.first?.videos.first {
                session.open(hashID: first.hashID, autoplay: false)
            }
        }
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    // MARK: 播放区

    private var controlsShown: Bool { pointerActive || showingDanmakuSettings || !player.isPlaying }

    private var video: some View {
        ZStack {
            Color.black
            ReplayVideoView(player: player) { player.preparePiP(automatic: false) }
            if let feed = session.feed {
                ObservationScope {
                    DanmakuOverlay(messages: feed.messages, settings: settings.danmakuSettings,
                                   isVisible: session.isDanmakuVisible && !player.isPiPActive,
                                   clearToken: feed.clearToken, isPaused: !player.isPlaying)
                }
                .id(session.hashID)
                    .allowsHitTesting(false)
            }
            statusOverlay
        }
        .overlay(alignment: .bottom) {
            if controlsShown {
                controls
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -50).allowsHitTesting(false)
                    }
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            case .ended:
                hideTask?.cancel()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { pointerActive = false }
            }
        }
        .onTapGesture(count: 2) { window?.toggleFullScreen(nil) }
        .onTapGesture { player.togglePlay(); revealControls() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controlsShown)
    }

    /// 鼠标一动就显示控件，静止 2.5 秒后隐藏；全屏时顺便藏起光标
    private func revealControls() {
        if !pointerActive { pointerActive = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { pointerActive = false }
            if window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if player.isPiPActive {
            VStack(spacing: 14) {
                Image(systemName: "pip").font(.system(size: 32, weight: .light))
                Text("正在画中画中播放").font(.system(size: 13))
                Button("返回此窗口") { player.togglePiP() }.buttonStyle(.glass)
            }.foregroundStyle(.white.opacity(0.8)).environment(\.colorScheme, .dark)
        } else if case .failed(let message) = session.phase {
            statusCard(symbol: "exclamationmark.triangle", text: message, action: "重新加载") { session.retry() }
        } else if session.phase == .loading || player.state == .loading {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text("正在打开录像…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
        } else {
            switch player.state {
            case .failed(let message):
                statusCard(symbol: "wifi.exclamationmark", text: "播放中断：\(message)", action: "重新连接") { session.retry() }
            case .buffering:
                ProgressView().controlSize(.regular).tint(.white)
                    .padding(16).glassEffect(.regular, in: .circle).environment(\.colorScheme, .dark)
            case .ended:
                endCard
            case .paused:
                Button { player.play() } label: {
                    Image(systemName: "play.fill").font(.system(size: 26)).frame(width: 76, height: 76)
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .glassEffect(.regular.interactive(), in: .circle).environment(\.colorScheme, .dark)
                    .help("播放（空格）")
            case .idle where session.hashID == nil:
                if list?.phase == .loading || list?.phase == .idle {
                    ProgressView().controlSize(.large).tint(.white)
                } else if case .failed(let message)? = list?.phase {
                    statusCard(symbol: "film.stack", text: message, action: "重试") { Task { await list?.refresh() } }
                } else {
                    statusCard(symbol: "film.stack", text: "这位主播还没有公开录像", action: nil) {}
                }
            default:
                EmptyView()
            }
        }
    }

    private var endCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.8))
            Text("这段录像已播完").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 10) {
                Button { session.seek(to: 0); player.play() } label: { Label("重新播放", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.glass)
                if let next = session.nextSegment {
                    Button { session.open(hashID: next.hashID, start: 0) } label: { Label("下一段 · \(next.title)", systemImage: "forward.end.fill") }
                        .buttonStyle(.glassProminent).tint(Theme.accent)
                }
            }
        }.padding(28).foregroundStyle(.white)
            .glassEffect(.regular, in: .rect(cornerRadius: 24)).environment(\.colorScheme, .dark)
    }

    private func statusCard(symbol: String, text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).textSelection(.enabled)
            if let action {
                Button(action, action: perform).buttonStyle(.glassProminent).tint(Theme.accent)
            }
        }.padding(28).frame(maxWidth: 360)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 20)
    }

    // MARK: 控制条

    private var controls: some View {
        VStack(spacing: 4) {
            ObservationScope {
                ReplayScrubber(time: player.displayTime, duration: session.duration, buffered: player.bufferedTime,
                               heat: session.heat.bins, chapters: session.chapters) { session.seek(to: $0) }
            }
            .padding(.horizontal, 4)
            ViewThatFits(in: .horizontal) {
                controlRow(expanded: true)
                controlRow(expanded: false)
            }
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture(count: 2) {}  // 点到控制条空白处既不暂停也不切换全屏
        .onTapGesture {}
        .padding(14)
        .disabled(session.phase != .loaded)
    }

    private func controlRow(expanded: Bool) -> some View {
        HStack(spacing: expanded ? 8 : 4) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 20)
            }.help("播放 / 暂停（空格）")
            Button { session.skip(by: -10) } label: { Image(systemName: "gobackward.10") }.help("后退 10 秒（←）")
            Button { session.skip(by: 10) } label: { Image(systemName: "goforward.10") }.help("前进 10 秒（→）")
            if let next = session.nextSegment {
                Button { session.open(hashID: next.hashID, start: 0) } label: { Image(systemName: "forward.end.fill") }
                    .help("下一段：\(next.title)")
            }
            ObservationScope {
                Text("\(ReplayPlayer.format(player.displayTime)) / \(ReplayPlayer.format(session.duration))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
                if expanded, let chapter = session.currentChapter {
                    Text(chapter.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
            Spacer(minLength: 10)
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button { player.rate = Float(value) } label: {
                        if Float(value) == player.rate { Label(speedName(Float(value)), systemImage: "checkmark") }
                        else { Text(speedName(Float(value))) }
                    }
                }
            } label: { Text(player.rate == 1 ? "倍速" : speedName(player.rate)).font(.system(size: 11, weight: .medium)).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize().help("播放速度")
                .padding(.horizontal, 6)
            Menu {
                ForEach(Array(session.qualities.enumerated()), id: \.element.id) { index, quality in
                    Button { session.chooseQuality(index) } label: {
                        if index == session.selectedQualityIndex { Label(quality.name, systemImage: "checkmark") }
                        else { Text(quality.name) }
                    }
                }
            } label: { Text(session.currentQuality?.name ?? "清晰度").font(.system(size: 11, weight: .medium)) }
                .menuStyle(.borderlessButton).fixedSize().disabled(session.qualities.isEmpty)
                .padding(.horizontal, 6)
            PlayerDanmakuControl(isVisible: Binding(get: { session.isDanmakuVisible },
                                                    set: { session.isDanmakuVisible = $0 }),
                                 onPresentationChange: { showingDanmakuSettings = $0 })
            Button { player.isMuted.toggle() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
            }.help("静音（M）")
            if expanded {
                Slider(value: Binding(get: { player.volume }, set: { player.volume = $0; player.isMuted = false }), in: 0...1)
                    .frame(width: 70).tint(.white).accessibilityLabel("音量")
                    .padding(.trailing, 4)
            }
            if ReplayPlayer.isPiPSupported {
                Button { player.togglePiP() } label: { Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter") }
                    .help("画中画")
            }
        }.buttonStyle(MacPlayerButtonStyle()).font(.system(size: 13)).foregroundStyle(.white).tint(.white)
    }

    private func speedName(_ rate: Float) -> String {
        rate == 1 ? "正常" : String(format: "%g×", rate)
    }

    /// 键盘操作挂在隐藏按钮上，焦点在窗口任意位置都生效
    private var shortcuts: some View {
        Group {
            Button("") { player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { session.skip(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { session.skip(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { session.skip(by: -60) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { session.skip(by: 60) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { player.isMuted.toggle() }.keyboardShortcut("m", modifiers: [])
            Button("") { session.isDanmakuVisible.toggle() }.keyboardShortcut("d", modifiers: [])
            Button("") { window?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: 侧栏

    /// 与 iOS 录像页同一结构：标题与元信息 → 分段选择 → 当前内容
    private var sidePanel: some View {
        VStack(spacing: 0) {
            replayInfo.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Picker("侧栏内容", selection: $panel) {
                ForEach(ReplayPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // 弹幕随进度追加、当前章节随进度变化，各自包成观察边界
            switch panel {
            case .danmaku: ObservationScope { danmakuPanel }
            case .chapters: ObservationScope { chapterPanel }
            case .episodes: episodePanel
            }
        }.macPanel()
    }

    private var replayInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail?.title ?? (session.phase == .loading ? "正在打开录像…" : "选择一段录像"))
                .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                HStack(spacing: 5) {
                    if let date = detail.recordedAt { Text(date, format: .dateTime.month().day().hour().minute()); dot }
                    Text(ReplayPlayer.format(detail.duration))
                    if detail.danmakuCount > 0 { dot; Text("\(Theme.formatHot(detail.danmakuCount)) 条弹幕") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
    }

    private var danmakuPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = session.feed?.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.top, 10)
            }
            let recent = session.feed?.recent ?? []
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if recent.isEmpty {
                            Text(session.feed?.isLoading == true ? "正在加载弹幕…" : "播放后，弹幕会随进度出现在这里")
                                .font(.system(size: 12)).multilineTextAlignment(.center)
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 48)
                        }
                        ForEach(recent) { item in
                            Button { session.seek(to: item.offset) } label: { danmakuRow(item) }
                                .buttonStyle(.plain).id(item.id)
                                .help("跳到 \(ReplayPlayer.format(item.offset))")
                        }
                    }.padding(14)
                }.scrollIndicators(.hidden)
                    .onChange(of: recent.last?.id) { _, id in
                        if followDanmaku, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
            Toggle("跟随播放进度", isOn: $followDanmaku).toggleStyle(.checkbox)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func danmakuRow(_ item: DouyuReplayDanmaku) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(ReplayPlayer.format(item.offset))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.userName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(item.text).font(.system(size: 13)).foregroundStyle(item.color.macListForeground)
                    .lineSpacing(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }.contentShape(.rect)
    }

    private var chapterPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("斗鱼 AI 生成的章节").foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 4).padding(.bottom, 2)
                if session.chapters.isEmpty {
                    MacEmptyState(symbol: "list.bullet.rectangle", title: "暂无章节", detail: "这段录像还没有 AI 章节。")
                }
                let current = session.currentChapter?.id
                ForEach(session.chapters) { chapter in
                    Button { session.seek(to: chapter.start); player.play() } label: {
                        chapterRow(chapter, current: chapter.id == current)
                    }.buttonStyle(.plain)
                }
            }.padding(14)
        }.scrollIndicators(.hidden)
    }

    private func chapterRow(_ chapter: DouyuReplayChapter, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                // 只有当前章节用品牌色胶囊，其余时间戳安静地排成一列
                Text(ReplayPlayer.format(chapter.start))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(current ? Theme.accent : Theme.softFill, in: .capsule)
                if !chapter.tag.isEmpty {
                    Text(chapter.tag).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if chapter.isContinued {
                    Text("接上段").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying && !reduceMotion)
                }
            }
            Text(chapter.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
            if !chapter.summary.isEmpty {
                Text(chapter.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    .lineSpacing(2).multilineTextAlignment(.leading)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 10))
        .macHoverFill(radius: 10)
        .contentShape(.rect)
    }

    private var episodePanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if session.segments.count > 1 {
                    sectionTitle("本场分段", trailing: "\(session.segments.count) 段")
                    ForEach(Array(session.segments.enumerated()), id: \.element.id) { index, video in
                        Button { if video.hashID != session.hashID { session.open(hashID: video.hashID) } } label: {
                            segmentRow(video, index: index)
                        }.buttonStyle(.plain)
                    }
                    Spacer().frame(height: 8)
                }
                sectionTitle("全部录像", trailing: list?.author.map { $0.name } ?? "")
                if let list {
                    if list.shows.isEmpty {
                        PhaseStateView(phase: list.phase, isEmpty: true, emptyText: "暂无录像") { Task { await list.refresh() } }
                            .controlSize(.small)
                    }
                    ForEach(list.shows) { show in
                        Button {
                            if let first = show.videos.first, show.showID != detail?.showID { session.open(hashID: first.hashID) }
                        } label: { showRow(show) }
                            .buttonStyle(.plain)
                            .task { await list.loadMoreIfNeeded(current: show) }
                    }
                    if list.isLoadingMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }.padding(14)
        }.scrollIndicators(.hidden)
    }

    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func segmentRow(_ video: DouyuReplayVideo, index: Int) -> some View {
        let playing = video.hashID == session.hashID
        return HStack(spacing: 11) {
            thumbnail(video.cover, fraction: progress.fraction(for: video.hashID), playing: playing)
            VStack(alignment: .leading, spacing: 5) {
                Text(video.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("第 \(index + 1) 段 · \(ReplayPlayer.format(video.duration))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if playing {
                    Label("正在播放", systemImage: "waveform").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(playing ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 10))
        .macHoverFill(radius: 10)
    }

    private func showRow(_ show: DouyuReplayShow) -> some View {
        let current = show.showID == detail?.showID
        let first = show.videos.first
        return HStack(spacing: 11) {
            thumbnail(first?.cover ?? "", fraction: first.flatMap { progress.fraction(for: $0.hashID) }, playing: current)
            VStack(alignment: .leading, spacing: 5) {
                Text(show.sessionLabel.isEmpty ? show.title : show.sessionLabel)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(show.relativeDate)
                    if !show.startClock.isEmpty { Text(show.startClock) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if !show.totalDuration.isEmpty { Text(show.totalDuration) }
                    if show.partCount > 1 { Text("· \(show.partCount) 段") }
                }.font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(current ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 10))
        .macHoverFill(radius: 10)
    }

    private func thumbnail(_ url: String, fraction: Double?, playing: Bool) -> some View {
        CoverImage(url: url, cornerRadius: 8)
            .frame(width: 96)
            .overlay(alignment: .bottom) {
                if let fraction, fraction > 0 {
                    GeometryReader { geometry in
                        Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction, height: 3)
                    }.frame(height: 3).padding(.horizontal, 5).padding(.bottom, 4)
                }
            }
            .overlay {
                if playing {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
    }
}

extension LiveMessageColor {
    /// 斗鱼弹幕大多是纯白，在浅色侧栏里不可读，近白色回退为主文本色
    var macListForeground: Color {
        if r > 225, g > 225, b > 225 { return .primary.opacity(0.85) }
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
