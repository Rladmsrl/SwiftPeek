import SwiftUI
import SimpleLiveKit

typealias PhoneMultiWatch = MultiWatchSession<FLVLivePlayer>
typealias PhoneMultiWatchRoom = MultiWatchRoom<FLVLivePlayer>

struct MultiWatchView: View {
    @Environment(PhoneMultiWatch.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingRooms = false
    @State private var pip = PiPController()
    @State private var pipRoomID: String?
    @State private var pipActive = false

    var body: some View {
        pipNavigation
        .onChange(of: settings.data.backgroundAudio) { workspace.refreshSettings() }
        .onChange(of: settings.data.pictureInPictureDanmaku) { workspace.refreshSettings(); pip.refreshDanmaku() }
        .onChange(of: workspace.danmakuMode) { pip.refreshDanmaku() }
        .onChange(of: workspace.pipCandidate?.playback.store.isDanmakuVisible) { pip.refreshDanmaku() }
        .onChange(of: settings.data.autoPictureInPicture) { configurePiP() }
        .onChange(of: scenePhase) { _, value in workspace.setBackgrounded(value == .background) }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in updateResourcePressure() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in updateResourcePressure() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            workspace.setConstrained(true)
            workspace.focused = true
        }
        .onDisappear { pip.detach() }
    }

    private var pipNavigation: some View {
        navigation
            .task {
                updateResourcePressure()
                workspace.setBackgrounded(scenePhase == .background)
                if workspace.rooms.isEmpty { choosingRooms = true }
                configurePiP()
            }
            .onChange(of: workspace.pipCandidate?.id) { configurePiP() }
            .onChange(of: workspace.isRunning) { configurePiP() }
            .onChange(of: workspace.pipCandidate?.playback.player.state) { pip.invalidatePlaybackState() }
            .onChange(of: workspace.pipCandidate?.playback.isWorking) { pip.invalidatePlaybackState() }
    }

