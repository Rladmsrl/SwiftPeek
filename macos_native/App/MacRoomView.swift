import AppKit
import SimpleLiveKit
import SwiftUI

/// A window owns its playback session. Reconnection never depends on view onChange order.
@MainActor
@Observable
final class MacRoomSession {
    let roomID: String
    private(set) var store: RoomStore
    let player = FLVLivePlayer()
    let pip = PiPController()
    var pipActive = false
    var isWorking = false
    private var opened = false
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var telemetry: Task<Void, Never>?
    private var settings: AppSettings?
    private var library: LibraryStore?

    init(roomID: String) {
        self.roomID = roomID
        store = RoomStore(roomID: roomID)
    }

    func open(settings: AppSettings, library: LibraryStore) {
        guard !opened else { return }
        opened = true
        self.settings = settings
        self.library = library
        player.volume = settings.data.playerVolume
        pip.attach(player: player, automatic: false)
        pip.onRequestPlay = { [weak self] in self?.play() }
        pip.onRequestPause = { [weak self] in self?.togglePlayback() }
        pip.onStateChange = { [weak self] in self?.pipActive = $0 }
        player.onNeedsFreshStream = { [weak self] in self?.reconnect() }
        player.onPrepareStream = { [weak self] rotate in
            guard let self, self.opened else { throw CancellationError() }
            return try await self.store.prepareReplacementStream(rotateLine: rotate)
        }
        player.onCommitStream = { [weak self] selection in
            guard let self, self.opened else { return }
            self.store.commitReplacementStream(selection)
        }
        LiveDiagnostics.record("room.open", roomID: roomID, fields: ["player": player.diagnosticID])
        loadRoom(autoplay: settings.data.autoPlay)
        telemetry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.opened else { return }
                self.snapshot(event: "player.heartbeat")
            }
        }
    }

    private func loadRoom(autoplay: Bool, selection: RoomStore.Selection? = nil) {
        guard let settings, let library else { return }
        let token = beginOperation()
        let store = self.store
        store.configure(settings: settings, library: library)
        operation = Task { [weak self] in
            await store.load(selection: selection)
            guard let self, self.isCurrent(token) else { return }
            self.isWorking = false
            self.snapshot(event: "room.loaded")
            if autoplay, let url = store.currentStreamURL {
                self.player.start(url: url, headers: store.playURL?.headers)
            }
        }
    }

    /// Manual retry rechecks room info and obtains fresh URLs, including a room that went live later.
    func retry() {
        guard opened, !isWorking else { return }
        player.stop()
        let oldStore = store
        let selection = oldStore.playbackSelection
        Task { await oldStore.stop() }
        store = RoomStore(roomID: roomID)
        loadRoom(autoplay: true, selection: selection)
    }

    /// Resume using a fresh signed URL without discarding the user's choices.
    func play() {
        guard opened, !isWorking else { return }
        guard store.detail?.isLiving == true, !store.qualities.isEmpty else { retry(); return }
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let fresh = await store.refreshStreamURL(rotateLine: false)
            guard let self, self.isCurrent(token) else { return }
            self.isWorking = false
            if let fresh { self.player.start(url: fresh, headers: store.playURL?.headers) }
            else { self.player.abortReconnect(reason: store.offlineNotice ?? store.danmakuNotice ?? "取流失败") }
        }
    }

    func togglePlayback() {
        if player.isActive || isWorking {
            generation += 1
            operation?.cancel()
            operation = nil
            store.cancelPendingStreamRequest()
            isWorking = false
            player.stop()
        } else { play() }
    }

    func chooseQuality(_ index: Int) {
        guard opened, !isWorking, index != store.selectedQualityIndex else { return }
        let wasActive = player.isActive
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let changed = await store.selectQuality(index)
            guard let self, self.isCurrent(token) else { return }
            self.isWorking = false
            if changed, wasActive, let url = store.currentStreamURL {
                self.player.start(url: url, headers: store.playURL?.headers)
            }
        }
    }

    func switchLine() {
        guard !isWorking else { return }
        let wasActive = player.isActive
        store.switchToNextLine()
        if wasActive, let url = store.currentStreamURL {
            player.start(url: url, headers: store.playURL?.headers)
        }
    }

    private func reconnect() {
        guard opened else { return }
        let token = beginOperation()
        let store = self.store
        operation = Task { [weak self] in
            let fresh = await store.refreshStreamURL()
            guard let self, self.isCurrent(token) else { return }
            self.isWorking = false
            if let fresh {
                self.player.resume(url: fresh, headers: store.playURL?.headers)
            } else {
                self.player.abortReconnect(reason: store.offlineNotice ?? store.danmakuNotice ?? "重连失败")
            }
            self.snapshot(event: "room.reconnectComplete")
        }
    }

    private func beginOperation() -> Int {
        generation += 1
        operation?.cancel()
        isWorking = true
        return generation
    }
    private func isCurrent(_ token: Int) -> Bool { opened && generation == token && !Task.isCancelled }

    func close() {
        guard opened else { return }
        opened = false
        generation += 1
        operation?.cancel()
        operation = nil
        telemetry?.cancel()
        telemetry = nil
        isWorking = false
        settings?.data.playerVolume = player.volume
        pip.detach()
        player.onNeedsFreshStream = nil
        player.onPrepareStream = nil
        player.onCommitStream = nil
        player.stop()
        let store = self.store
        Task { await store.stop() }
        snapshot(event: "room.close")
    }

    func snapshot(event: String) {
        LiveDiagnostics.record(event, roomID: roomID, fields: [
            "player": player.diagnosticID,
            "state": String(describing: player.state),
            "bytes": String(player.receivedBytes),
            "line": String(store.currentLineIndex),
            "lines": String(store.lineCount),
            "pipeline": player.pipelineDiagnostics,
            "bufferSeconds": String(player.bufferedSeconds), "bufferBytes": String(player.bufferedBytes),
            "renewing": String(player.isRenewingStream),
            "offline": store.offlineNotice ?? "none",
        ])
    }
}

