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
    @State private var hud: PlayerHUD?
    @State private var controlsHideTask: Task<Void, Never>?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    init(roomID: String, fallbackTitle: String) {
        self.roomID = roomID
        self.fallbackTitle = fallbackTitle
        _playback = State(initialValue: MobileRoomPlaybackSession(roomID: roomID, player: FLVLivePlayer()))
    }

    /// regular 宽度（iPad / iPhone Duo 内屏 / Mac 放大窗口）左右分栏，
    /// compact 宽度上下堆叠。判断依据是 size class，不是设备型号或方向。
    private var isWide: Bool { horizontalSizeClass == .regular }

    /// 全屏同样由 size class 驱动：iPhone 横屏是 compact 高度，
    /// 手动点全屏按钮也会通过旋转落到同一状态。
    /// iPad 横屏是 regular/regular，因此不会被误判为全屏，保持分栏布局。
    private var isFullscreen: Bool { wantsFullscreen || verticalSizeClass == .compact }

    private var isFollowed: Bool { library.isFollowed(roomID) }

    var body: some View {
        Group {
            if isFullscreen {
                fullscreenLayout
            } else if isWide {
                wideLayout
            } else {
                compactLayout
            }
        }
        .navigationTitle(store.detail?.userName ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar, .tabBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .toolbar {
            // 用文字而不是图标：录像入口没有约定俗成的符号，图标容易看不懂
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ReplayRoute(roomID: store.detail?.roomID ?? roomID)) {
                    Text("录像")
                }
                .accessibilityLabel("查看主播的直播录像")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let detail = store.detail else { return }
                    library.toggleFollow(detail: detail)
                } label: {
                    Image(systemName: isFollowed ? "star.fill" : "star")
                }
                .disabled(store.detail == nil)
                .tint(isFollowed ? Theme.accent : nil)
                .accessibilityLabel(isFollowed ? "取消关注" : "关注")
            }
        }
        .task {
            if homeTab == nil { homeTab = router.selectedTab }
            configurePiP()
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
            // 只旋转、不置 wantsFullscreen，用来验证「用户手动转横屏」这条
            // 纯 size class 驱动的路径能否独立进入全屏
            if UserDefaults.standard.bool(forKey: "rotateOnly") {
                SceneBridge.requestOrientation(.landscapeRight)
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

            // 切 Tab 只是界面被盖住，人还在 App 里浏览——不该停流，
            // 否则切回来要整套重新拉（详情 + 签名 + 取流 + 弹幕重连）。
            // 只有真正离开房间才收摊。
            let isTabSwitch = homeTab != nil && router.selectedTab != homeTab
            guard !isTabSwitch else { return }

            if isFullscreen { SceneBridge.returnToPortrait() }
            playback.close()
            pip.detach()
        }
        .onChange(of: settings.data.autoPictureInPicture) { configurePiP() }
        .onChange(of: settings.data.backgroundAudio) { _, enabled in playback.setBackgroundAudio(enabled) }
        .onChange(of: player.state) { pip.invalidatePlaybackState() }
        .onChange(of: playback.isWorking) { pip.invalidatePlaybackState() }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    // MARK: - 三种布局

    private var compactLayout: some View {
        VStack(spacing: 0) {
            playerSection
            infoSection
            danmakuList
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                playerSection
                infoSection
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            Divider()

            danmakuList
                .frame(width: 320)
        }
    }

    private var fullscreenLayout: some View {
        @Bindable var player = player

        return ZStack {
            Color.black.ignoresSafeArea()

            FLVVideoLayerView(player: player)
                .ignoresSafeArea()

            DanmakuOverlay(
                messages: store.messages,
                settings: store.danmakuRenderSettings,
                isVisible: store.isDanmakuVisible
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()

            // 手势层必须压在状态层**下面**：它是一张铺满全屏、带 contentShape
            // 的透明面，放在上面会把「播放」「重试」「切换线路」这些按钮全挡死。
            PlayerGestureSurface(
                volume: $player.volume,
                hud: $hud,
                isLocked: isLocked,
                onSingleTap: toggleControls,
                onDoubleTap: togglePlayback
            )
            .ignoresSafeArea()

            playerStatusOverlay

            if let hud {
                PlayerHUDView(hud: hud)
            }

            // chrome 不 ignoresSafeArea，由系统逐边避让刘海与 Home 指示条
            if controlsVisible {
                if isLocked {
                    lockToggle
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                } else {
                    fullscreenChrome
                }
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
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonBorderShape(.circle)
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
                        .font(.system(size: 13))
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel(player.videoGravity == .resizeAspect ? "填充画面" : "适应画面")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var fullscreenBottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                danmakuToggleButton
                muteButton
                qualityMenu
                lineButton

                Spacer(minLength: 0)

                resolutionBadge
                pipButton
            }
            .buttonStyle(.glass)
            .controlSize(.small)
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
                .font(.system(size: 14))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .accessibilityLabel(isLocked ? "解锁屏幕" : "锁定屏幕")
    }

    // MARK: - 播放区（非全屏）

    private var playerSection: some View {
        ZStack {
            Color.black
            FLVVideoLayerView(player: player)

            DanmakuOverlay(
                messages: store.messages,
                settings: store.danmakuRenderSettings,
                isVisible: store.isDanmakuVisible
            )
            .allowsHitTesting(false)

            playerStatusOverlay
        }
        .aspectRatio(Theme.coverAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) { controlBar }
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
            HStack(spacing: 8) {
                danmakuToggleButton
                muteButton
                qualityMenu
                lineButton

                Spacer(minLength: 0)

                resolutionBadge

                pipButton

                Button {
                    enterFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel("全屏")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        // 控制条属于前景交互元素，必须留在安全区内（Duo 上安全区是非对称的）
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 控制条零件（全屏与非全屏共用）

    private var danmakuToggleButton: some View {
        Button {
            store.isDanmakuVisible.toggle()
            resetControlsTimer()
        } label: {
            Image(systemName: store.isDanmakuVisible ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 13))
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(store.isDanmakuVisible ? "隐藏弹幕" : "显示弹幕")
    }

    private var muteButton: some View {
        Button {
            player.isMuted.toggle()
            resetControlsTimer()
        } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13))
        }
        .buttonBorderShape(.circle)
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
            } label: {
                Text(store.qualities[safe: store.selectedQualityIndex]?.quality ?? "清晰度")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.glass)
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
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
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
                    .font(.system(size: 13))
            }
            .buttonBorderShape(.circle)
            .disabled(!isPiPActive && !player.isActive)
            .accessibilityLabel(isPiPActive ? "退出画中画" : "画中画")
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        if let size = player.videoSize, store.showResolutionBadge {
            // 用 description 拼接，避免 Text 插值对 Int 自动加千位分隔符
            Text("\(Int(size.width).description)×\(Int(size.height).description)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
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

        let savedBrightness = SceneBridge.brightness
        lines.append("scene=\(SceneBridge.windowScene != nil)")
        print("[SELFCHECK] " + lines.joined(separator: " | "))

        // 亮度必须写后延迟再读：setter 是异步生效的，
        // 紧接着读会拿到写入前的值，看起来像「写不进去」。
        Task { @MainActor in
            var brightness = [String(format: "before=%.3f", savedBrightness)]
            for target in [0.31, 2.0] {
                SceneBridge.brightness = target
                try? await Task.sleep(for: .milliseconds(500))
                brightness.append(String(format: "set(%.2f)→%.3f", target, SceneBridge.brightness))
            }
            SceneBridge.brightness = savedBrightness
            try? await Task.sleep(for: .milliseconds(500))
            brightness.append(String(format: "restored=%.3f", SceneBridge.brightness))
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
        wantsFullscreen = true
        controlsVisible = true
        resetControlsTimer()
        SceneBridge.enterLandscape()
    }

    private func exitFullscreen() {
        wantsFullscreen = false
        isLocked = false
        controlsVisible = true
        hud = nil  // 否则拖动中途退出，再次进全屏会看到上次残留的 HUD
        controlsHideTask?.cancel()
        SceneBridge.returnToPortrait()
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
        pip.attach(player: player, automatic: settings.data.autoPictureInPicture)
        pip.onRequestPlay = { playback.play() }
        pip.onRequestPause = { playback.stopPlayback() }
        pip.isPlaybackRequested = { playback.playbackRequested }
        pip.onStateChange = { active in
            isPiPActive = active
            playback.setPictureInPictureActive(active)
        }
    }

    /// 控制条 4 秒无操作自动隐藏；任何一次交互都把计时重置
    private func resetControlsTimer() {
        controlsHideTask?.cancel()
        guard isFullscreen else { return }
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

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: store.detail?.userAvatar ?? "")) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(.quaternary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(.circle)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.detail?.title ?? fallbackTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(store.detail?.userName ?? "")
                        if let online = store.detail?.online, online > 0 {
                            Label(Theme.formatHot(online), systemImage: "flame.fill")
                        }
                        if let duration = store.detail?.liveDuration {
                            Label(Theme.formatDuration(duration), systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if let notice = store.danmakuNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 弹幕列表

    private var danmakuList: some View {
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