    private var navigation: some View {
        NavigationStack {
            playback
                .navigationTitle("多画面")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(workspace.hasOrigin ? "返回单画面" : "完成", systemImage: "chevron.left") { pip.detach(); workspace.finish() }
                            .accessibilityIdentifier("multiwatch.close")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("添加直播间", systemImage: "plus") { choosingRooms = true }
                            .disabled(workspace.rooms.count >= 4)
                            .accessibilityIdentifier("multiwatch.add")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if workspace.isRunning { controls }
                }
                .sheet(isPresented: $choosingRooms) {
                    MultiWatchPicker(existing: workspace.rooms.map { MultiWatchSelection(id: $0.id, title: $0.name) }) { additions in
                        for room in additions { workspace.add(id: room.id, title: room.title) }
                    }
                }
        }
    }

    private var playback: some View {
        GeometryReader { geometry in
            let layout = layout(in: geometry)
            MultiWatchPaneLayout(size: geometry.size, frames: layout.tiles) {
                ForEach(Array(workspace.rooms.enumerated()), id: \.element.id) { index, room in
                    MultiWatchTile(room: room, pipActive: pipActive && pipRoomID == room.id)
                        .clipped()
                        .opacity(layout.tiles[index].isEmpty ? 0 : 1)
                        .allowsHitTesting(!layout.tiles[index].isEmpty)
                        .accessibilityHidden(layout.tiles[index].isEmpty)
                }
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func layout(in geometry: GeometryProxy) -> MultiWatchLayout {
        var divisions: [CGRect] = [], occlusions: [CGRect] = []
        if #available(iOS 27.1, *) {
            divisions = geometry.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
            occlusions = geometry.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        }
        return MultiWatchLayout(size: geometry.size, count: workspace.rooms.count,
                               selected: workspace.rooms.firstIndex { $0.id == workspace.selectedID } ?? 0,
                               mode: workspace.layoutMode, focused: workspace.focused,
                               divisions: divisions, occlusions: occlusions)
    }

    private var controls: some View {
        @Bindable var workspace = workspace
        return VStack(spacing: 0) {
            if workspace.constrained {
                Text("已降低自动画质，减轻设备负载").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button(workspace.focused ? "返回多画面" : "放大主画面", systemImage: workspace.focused ? "rectangle.split.2x2" : "arrow.up.left.and.arrow.down.right") {
                    workspace.focused.toggle()
                }
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                .accessibilityIdentifier("multiwatch.focus")
                Button(workspace.hasSound ? "全部静音" : "取消静音", systemImage: workspace.hasSound ? "speaker.wave.2" : "speaker.slash") {
                    workspace.toggleAllSound()
                }
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                .accessibilityIdentifier("multiwatch.mute")
                Menu {
                    Picker("弹幕", selection: $workspace.danmakuMode) {
                        ForEach(MultiWatchDanmakuMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                                .accessibilityIdentifier("multiwatch.danmaku.\(mode.rawValue)")
                        }
                    }
                } label: {
                    Label("弹幕：\(workspace.danmakuMode.label)", systemImage: workspace.danmakuMode == .off ? "text.bubble" : "text.bubble.fill")
                }
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                .accessibilityValue(workspace.danmakuMode.label)
                .accessibilityIdentifier("multiwatch.danmaku")
                Menu {
                    Picker("布局", selection: $workspace.layoutMode) {
                        ForEach(MultiWatchLayout.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("锁定当前声音", isOn: $workspace.audioLocked)
                    if let room = workspace.pipCandidate {
                        Button(pipActive ? "退出画中画" : "画中画：\(room.name)", systemImage: "pip.enter") {
                            configurePiP(); pip.toggle()
                        }
                        .disabled(!room.playback.player.isActive || !pip.isPossible)
                    }
                    Button("结束全部播放", role: .destructive) { pip.detach(); workspace.finish(stopOrigin: true) }
                } label: { Label("更多", systemImage: "ellipsis") }
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                .accessibilityIdentifier("multiwatch.more")
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 20, weight: .medium))
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .environment(\.defaultMinListRowHeight, 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .controlSize(.large)
    }

    private func updateResourcePressure() {
        let process = ProcessInfo.processInfo
        workspace.setConstrained(process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical)
    }

    private func configurePiP() {
        guard workspace.isRunning, let room = workspace.pipCandidate else {
            pip.detach(); pipRoomID = nil; pipActive = false; workspace.setPiP(nil)
            return
        }
        if pipRoomID != room.id {
            pip.detach()
            pipActive = false
            workspace.setPiP(nil)
            pipRoomID = room.id
        }
        pip.attach(player: room.playback.player, automatic: settings.data.autoPictureInPicture, settings: settings)
        pip.onRequestPlay = { [weak room] in room?.playback.play() }
        pip.onRequestPause = { [weak room] in room?.playback.stopPlayback() }
        pip.isPlaybackRequested = { [weak room] in room?.playback.playbackRequested ?? false }
        pip.onStateChange = { active in
            pipActive = active
            workspace.setPiP(active ? room.id : nil)
        }
        pip.danmakuSnapshot = { [weak room, weak settings, weak workspace] in
            guard let room, let settings, let workspace else { return PiPDanmakuSnapshot() }
            return PiPDanmakuSnapshot(messages: room.playback.store.messages, settings: settings.danmakuSettings,
                                      isVisible: workspace.danmakuMode != .off && settings.data.pictureInPictureDanmaku && room.playback.store.isDanmakuVisible,
                                      sourceID: room.id)
        }
    }
}

private struct MultiWatchPaneLayout: Layout {
    let size: CGSize
    let frames: [CGRect]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct MultiWatchTile: View {
    let room: PhoneMultiWatchRoom
    let pipActive: Bool
    @Environment(PhoneMultiWatch.self) private var workspace
    private var selected: Bool { workspace.selectedID == room.id }
    private var audible: Bool { !workspace.muted && workspace.audibleID == room.id }
    private var player: FLVLivePlayer { room.playback.player }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                FLVVideoLayerView(player: player).allowsHitTesting(false)
                if workspace.showsDanmaku(for: room) {
                    DanmakuOverlay(messages: room.playback.store.messages, settings: workspace.danmakuSettings(for: room),
                                   isVisible: true)
                        .allowsHitTesting(false)
                }
                status
            }
            .contentShape(.rect)
            .onTapGesture { workspace.select(room.id) }
            .accessibilityLabel("主画面：\(room.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { workspace.select(room.id) }
            .accessibilityIdentifier("multiwatch.tile.\(room.id)")
            HStack(spacing: 0) {
                Button { workspace.toggleSound(room.id) } label: {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel(audible ? "关闭\(room.name)的声音" : "收听\(room.name)")
                .accessibilityValue(audible ? "有声" : "静音")
                .accessibilityIdentifier("multiwatch.sound.\(room.id)")
                Button { workspace.select(room.id) } label: {
                    Text(room.name).lineLimit(1)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .accessibilityLabel("切换到\(room.name)")
                .accessibilityValue((selected ? "主画面" : "副画面") + (audible ? "，正在出声" : "，静音"))
                .accessibilityIdentifier("multiwatch.select.\(room.id)")
                Menu {
                    Button("放大这一路", systemImage: "arrow.up.left.and.arrow.down.right") {
                        workspace.select(room.id); workspace.focused = true
                    }
                    Button("听这一路", systemImage: "speaker.wave.2") { workspace.listen(room.id) }
                    Button(player.isActive || room.playback.isWorking ? "暂停" : "播放 / 重试", systemImage: player.isActive ? "pause" : "play") {
                        room.playback.togglePlayback()
                    }
                    Toggle("本画面弹幕", isOn: Binding(get: { room.playback.store.isDanmakuVisible }, set: { workspace.setDanmakuVisible($0, for: room) }))
                    Menu("画质") {
                        Button(room.manualQuality ? "自动" : "自动 ✓") { workspace.useAutomaticQuality(room) }
                        ForEach(Array(room.playback.store.qualities.enumerated()), id: \.offset) { index, quality in
                            Button(quality.quality + (index == room.playback.store.selectedQualityIndex ? " ✓" : "")) {
                                workspace.chooseQuality(index, for: room)
                            }
                        }
                    }
                    .disabled(room.playback.isWorking)
                    if room.playback.store.lineCount > 1 {
                        Button("切换线路") { room.playback.switchLine() }.disabled(room.playback.isWorking)
                    }
                    if workspace.rooms.count > 1 {
                        Menu("交换位置") {
                            ForEach(workspace.rooms.filter { $0.id != room.id }) { other in
                                Button(other.name) { workspace.move(room.id, to: other.id) }
                            }
                        }
                    }
                    Button("移除直播间", role: .destructive) { workspace.remove(room.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel("\(room.name)的播放选项")
                .accessibilityIdentifier("multiwatch.options.\(room.id)")
            }
            .foregroundStyle(selected ? Theme.accent : .primary)
            .background(.background)
            .buttonStyle(.plain)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        .onChange(of: room.playback.isWorking) { _, working in
            if !working { workspace.refreshAutomaticQuality() }
        }
    }

    @ViewBuilder private var status: some View {
        if pipActive {
            Text("正在画中画中播放").font(.caption).foregroundStyle(.white)
        } else if room.playback.isWorking || player.state == .connecting || player.state == .buffering {
            ProgressView().tint(.white)
        } else if case .failed = player.state {
            retry("播放中断")
        } else if room.playback.store.detail?.isLiving == false {
            retry("主播未开播")
        } else if case .failed = room.playback.store.phase {
            retry("加载失败")
        } else if case .reconnecting = player.state {
            Text("正在重连…").font(.caption).foregroundStyle(.white)
        } else if player.state == .idle {
            Button("播放", systemImage: "play.fill") { room.playback.play() }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).foregroundStyle(.white)
        }
    }

    private func retry(_ title: String) -> some View {
        Button { room.playback.play() } label: {
            Label(title + " · 重试", systemImage: "arrow.clockwise")
                .font(.caption).padding(10)
        }
        .foregroundStyle(.white)
    }
}

struct MultiWatchPicker: View {
    enum Source: String, CaseIterable, Identifiable {
        case history = "历史", follow = "关注", search = "搜索"
        var id: Self { self }
    }

    let existing: [MultiWatchSelection]
    let onAdd: ([MultiWatchSelection]) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var search = SearchStore()
    @State private var query = ""
    @State private var source: Source = .history
    @State private var selection: [MultiWatchSelection] = []

    private var count: Int { existing.count + selection.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("正在看 \(existing.count) 路 · 已选 \(selection.count) 路")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("添加来源", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("multiwatch.picker.source")
                }
                switch source {
                case .history:
                    Section("最近观看") {
                        ForEach(library.history.prefix(50)) { room in row(id: room.roomID, title: room.userName) }
                        if library.history.isEmpty { Text("暂无历史记录，可切换关注或搜索").foregroundStyle(.secondary) }
                    }
                case .follow:
                    Section("关注的主播") {
                        ForEach(library.follows) { room in row(id: room.roomID, title: room.userName) }
                        if library.follows.isEmpty { Text("暂无关注，可切换历史或搜索").foregroundStyle(.secondary) }
                    }
                case .search:
                    if let id = MultiWatchRoomInput.roomID(query) {
                        Section("房间号 / 链接") { row(id: id, title: "直播间 \(id)") }
                    }
                    Section("搜索结果") {
                        ForEach(search.rooms) { room in row(id: room.roomID, title: room.userName) }
                        if search.phase == .loading { ProgressView("搜索中…") }
                        if case .failed(let error) = search.phase { Text(error).foregroundStyle(.secondary) }
                        if search.phase == .loaded && search.rooms.isEmpty { Text("没有找到直播间") }
                        if search.phase == .idle { Text("输入主播名后搜索，也可直接粘贴房间号或斗鱼链接").foregroundStyle(.secondary) }
                    }
                }
                if !selection.isEmpty {
                    Section("待添加 · 最多同时看 4 路") {
                        ForEach(selection) { room in row(id: room.id, title: room.title) }
                    }
                }
            }
            .navigationTitle("加看直播间")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Text("已选 \(selection.count) 路，还可选 \(max(0, 4 - count)) 路")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("添加（\(selection.count)）", action: commit)
                        .buttonStyle(.borderedProminent).disabled(selection.isEmpty)
                        .accessibilityIdentifier("multiwatch.picker.add")
                }
                .padding(12)
                .background(.bar)
            }
            .searchable(text: $query, prompt: "主播、房间号或斗鱼链接")
            .onSubmit(of: .search) { source = .search; search.keyword = query; search.search() }
            .onChange(of: query) { _, value in
                if !value.isEmpty { source = .search }
                search.keyword = ""; search.search()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("multiwatch.picker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加（\(selection.count)）", action: commit)
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("multiwatch.picker.toolbarAdd")
                }
            }
        }
    }

    private func commit() {
        guard !selection.isEmpty, count <= 4 else { return }
        onAdd(selection)
        dismiss()
    }

    private func row(id: String, title: String) -> some View {
        let playing = existing.contains { $0.id == id }
        let selected = selection.contains { $0.id == id }
        return Button {
            if selected { selection.removeAll { $0.id == id } }
            else if count < 4 { selection.append(MultiWatchSelection(id: id, title: title)) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(playing ? "正在播放" : id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: playing ? "play.circle.fill" : (selected ? "checkmark.circle.fill" : "plus.circle"))
                    .foregroundStyle(Theme.accent)
            }.frame(minHeight: 44)
        }
        .disabled(playing || (!selected && count >= 4))
        .accessibilityIdentifier("multiwatch.pick.\(id)")
    }
}