struct MacRoomView: View {
    let roomID: String
    @State private var session: MacRoomSession
    @State private var showChat = true
    @State private var controlsVisible = true
    @State private var followChat = true
    @State private var window: NSWindow?
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(roomID: String) {
        self.roomID = roomID
        _session = State(initialValue: MacRoomSession(roomID: roomID))
    }

    var body: some View {
        VStack(spacing: 18) {
            roomHeader
            GeometryReader { geometry in
                HStack(spacing: 16) {
                    video.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showChat {
                        chat.frame(width: geometry.size.width < 1000 ? 230 : 280)
                    }
                }
            }
            bottomBar
        }.padding(20)
        .background(MacBackdrop())
        .navigationTitle(session.store.detail?.userName ?? "斗鱼 · \(roomID)")
        .background(WindowReader { resolved in
            window = resolved
            resolved?.isReleasedWhenClosed = false
            session.pip.onRequestRestore = { [weak resolved] in
                resolved?.deminiaturize(nil)
                resolved?.makeKeyAndOrderFront(nil)
            }
        })
        .task { session.open(settings: settings, library: library) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let closing = notification.object as? NSWindow, closing === window { session.close() }
        }
        .onDisappear { session.close() }
        .onChange(of: settings.data.danmakuVisibleByDefault) { _, value in session.store.isDanmakuVisible = value }
    }

    private var followed: Bool { library.isFollowed(session.store.detail?.roomID ?? roomID) }

