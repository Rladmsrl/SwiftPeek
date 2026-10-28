import SimpleLiveKit
import SwiftUI

struct RoomView: View {
    let roomID: String
    let fallbackTitle: String

    @State private var playback: MobileRoomPlaybackSession<FLVLivePlayer>
    private var store: RoomStore { playback.store }
    private var player: FLVLivePlayer { playback.player }
    @State private var pip = PiPController()
    @State private var isPiPActive = false
    /// 进入房间时所在的 Tab。用于区分「切 Tab（界面被盖住）」与
    /// 「真正离开房间（返回上一页）」——两者都会触发 onDisappear。
    @State private var homeTab: AppTab?
    // 全屏相关
    @State private var wantsFullscreen = false
    @State private var isLocked = false
    @State private var controlsVisible = true
    @State private var showingDanmakuSettings = false
    @State private var hud: PlayerHUD?
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var choosingAdditionalRooms = false
    @State private var pendingRooms: [MultiWatchSelection] = []

    @State private var sceneContext = PlayerSceneContext()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(PhoneMultiWatch.self) private var multiWatch

    init(roomID: String, fallbackTitle: String) {
        self.roomID = roomID
        self.fallbackTitle = fallbackTitle
        _playback = State(initialValue: MobileRoomPlaybackSession(roomID: roomID, player: FLVLivePlayer()))
    }

    private var isFullscreen: Bool { wantsFullscreen }

    private var isFollowed: Bool { library.isFollowed(roomID) }

