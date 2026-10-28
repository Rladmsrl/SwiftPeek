import SimpleLiveKit
import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case recommend = "发现", categories = "分类", search = "搜索", follows = "关注", history = "观看历史"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .recommend: "safari"
        case .categories: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .follows: "heart"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// 主窗口：系统侧栏 + 工具栏搜索，内容区首屏就是第一排直播。
/// 分类下钻走详情栏自己的导航栈，返回按钮由系统提供。
struct MacLibraryView: View {
    @State private var selection: LibrarySection? = .recommend
    @State private var detailPath = NavigationPath()
    @State private var recommend = RecommendStore()
    @State private var categories = CategoryStore()
    @State private var search = SearchStore()
    @State private var categoryGroup: String?
    @State private var categoryFilter = ""
    @State private var query = ""
    @State private var linkError: String?
    @FocusState private var searchFocused: Bool
    @Environment(LibraryStore.self) private var library
    @Environment(FollowTransferController.self) private var followTransfer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var section: LibrarySection { selection ?? .recommend }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 260)
        } detail: {
            NavigationStack(path: $detailPath) {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                }
                .navigationTitle(section.rawValue)
                .navigationDestination(for: LiveSubCategory.self) { category in
                    MacCategoryRooms(category: category, open: openRoom)
                }
                .toolbar {
                    if section == .recommend || section == .follows || section == .search {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                                .keyboardShortcut("r", modifiers: .command)
                                .help("刷新（⌘R）")
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索主播、房间号或粘贴链接")
        .searchFocused($searchFocused)
        .onSubmit(of: .search, submit)
        .onChange(of: selection) { _, value in
            detailPath = NavigationPath()
            if value == .search { searchFocused = true }
        }
        .onOpenURL { url in
            if followTransfer.receive(url) { selection = .follows; return }
            if let replay = DouyuReplayService.parseLink(url.absoluteString) {
                openWindow(id: "replay", value: ReplayRoute(hashID: replay.hashID, start: replay.start))
            } else if let id = MacRoomLink.roomID(url.absoluteString) { openRoom(id) }
            else { linkError = "无法识别这个直播间链接" }
        }
        .alert("打开直播间失败", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("好") { linkError = nil }
        } message: { Text(linkError ?? "") }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    // MARK: 侧栏

    private var sidebar: some View {
        List(selection: $selection) {
            Section("浏览") {
                ForEach([LibrarySection.recommend, .categories, .search]) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            Section("我的") {
                Label(LibrarySection.follows.rawValue, systemImage: LibrarySection.follows.symbol)
                    .badge(library.follows.count)
                    .tag(LibrarySection.follows)
                Label(LibrarySection.history.rawValue, systemImage: LibrarySection.history.symbol)
                    .badge(library.history.count)
                    .tag(LibrarySection.history)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .help("设置（⌘,）")
                Spacer()
                Button(action: MacDiagnostics.reveal) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .help("打开播放日志")
                .accessibilityLabel("打开播放日志")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        switch section {
        case .recommend:
            MacRoomGrid(rooms: recommend.rooms, phase: recommend.phase, open: openRoom,
                        retry: { Task { await recommend.refresh() } },
                        loadMore: { await recommend.loadMoreIfNeeded(currentItem: $0) })
                .task { if recommend.rooms.isEmpty { await recommend.refresh() } }
        case .categories:
            categoryContent
        case .follows:
            followContent.task { await library.refreshFollowStatus() }
        case .history:
            historyContent
        case .search:
            searchContent
        }
    }

    private var categoryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                ChipBar(items: categories.categories.map { ChipItem(id: $0.id, title: $0.name) }, selection: $categoryGroup)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
                    TextField("筛选\(categories.categories.first { $0.id == categoryGroup }?.name ?? "分类")", text: $categoryFilter)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(width: 170, height: 28)
                .background(Theme.softFill, in: .capsule)
            }
            PhaseStateView(phase: categories.phase, isEmpty: categories.categories.isEmpty, emptyText: "暂无分类") {
                Task { await categories.load() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 12, alignment: .top)], spacing: 24) {
                ForEach(visibleCategories) { category in
                    MacCategoryButton(category: category) { detailPath.append(category) }
                }
            }
            .id(categoryGroup)
            if visibleCategories.isEmpty, !categories.categories.isEmpty {
                MacEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "没有匹配的分类", detail: "换个关键词，或切换上方分区。")
            }
        }
        .task {
            await categories.load()
            if categoryGroup == nil { categoryGroup = categories.categories.first?.id }
        }
    }

    private var visibleCategories: [LiveSubCategory] {
        let children = categories.categories.first(where: { $0.id == categoryGroup })?.children ?? []
        let filter = categoryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return filter.isEmpty ? children : children.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var followContent: some View {
        let liveFollows = library.follows.filter { library.liveStatus[$0.roomID] == true }
        let otherFollows = library.follows.filter { library.liveStatus[$0.roomID] != true }
        return VStack(alignment: .leading, spacing: 28) {
            if library.follows.isEmpty {
                MacEmptyState(symbol: "heart", title: "还没有关注的主播",
                              detail: "在直播间点主播旁的“关注”，下次就能在这里找到")
                FollowTransferActions().buttonStyle(.glass).frame(maxWidth: .infinity)
            } else {
                if !liveFollows.isEmpty {
                    followGroup("正在直播 · \(liveFollows.count)", liveFollows, pulses: true)
                }
                followGroup(liveFollows.isEmpty ? (library.isRefreshingFollows ? "正在更新开播状态…" : nil) : "未开播", otherFollows)
                HStack(spacing: 12) {
                    Text("通过隔空投送，把关注合并到另一台设备。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    FollowTransferActions().buttonStyle(.glass).controlSize(.small)
                }
                .padding(.top, 8)
            }
        }
        .animation(reduceMotion ? nil : Theme.glide, value: liveFollows.map(\.roomID))
    }

    private func followGroup(_ title: String?, _ items: [FollowedRoom], pulses: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    if pulses { LiveDot(pulses: true) }
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 8)], spacing: 4) {
                ForEach(items) { item in
                    MacFollowTile(item: item, isLive: library.liveStatus[item.roomID]) { openRoom(item.roomID) }
                        .contextMenu {
                            Button("查看录像") { openReplays(item.roomID) }
                            Divider()
                            Button("取消关注", role: .destructive) {
                                if let index = library.follows.firstIndex(where: { $0.roomID == item.roomID }) {
                                    library.removeFollows(at: IndexSet(integer: index))
                                }
                            }
                        }
                }
            }
        }
    }

    private var historyContent: some View {
        Group {
            if library.history.isEmpty {
                MacEmptyState(symbol: "clock.arrow.circlepath", title: "暂无观看记录", detail: "打开过的直播间会出现在这里。")
            } else {
                LazyVGrid(columns: MacDesign.columns, spacing: 28) {
                    ForEach(library.history) { item in
                        MacRoomCard(room: LiveRoomItem(roomID: item.roomID, title: item.title, cover: item.cover, userName: item.userName),
                                    watchedAt: item.watchedAt) { openRoom(item.roomID) }
                            .contextMenu {
                                Button("查看录像") { openReplays(item.roomID) }
                                Divider()
                                Button("删除记录", role: .destructive) {
                                    if let index = library.history.firstIndex(where: { $0.roomID == item.roomID }) {
                                        library.removeHistory(at: IndexSet(integer: index))
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchContent: some View {
        if search.keyword.isEmpty {
            MacEmptyState(symbol: "magnifyingglass", title: "搜索斗鱼",
                          detail: "在右上角输入主播名或房间号\n也可以直接粘贴直播间、录像链接")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("“\(search.keyword)”").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Picker("搜索范围", selection: $search.scope) {
                        ForEach(SearchStore.Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: search.scope) { _, _ in search.search() }
                }
                if search.scope == .rooms {
                    MacRoomGrid(rooms: search.rooms, phase: search.phase, open: openRoom, retry: { search.search() })
                } else {
                    PhaseStateView(phase: search.phase, isEmpty: search.anchors.isEmpty, emptyText: "没有找到主播") { search.search() }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 8)], spacing: 4) {
                        ForEach(search.anchors) { anchor in
                            Button { openRoom(anchor.roomID) } label: {
                                AnchorRow(anchor: anchor).padding(10).macHoverFill(radius: 12)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: 动作

    private func openRoom(_ id: String) { openWindow(id: "room", value: id) }
    private func openReplays(_ roomID: String) { openWindow(id: "replay", value: ReplayRoute(roomID: roomID)) }
    private func submit() {
        if let replay = DouyuReplayService.parseLink(query) {
            openWindow(id: "replay", value: ReplayRoute(hashID: replay.hashID, start: replay.start))
            query = ""
            return
        }
        if let id = MacRoomLink.roomID(query) { openRoom(id); return }
        search.keyword = query
        selection = .search
        search.search()
    }
    private func refresh() {
        Task {
            switch section {
            case .recommend: await recommend.refresh()
            case .follows: await library.refreshFollowStatus()
            case .search: search.search()
            case .categories, .history: break
            }
        }
    }
}

private struct MacCategoryRooms: View {
    @State private var store: CategoryRoomsStore
    let open: (String) -> Void
    init(category: LiveSubCategory, open: @escaping (String) -> Void) {
        _store = State(initialValue: CategoryRoomsStore(category: category))
        self.open = open
    }
    var body: some View {
        ScrollView {
            MacRoomGrid(rooms: store.rooms, phase: store.phase, open: open,
                        retry: { Task { await store.refresh() } },
                        loadMore: { await store.loadMoreIfNeeded(currentItem: $0) })
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 32)
        }
        .navigationTitle(store.category.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("刷新（⌘R）")
            }
        }
        .task { await store.refresh() }
    }
}