    private var roomHeader: some View {
        HStack(spacing: 13) {
            MacAvatar(url: session.store.detail?.userAvatar ?? "", name: session.store.detail?.userName ?? "斗鱼", size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.store.detail?.title ?? "直播间 \(roomID)")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(session.store.detail?.userName ?? "斗鱼直播").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(roomID)").foregroundStyle(.tertiary)
                }.font(.system(size: 11))
            }
            Spacer(minLength: 12)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        if let detail = session.store.detail { library.toggleFollow(detail: detail) }
                    } label: {
                        Label(followed ? "已关注" : "关注", systemImage: followed ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(.glass).tint(followed ? MacDesign.accent : nil)
                        .disabled(session.store.detail == nil)
                    MacIconButton(symbol: "sidebar.right", help: "显示 / 隐藏弹幕列表", active: showChat) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showChat.toggle() }
                    }
                    MacIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "全屏") { window?.toggleFullScreen(nil) }
                        .keyboardShortcut("f", modifiers: [.command, .control])
                }
            }
        }
    }

    private var video: some View {
        ZStack {
            Color.black
            FLVVideoLayerView(player: session.player)
            DanmakuOverlay(messages: session.store.messages, settings: settings.danmakuSettings,
                           isVisible: session.store.isDanmakuVisible && !session.pipActive)
                .allowsHitTesting(false)
            if session.pipActive {
                VStack(spacing: 14) {
                    Image(systemName: "pip").font(.system(size: 32, weight: .light))
                    Text("正在画中画中播放").font(.system(size: 13))
                    Button("返回此窗口") { session.pip.stop() }.buttonStyle(.glass)
                }.foregroundStyle(.white.opacity(0.8)).environment(\.colorScheme, .dark)
            } else {
                statusOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if controlsVisible || session.player.state != .playing {
                VStack(spacing: 10) {
                    HStack {
                        Spacer()
                        if settings.data.showResolutionBadge, let size = session.player.videoSize {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }.padding(.horizontal, 8)
                    controls
                }.padding(16)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -36).allowsHitTesting(false)
                    }
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = hovering }
        }
        .onTapGesture(count: 2) { window?.toggleFullScreen(nil) }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch session.player.state {
        case .playing: EmptyView()
        case .connecting, .buffering: statusCard("正在连接直播…", loading: true)
        case .reconnecting(let attempt): statusCard("连接中断，正在重连（\(attempt)）", loading: true)
        case .failed(let reason): statusCard(session.store.offlineNotice ?? reason, loading: false)
        case .idle:
            if session.isWorking { statusCard("正在加载直播间…", loading: true) }
            else if case .failed(let reason) = session.store.phase { statusCard(reason, loading: false) }
            else if session.store.detail?.isLiving == false {
                statusCard(session.store.detail?.isRecord == true ? "当前为轮播内容" : "主播未开播", loading: false)
            } else if let notice = session.store.danmakuNotice, session.store.currentStreamURL == nil {
                statusCard(notice, loading: false)
            } else {
                Button { session.play() } label: {
                    Image(systemName: "play.fill").font(.system(size: 24)).frame(width: 72, height: 72)
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .glassEffect(.regular.interactive(), in: .circle).environment(\.colorScheme, .dark).help("播放")
            }
        }
    }

    private func statusCard(_ text: String, loading: Bool) -> some View {
        VStack(spacing: 18) {
            if loading { ProgressView().controlSize(.large) }
            else { Image(systemName: "play.tv").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary) }
            Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).textSelection(.enabled)
            if !loading {
                Button("重新加载直播间") { session.retry() }.buttonStyle(.glassProminent).tint(MacDesign.accent)
            }
        }.padding(28).frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 20)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(expanded: true)
            controlRow(expanded: false)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    private func controlRow(expanded: Bool) -> some View {
        HStack(spacing: expanded ? 16 : 12) {
            Button { session.togglePlayback() } label: {
                Image(systemName: session.player.isActive || session.isWorking ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }.help("播放 / 停止（空格）").keyboardShortcut(.space, modifiers: [])
            Button { session.player.isMuted.toggle() } label: {
                Image(systemName: session.player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }.help("静音（M）").keyboardShortcut("m", modifiers: [])
            if expanded {
                Slider(value: Binding(get: { session.player.volume }, set: { session.player.volume = $0 }), in: 0...1)
                    .frame(width: 66).tint(.white).accessibilityLabel("播放器音量")
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(Array(session.store.qualities.enumerated()), id: \.offset) { index, quality in
                    Button(quality.quality) { session.chooseQuality(index) }
                }
            } label: {
                Text(session.store.qualities.indices.contains(session.store.selectedQualityIndex)
                     ? session.store.qualities[session.store.selectedQualityIndex].quality : "清晰度")
                    .font(.system(size: 11, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize()
                .disabled(session.isWorking || session.store.qualities.isEmpty)
            if expanded {
                Button("线路 \(session.store.lineCount == 0 ? 0 : session.store.currentLineIndex + 1)") { session.switchLine() }
                    .font(.system(size: 11, weight: .medium)).disabled(session.store.lineCount < 2 || session.isWorking)
            }
            Button { session.store.isDanmakuVisible.toggle() } label: {
                Image(systemName: "text.bubble").foregroundStyle(session.store.isDanmakuVisible ? .white : .white.opacity(0.4))
            }.help("显示 / 隐藏弹幕")
            if PiPController.isSupported {
                Button { session.pip.toggle() } label: { Image(systemName: session.pipActive ? "pip.exit" : "pip.enter") }
                    .help("画中画").disabled(!session.pipActive && !session.player.isActive)
            }
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Circle().fill(session.player.state == .playing ? MacDesign.green : .secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(playbackLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("双击画面全屏  ·  空格播放 / 停止").font(.system(size: 10)).foregroundStyle(.tertiary)
            Menu {
                Button("重新加载直播间") { session.retry() }
                Button("切换播放线路") { session.switchLine() }.disabled(session.store.lineCount < 2 || session.isWorking)
                Divider()
                Button("记录当前播放状态") { session.snapshot(event: "user.mark") }
                Button("打开播放日志", action: MacDiagnostics.reveal)
            } label: { Image(systemName: "ellipsis").font(.system(size: 14)) }
                .menuStyle(.borderlessButton).frame(width: 28)
        }.padding(.horizontal, 3)
    }

    private var playbackLabel: String {
        switch session.player.state {
        case .playing: "正在直播"
        case .connecting, .buffering: "连接中"
        case .reconnecting: "正在重新连接"
        case .failed: "播放已中断"
        case .idle: "等待播放"
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("实时弹幕").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("LIVE").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(MacDesign.accent)
            }.padding(18)
            Rectangle().fill(.primary.opacity(0.05)).frame(height: 1)
            if let notice = session.store.danmakuNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if session.store.messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 25, weight: .light))
                                Text("一起等下一条弹幕").font(.system(size: 11))
                            }.foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 50)
                        }
                        ForEach(session.store.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.userName).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                Text(message.message).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                                    .lineSpacing(3).textSelection(.enabled)
                            }.id(message.id).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16)
                }.scrollIndicators(.hidden)
                    .onChange(of: session.store.messages.last?.id) { _, id in
                        if followChat, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
            HStack {
                Image(systemName: "bubble.right").font(.system(size: 11))
                Text("与此刻同频").font(.system(size: 10))
                Spacer()
                Toggle("跟随", isOn: $followChat).toggleStyle(.checkbox).font(.system(size: 10))
            }.foregroundStyle(.tertiary).padding(14)
        }.macSurface(radius: 18)
    }
}

private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onResolve = onResolve
        return view
    }
    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.onResolve = onResolve }
    final class ReaderView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let current = window
            DispatchQueue.main.async { [weak self] in self?.onResolve?(current) }
        }
    }
}