    var body: some View {
        AdaptivePlaybackContainer(fullscreen: isFullscreen) {
            playerSurface
        } companion: {
            PlaybackCompanion {
                infoSection
            } content: {
                VStack(spacing: 0) {
                    HStack {
                        Text("实时弹幕")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    RoomDanmakuList(store: store)
                }
            }
        }
        .background(PlayerSceneReader(context: sceneContext))
        .navigationTitle(store.detail?.userName ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar, .tabBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        // 横屏全屏时顶栏贴着屏幕上沿，先让给按钮，系统手势需要再划一次
        .defersSystemGestures(on: isFullscreen ? .vertical : [])
        .toolbar {
            // 标题和符号同时提供，系统可用于横向栏、侧边栏和溢出菜单。
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ReplayRoute(roomID: store.detail?.roomID ?? roomID)) {
                    Label("录像", systemImage: "play.rectangle.on.rectangle")
                }
                .accessibilityLabel("查看主播的直播录像")
            }
        }
        .sheet(isPresented: $choosingAdditionalRooms, onDismiss: addSelectedRooms) {
            MultiWatchPicker(existing: [MultiWatchSelection(id: store.detail?.roomID ?? roomID,
                                                          title: store.detail?.userName ?? fallbackTitle)]) {
                pendingRooms = $0
            }
        }
        .task {
            if homeTab == nil { homeTab = router.selectedTab }
            configurePiP()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "launchRoomLayout") { return }
            #endif
            playback.open(settings: settings, library: library)
            playback.setSceneBackgrounded(scenePhase == .background)
            await playback.waitUntilLoaded()
            #if DEBUG
            // 自动化验证入口：--args -autoFollow 1 走与右上角星标完全相同的关注逻辑
            if UserDefaults.standard.bool(forKey: "autoFollow"),
               let detail = store.detail,
               !library.isFollowed(detail.roomID) {
                library.toggleFollow(detail: detail)
            }
            if UserDefaults.standard.bool(forKey: "launchFullscreen") {
                enterFullscreen()
            }
            // 只旋转：验证横屏仍能访问弹幕面板，不隐式进入全屏。
            if UserDefaults.standard.bool(forKey: "rotateOnly") {
                sceneContext.requestOrientation(.landscapeRight)
            }
            if UserDefaults.standard.bool(forKey: "selfCheck") {
                runSelfCheck()
            }
            // 手势产生的瞬时 UI（HUD、锁屏）无法用 simctl 触发，
            // 这两个开关用于让它们可复现地呈现出来做视觉校验
            if UserDefaults.standard.bool(forKey: "hudDemo") {
                hud = PlayerHUD(kind: .volume, value: 0.62)
            }
            if UserDefaults.standard.bool(forKey: "lockDemo") {
                isLocked = true
            }
            // 切 Tab 不该停播：脚本化地切走再切回，打印三个时点的播放器状态
            if UserDefaults.standard.bool(forKey: "tabSwitchDemo") {
                runTabSwitchDemo()
            }
            // 断流自动重连：伪造网络中断，逐秒打印恢复过程。值即断流次数
            let drops = UserDefaults.standard.integer(forKey: "dropDemo")
            if drops > 0 {
                runDropDemo(drops)
            }
            // 纯观察播放链路，不制造中断
            if UserDefaults.standard.bool(forKey: "stallProbe") {
                runStallProbe()
            }
            #endif
        }
        .onDisappear {
            controlsHideTask?.cancel()
            if multiWatch.isPresented { pip.detach(); return }

            // 切 Tab 只是界面被盖住，人还在 App 里浏览——不该停流，
            // 否则切回来要整套重新拉（详情 + 签名 + 取流 + 弹幕重连）。
            // 只有真正离开房间才收摊。
            let isTabSwitch = homeTab != nil && router.selectedTab != homeTab
            guard !isTabSwitch else { return }

            if isFullscreen { exitFullscreen() }
            playback.close()
            pip.detach()
        }
        .onChange(of: settings.data.autoPictureInPicture) { configurePiP() }
        .onChange(of: multiWatch.isPresented) { _, presented in
            if presented { pip.detach() } else { configurePiP() }
        }
        .onChange(of: store.isDanmakuVisible) { pip.refreshDanmaku() }
        .onChange(of: settings.data.backgroundAudio) { _, enabled in
            if !multiWatch.owns(playback) { playback.setBackgroundAudio(enabled) }
        }
        .onChange(of: player.state) { pip.invalidatePlaybackState() }
        .onChange(of: playback.isWorking) { pip.invalidatePlaybackState() }
        .onChange(of: scenePhase) { _, phase in
            if !multiWatch.owns(playback) { handleScenePhase(phase) }
        }
    }

    // MARK: - 稳定的播放器宿主

    private var playerSurface: some View {
        @Bindable var player = player
        return ZStack {
            Color.black
            FLVVideoLayerView(player: player, enabled: !multiWatch.owns(playback))
                .allowsHitTesting(false)
            if !multiWatch.owns(playback) {
                LiveDanmakuLayer(store: store, settings: store.danmakuRenderSettings,
                                 isVisible: store.isDanmakuVisible)
            }

            if isFullscreen {
                PlayerGestureSurface(
                    volume: $player.volume, hud: $hud, sceneContext: sceneContext,
                    isLocked: isLocked, onSingleTap: toggleControls, onDoubleTap: togglePlayback
                )
            }
            playerStatusOverlay
            if let hud { PlayerHUDView(hud: hud) }
            if isFullscreen {
                if controlsVisible {
                    if isLocked {
                        lockToggle
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    } else {
                        fullscreenChrome
                    }
                }
            } else {
                VStack {
                    Spacer(minLength: 0)
                    controlBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: isLocked)
    }

    // MARK: - 全屏 chrome

    private var fullscreenChrome: some View {
        VStack(spacing: 0) {
            fullscreenTopBar
            Spacer(minLength: 0)
            fullscreenBottomBar
        }
        .overlay(alignment: .leading) {
            lockToggle.padding(.leading, 16)
        }
        .transition(.opacity)
    }

    private var fullscreenTopBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    exitFullscreen()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("退出全屏")

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.detail?.title ?? fallbackTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(store.detail?.userName ?? "")
                        .font(.caption2)
                        .opacity(0.75)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)

                Spacer(minLength: 0)

                Button {
                    toggleVideoGravity()
                    resetControlsTimer()
                } label: {
                    Image(systemName: player.videoGravity == .resizeAspect
                          ? "rectangle.arrowtriangle.2.outward"
                          : "rectangle.arrowtriangle.2.inward")
                }
                .accessibilityLabel(player.videoGravity == .resizeAspect ? "填充画面" : "适应画面")
            }
            .buttonStyle(PlayerControlButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var fullscreenBottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                inlineControlRow(expanded: true, showsFullscreen: false)
                inlineControlRow(expanded: false, showsFullscreen: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var lockToggle: some View {
        Button {
            isLocked.toggle()
            resetControlsTimer()
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
        }
        .buttonStyle(PlayerControlButtonStyle())
        .accessibilityLabel(isLocked ? "解锁屏幕" : "锁定屏幕")
    }

    @ViewBuilder
    private var playerStatusOverlay: some View {
        switch player.state {
        case .idle where playback.isWorking:
            ProgressView("正在准备播放…").tint(.white).foregroundStyle(.white)

        case .idle where store.phase.errorText != nil || (store.currentStreamURL == nil && store.danmakuNotice != nil):
            VStack(spacing: 12) {
                Text(store.phase.errorText ?? store.danmakuNotice ?? "加载失败")
                    .font(.caption).multilineTextAlignment(.center)
                Button("重试") { playback.play() }.buttonStyle(.glass)
            }.padding(20).foregroundStyle(.white)

        case .idle where store.detail?.isLiving == false:
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.largeTitle)
                Text(store.detail?.isRecord == true ? "当前为轮播内容" : "主播未开播")
                    .font(.subheadline)
                // 没开播时最需要录像，在这里给出明显入口
                HStack(spacing: 10) {
                    Button("重新查询") { playback.play() }.buttonStyle(.glass)
                    NavigationLink(value: ReplayRoute(roomID: store.detail?.roomID ?? roomID)) {
                        Label("看录像", systemImage: "play.rectangle.on.rectangle")
                    }
                    .buttonStyle(.glassProminent)
                }
                .font(.subheadline)
            }
            .foregroundStyle(.white.opacity(0.85))

        case .idle where store.currentStreamURL != nil:
            // 关闭了自动播放，或被双击暂停
            Button {
                startPlaybackNow()
            } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)

        case .connecting, .buffering:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text(player.state == .connecting ? "连接中…" : "缓冲中…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }

        case .reconnecting(let attempt):
            // 重连时最后一帧仍留在图层上（resume 不清画面），
            // 这里只叠一个轻量玻璃提示，避免网络抖动时整屏闪黑。
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("连接中断，正在重连…（第 \(attempt.description) 次）")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                // 重连时若查明是主播下播，给出确切原因而不是笼统的连接错误
                Text(store.offlineNotice ?? message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button("重试") { startPlaybackNow() }
                    if store.lineCount > 1 {
                        Button("切换线路") { playback.switchLine() }
                    }
                }
                .buttonStyle(.glass)
                .font(.caption)
            }
            .foregroundStyle(.white)

        default:
            EmptyView()
        }
    }

    /// Liquid Glass 控制条。GlassEffectContainer 让相邻玻璃元素共享折射、
    /// 在滚动和交互时表现为一体而不是各自独立的一块块玻璃。
    private var controlBar: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                inlineControlRow(expanded: true)
                inlineControlRow(expanded: false)
            }
        }
        // 控制条属于前景交互元素，必须留在安全区内（Duo 上安全区是非对称的）
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func inlineControlRow(expanded: Bool, showsFullscreen: Bool = true) -> some View {
        HStack(spacing: 8) {
            danmakuToggleButton
            Button {
                pendingRooms = []
                choosingAdditionalRooms = true
                controlsHideTask?.cancel()
            } label: {
                Label("加看", systemImage: "rectangle.badge.plus").labelStyle(.iconOnly)
            }
            .accessibilityLabel("加看直播间")
            .accessibilityIdentifier("multiwatch.entry")
            if expanded {
                muteButton
                qualityMenu
                lineButton
            } else {
                Menu {
                    Button(player.isMuted ? "取消静音" : "静音", systemImage: player.isMuted ? "speaker.wave.2" : "speaker.slash") {
                        player.isMuted.toggle()
                        resetControlsTimer()
                    }
                    qualityMenu
                    if store.qualities.isEmpty { lineButton }
                    if PiPController.isSupported {
                        Button(isPiPActive ? "退出画中画" : "画中画", systemImage: isPiPActive ? "pip.exit" : "pip.enter") {
                            pip.toggle()
                            resetControlsTimer()
                        }
                        .disabled(!isPiPActive && !player.isActive)
                    }
                } label: {
                    Label("播放选项", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .playerControlChrome()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放选项")
            }
            Spacer(minLength: 0)
            if expanded { resolutionBadge.fixedSize() }
            if expanded { pipButton }
            if showsFullscreen {
                Button { enterFullscreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("全屏")
            }
        }
        .buttonStyle(PlayerControlButtonStyle())
    }

    // MARK: - 控制条零件（全屏与非全屏共用）

    private var danmakuToggleButton: some View {
        PlayerDanmakuControl(isVisible: Binding(get: { store.isDanmakuVisible }, set: { store.isDanmakuVisible = $0 }),
                             onPresentationChange: { shown in
                                 showingDanmakuSettings = shown
                                 if shown { controlsHideTask?.cancel(); controlsVisible = true }
                                 else { resetControlsTimer() }
                             }, onToggle: resetControlsTimer)
    }

    private var muteButton: some View {
        Button {
            player.isMuted.toggle()
            resetControlsTimer()
        } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .accessibilityLabel(player.isMuted ? "取消静音" : "静音")
    }

    @ViewBuilder
    private var qualityMenu: some View {
        if !store.qualities.isEmpty {
            Menu {
                ForEach(Array(store.qualities.enumerated()), id: \.offset) { index, quality in
                    Button {
                        playback.chooseQuality(index)
                        resetControlsTimer()
                    } label: {
                        if index == store.selectedQualityIndex {
                            Label(quality.quality, systemImage: "checkmark")
                        } else {
                            Text(quality.quality)
                        }
                    }
                }
                if store.lineCount > 1 {
                    Divider()
                    Button("切换线路（当前线路 \(store.currentLineIndex + 1)）") {
                        playback.switchLine()
                        resetControlsTimer()
                    }
                }
            } label: {
                Text(store.qualities[safe: store.selectedQualityIndex]?.quality ?? "清晰度")
                    .font(.subheadline.weight(.medium))
                    .playerControlChrome()
            }
            .buttonStyle(.plain)
            .disabled(playback.isWorking)
        }
    }

    @ViewBuilder
    private var lineButton: some View {
        if store.lineCount > 1 {
            Button {
                playback.switchLine()
                resetControlsTimer()
            } label: {
                Text("线路\(store.currentLineIndex + 1)")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(playback.isWorking)
        }
    }

    @ViewBuilder
    private var pipButton: some View {
        if PiPController.isSupported {
            Button {
                pip.toggle()
                resetControlsTimer()
            } label: {
                Image(systemName: isPiPActive
                      ? "pip.exit"
                      : "pip.enter")
            }
            .disabled(!isPiPActive && !player.isActive)
            .accessibilityLabel(isPiPActive ? "退出画中画" : "画中画")
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        if let size = player.videoSize, store.showResolutionBadge {
            // 用 description 拼接，避免 Text 插值对 Int 自动加千位分隔符
            Text("\(Int(size.width).description)×\(Int(size.height).description)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
    }

    // MARK: - 全屏与手势动作

    #if DEBUG
    /// 手势会改写的两个量（音量、亮度）在截图里看不出来，这里直接跑一遍读写回路。
    private func runSelfCheck() {
        var lines: [String] = []
        let savedVolume = player.volume

        player.volume = 1.5
        lines.append("volume(1.5)=\(player.volume)")
        player.volume = -0.3
        lines.append("volume(-0.3)=\(player.volume)")
        player.volume = 0.42
        lines.append("volume(0.42)=\(player.volume)")
        lines.append("renderer=\(player.audioRenderer.volume)")
        player.volume = savedVolume

        let savedBrightness = sceneContext.brightness
        lines.append("scene=\(sceneContext.window?.windowScene != nil)")
        print("[SELFCHECK] " + lines.joined(separator: " | "))

        // 亮度必须写后延迟再读：setter 是异步生效的，
        // 紧接着读会拿到写入前的值，看起来像「写不进去」。
        Task { @MainActor in
            var brightness = [String(format: "before=%.3f", savedBrightness)]
            for target in [0.31, 2.0] {
                sceneContext.brightness = target
                try? await Task.sleep(for: .milliseconds(500))
                brightness.append(String(format: "set(%.2f)→%.3f", target, sceneContext.brightness))
            }
            sceneContext.brightness = savedBrightness
            try? await Task.sleep(for: .milliseconds(500))
            brightness.append(String(format: "restored=%.3f", sceneContext.brightness))
            print("[SELFCHECK-BRIGHTNESS] " + brightness.joined(separator: " | "))
        }

        // 画中画要等图层真的收到帧才「可用」，所以延后再采一次
        Task {
            try? await Task.sleep(for: .seconds(6))
            print("[SELFCHECK-PIP] supported=\(PiPController.isSupported) "
                  + "possible=\(pip.isPossible) "
                  + "auto=\(settings.data.autoPictureInPicture) "
                  + "playerState=\(player.state)")
        }
    }

    /// 「切 Tab 不停播」的可复现验证：等起播稳定后切到关注页、停留、再切回来，
    /// 三个时点各打一次播放器状态。修复前第二次会是 idle。
    private func runTabSwitchDemo() {
        let home = homeTab ?? .recommend
        Task { @MainActor in
            @MainActor func snapshot(_ label: String) {                print("[TABTEST] \(label): state=\(player.state) "
                      + "active=\(player.isActive) "
                      + "detail=\(store.detail != nil) "
                      + "danmaku=\(store.messages.count)")
            }
            try? await Task.sleep(for: .seconds(12))
            snapshot("切走前 ")
            router.selectedTab = .follow
            try? await Task.sleep(for: .seconds(5))
            snapshot("在别的Tab")
            router.selectedTab = home
            try? await Task.sleep(for: .seconds(4))
            snapshot("切回来后")
        }
    }

    /// 纯观察：不制造任何中断，只逐秒采样播放链路，
    /// 用于判断「状态是 playing 但字节数不增长」到底停在哪一环。
    private func runStallProbe() {
        Task { @MainActor in
            for tick in 1...40 {
                try? await Task.sleep(for: .seconds(1))
                print("[STALL] \(tick.description)s state=\(player.state) "
                      + "bytes=\(player.receivedBytes.description) "
                      + "\(player.pipelineDiagnostics)")
            }
        }
    }

    /// 自动重连的可复现验证：起播稳定后伪造断流，逐秒采样恢复过程。
    ///
    /// `-dropDemo 1` 只断一次，验证同址快速重试；
    /// `-dropDemo 5` 连续断 5 次，把「同址重试用尽 → 重新取流 → 轮转线路」
    /// 的升级路径也走一遍。伪造的错误与真实断网同路。
    private func runDropDemo(_ drops: Int) {
        Task { @MainActor in
            @MainActor func snapshot(_ label: String) {
                print("[DROPTEST] \(label): state=\(player.state) "
                      + "bytes=\(player.receivedBytes.description) "
                      + "line=\(store.currentLineIndex.description)/\(store.lineCount.description) "
                      + "offline=\(store.offlineNotice ?? "-")")
            }
            try? await Task.sleep(for: .seconds(14))
            snapshot("断流前")
            player.simulateStreamDrops(drops)
            for tick in 1...40 {
                try? await Task.sleep(for: .seconds(1))
                snapshot("断后\(tick.description)秒")
                // 走到终态就收尾：重连要么恢复播放，要么在预算内停止，
                // 不允许无限重连下去
                if case .failed = player.state {
                    print("[DROPTEST] 已进入终态，停止采样")
                    break
                }
            }
        }
    }
    #endif

    private func enterFullscreen() {
        LiveDiagnostics.record("ui.fullscreen", fields: ["page": "live", "enabled": "true"])
        wantsFullscreen = true
        sceneContext.requestLandscapeFullscreen()
        controlsVisible = true
        resetControlsTimer()
    }

    private func exitFullscreen() {
        LiveDiagnostics.record("ui.fullscreen", fields: ["page": "live", "enabled": "false"])
        wantsFullscreen = false
        sceneContext.restoreOrientationBeforeFullscreen()
        isLocked = false
        controlsVisible = true
        hud = nil  // 否则拖动中途退出，再次进全屏会看到上次残留的 HUD
        controlsHideTask?.cancel()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        if controlsVisible { resetControlsTimer() }
    }

    /// 双击播放 / 停止。直播无法真正「暂停」（没有缓冲区可续播），
    /// 因此这里是停止拉流与重新拉流，语义上对用户等价。
    private func togglePlayback() {
        playback.togglePlayback()
        resetControlsTimer()
    }

    private func toggleVideoGravity() {
        player.videoGravity = player.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
    }

    // MARK: - 画中画

    private func configurePiP() {
        guard !multiWatch.owns(playback) else { return }
        pip.attach(player: player, automatic: settings.data.autoPictureInPicture, settings: settings)
        pip.danmakuSnapshot = { [weak playback, weak settings] in
            guard let playback, let settings else { return PiPDanmakuSnapshot() }
            let store = playback.store
            return PiPDanmakuSnapshot(messages: store.messages, settings: settings.danmakuSettings,
                                      isVisible: settings.data.pictureInPictureDanmaku && store.isDanmakuVisible,
                                      isPaused: !playback.playbackRequested, clearToken: playback.player.pipFrames.revision,
                                      sourceID: store.roomID)
        }
        pip.onRequestPlay = { playback.play() }
        pip.onRequestPause = { playback.stopPlayback() }
        pip.isPlaybackRequested = { playback.playbackRequested }
        pip.onStateChange = { active in
            isPiPActive = active
            playback.setPictureInPictureActive(active)
        }
    }

    private func addSelectedRooms() {
        guard !pendingRooms.isEmpty else { resetControlsTimer(); return }
        let additions = pendingRooms
        pendingRooms = []
        pip.detach()
        isPiPActive = false
        playback.setPictureInPictureActive(false)
        multiWatch.begin(from: playback, id: store.detail?.roomID ?? roomID,
                         title: store.detail?.userName ?? fallbackTitle)
        for room in additions { multiWatch.add(id: room.id, title: room.title) }
    }

    /// 控制条 4 秒无操作自动隐藏；任何一次交互都把计时重置
    private func resetControlsTimer() {
        controlsHideTask?.cancel()
        guard isFullscreen, !showingDanmakuSettings else { return }
        #if DEBUG
        // 截图校验时关掉自动隐藏，否则控制条是否出现取决于抓图时机
        if UserDefaults.standard.bool(forKey: "keepControls") { return }
        #endif
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    // MARK: - 播放控制

    private func startPlaybackNow() { playback.play() }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background: playback.setSceneBackgrounded(true)
        case .active: playback.setSceneBackgrounded(false)
        default: break
        }
    }

    // MARK: - 信息区

    /// 标题在上；主播、热度和关注按钮在同一行——关注属于主播，不属于页面。
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.detail?.title ?? fallbackTitle)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 10) {
                AvatarImage(url: store.detail?.userAvatar ?? "", name: store.detail?.userName ?? "",
                            size: 36, live: store.detail?.isLiving == true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.detail?.userName ?? " ")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { roomStatistics }
                        VStack(alignment: .leading, spacing: 2) { roomStatistics }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(CompactLabelStyle())
                }

                Spacer(minLength: 8)

                FollowButton(isFollowed: isFollowed) {
                    guard let detail = store.detail else { return }
                    library.toggleFollow(detail: detail)
                }
                .disabled(store.detail == nil)
            }

            if let notice = store.danmakuNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    @ViewBuilder
    private var roomStatistics: some View {
        if let online = store.detail?.online, online > 0 {
            Label(Theme.formatHot(online), systemImage: "flame")
                .fixedSize(horizontal: true, vertical: false)
        }
        if let duration = store.detail?.liveDuration {
            Label("已播 " + Theme.formatDuration(duration), systemImage: "clock")
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - 弹幕列表

/// 独立成视图，弹幕到达时只重算列表本身
private struct RoomDanmakuList: View {
    let store: RoomStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.userName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(minWidth: 52, alignment: .leading)
                            Text(message.message)
                                .font(.callout)
                                .foregroundStyle(message.color.listForeground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if store.messages.isEmpty {
                    Text(store.phase == .loading ? "连接弹幕中…" : "暂无弹幕")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .onChange(of: store.messages.last?.id) { _, newValue in
                guard let newValue else { return }
                // 不做动画：热门房一批弹幕就会滚一次，动画会把主线程占住
                proxy.scrollTo(newValue, anchor: .bottom)
            }
        }
    }
}

extension LiveMessageColor {
    /// 弹幕列表用前景色。
    ///
    /// 斗鱼绝大多数弹幕是纯白（#FFFFFF），直接用原色在浅色列表背景上完全不可读，
    /// 因此近白色回退为随深浅模式自适应的主文本色；彩色弹幕保留原色作为身份标识。
    var listForeground: Color {
        if r > 225, g > 225, b > 225 {
            return .primary
        }
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
