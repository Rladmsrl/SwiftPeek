import SimpleLiveKit
import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case recommend = "发现", categories = "分类", follows = "我的关注", history = "观看历史", search = "搜索"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .recommend: "safari"
        case .categories: "square.grid.2x2"
        case .follows: "heart"
        case .history: "clock.arrow.circlepath"
        case .search: "magnifyingglass"
        }
    }
}

struct MacLibraryView: View {
    @State private var selection: LibrarySection = .recommend
    @State private var recommend = RecommendStore()
    @State private var categories = CategoryStore()
    @State private var search = SearchStore()
    @State private var selectedCategory: LiveSubCategory?
    @State private var categoryGroup: String?
    @State private var categoryFilter = ""
    @State private var query = ""
    @State private var linkError: String?
    @FocusState private var searchFocused: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(FollowTransferController.self) private var followTransfer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        pageHeading
                        content
                    }.padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 32)
                }.scrollIndicators(.hidden)
            }
        }
        .background(MacBackdrop())
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image("BrandIcon")
                    .resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SwiftPeek").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Just live. Natively.").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 8).padding(.top, 18)

            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    sidebarCaption("探索")
                    navItem(.recommend)
                    navItem(.categories)
                    navItem(.search)
                    sidebarCaption("我的收藏").padding(.top, 20)
                    navItem(.follows, count: library.follows.count)
                    navItem(.history, count: library.history.count)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(MacDesign.accent).frame(width: 6, height: 6)
                    Text("斗鱼直播").font(.system(size: 11, weight: .medium))
                }
                Text("一个安静、专注的直播空间").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(12)
            HStack {
                SettingsLink {
                    Label("设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(.interaction, Capsule())
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                Spacer()
                Button(action: MacDiagnostics.reveal) { Image(systemName: "doc.text.magnifyingglass").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("打开播放日志")
            }.padding(.horizontal, 8)
        }.padding(.horizontal, 14).padding(.bottom, 22)
            .background(.ultraThinMaterial)
            .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.04)).frame(width: 1) }
    }

    private func sidebarCaption(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            .padding(.horizontal, 13).padding(.bottom, 5)
    }

    private func navItem(_ section: LibrarySection, count: Int? = nil) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = section }
            if section == .search { searchFocused = true }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: selection == section ? .semibold : .regular))
                    .foregroundStyle(selection == section ? MacDesign.accent : .secondary)
                    .frame(width: 20)
                Text(section.rawValue).font(.system(size: 13, weight: selection == section ? .semibold : .medium))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }.foregroundStyle(selection == section ? .primary : .secondary)
                .padding(.horizontal, 13).frame(height: 42).contentShape(.rect(cornerRadius: 13))
        }.buttonStyle(.plain)
            .background {
                if selection == section {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.primary.opacity(0.065))
                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.04), lineWidth: 1) }
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(selection == section ? [.isSelected] : [])
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("斗鱼").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                Text(selection.rawValue).foregroundStyle(.primary.opacity(0.8))
            }.font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("搜索主播、房间号、直播或录像链接", text: $query)
                    .font(.system(size: 12)).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit(submit).accessibilityIdentifier("roomSearch")
                if query.isEmpty {
                    Text("⌘ F").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }.padding(.horizontal, 14).frame(width: 286, height: 38)
                .glassEffect(.regular, in: .capsule)
        }.padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 15)
    }

    private var pageHeading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(heading).font(.system(size: 27, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if selection == .recommend || selection == .follows || selection == .search {
                MacIconButton(symbol: "arrow.clockwise", help: "刷新", action: refresh)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var heading: String {
        switch selection {
        case .recommend: "发现精彩现场"
        case .categories: "找到你的热爱"
        case .follows: "我的关注"
        case .history: "最近看过"
        case .search: search.keyword.isEmpty ? "想看些什么？" : "搜索结果"
        }
    }
    private var subtitle: String {
        switch selection {
        case .recommend: "游戏、生活与每一个值得停留的瞬间。"
        case .categories: "从熟悉的游戏，到未知的新世界。"
        case .follows: "喜欢的主播，都在这里。"
        case .history: "好看的内容，随时回来继续。"
        case .search: search.keyword.isEmpty ? "输入主播名称、房间号，或直接粘贴直播 / 录像链接。" : "与「\(search.keyword)」有关的直播"
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .recommend:
            recommendationContent
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

    private var recommendationContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let room = recommend.rooms.first, recommend.phase == .loaded {
                MacFeaturedRoom(room: room) { openRoom(room.roomID) }
            }
            HStack {
                Text("正在热播").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("为你发现更多直播").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            MacRoomGrid(rooms: recommend.rooms, phase: recommend.phase, open: openRoom,
                        retry: { Task { await recommend.refresh() } },
                        loadMore: { await recommend.loadMoreIfNeeded(currentItem: $0) })
        }.task { if recommend.rooms.isEmpty { await recommend.refresh() } }
    }

    private var categoryContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let selectedCategory {
                HStack(spacing: 12) {
                    Button {
                        self.selectedCategory = nil
                    } label: { Label("全部分类", systemImage: "arrow.left").font(.system(size: 12)).padding(.horizontal, 5) }
                        .buttonStyle(.glass)
                    Text("/").foregroundStyle(.tertiary)
                    Text(selectedCategory.name).font(.system(size: 15, weight: .semibold))
                }
                MacCategoryRooms(category: selectedCategory, open: openRoom).id(selectedCategory.id)
            } else {
                categoryBrowser
            }
        }.task {
            await categories.load()
            if categoryGroup == nil { categoryGroup = categories.categories.first?.id }
        }
    }

    private var categoryBrowser: some View {
        VStack(alignment: .leading, spacing: 24) {
            GlassEffectContainer(spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 10)], spacing: 10) {
                    ForEach(categories.categories) { group in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { categoryGroup = group.id }
                        } label: {
                            Text(group.name).font(.system(size: 12, weight: categoryGroup == group.id ? .semibold : .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .contentShape(.interaction, Capsule())
                                .foregroundStyle(categoryGroup == group.id ? MacDesign.accent : .secondary)
                        }.buttonStyle(.plain)
                            .glassEffect(.regular.tint(categoryGroup == group.id ? MacDesign.accent.opacity(0.14) : .clear).interactive(), in: .capsule)
                            .accessibilityAddTraits(categoryGroup == group.id ? [.isSelected] : [])
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Text(categories.categories.first(where: { $0.id == categoryGroup })?.name ?? "全部分类")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(visibleCategories.count)").font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: .capsule)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
                    TextField("筛选当前分类", text: $categoryFilter).textFieldStyle(.plain)
                }.font(.system(size: 11)).frame(width: 150)
            }
            PhaseStateView(phase: categories.phase, isEmpty: categories.categories.isEmpty, emptyText: "暂无分类") {
                Task { await categories.load() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)], spacing: 12) {
                ForEach(visibleCategories) { category in
                    MacCategoryCard(category: category) { selectedCategory = category }
                }
            }
            if visibleCategories.isEmpty, !categories.categories.isEmpty {
                MacEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "没有匹配的分类", detail: "试试其他关键词，或切换上方分区。")
            }
        }
    }

    private var visibleCategories: [LiveSubCategory] {
        let children = categories.categories.first(where: { $0.id == categoryGroup })?.children ?? []
        let filter = categoryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return filter.isEmpty ? children : children.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var followContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("把关注和观看历史带到另一台设备").font(.system(size: 13, weight: .medium))
                    Text("分享 → 隔空投送 → 接收后合并").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                FollowTransferActions().buttonStyle(.glass).font(.system(size: 12))
            }.padding(16).macSurface(radius: 14)
            if library.isRefreshingFollows {
                ProgressView("正在更新开播状态").font(.caption).controlSize(.small)
            }
            if library.follows.isEmpty {
                MacEmptyState(symbol: "heart", title: "把喜欢的主播留在这里", detail: "在直播间点击关注，下次打开就能找到。")
            } else {
                LazyVGrid(columns: MacDesign.columns, spacing: 20) {
                    ForEach(library.follows) { item in
                        Button { openRoom(item.roomID) } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    MacAvatar(url: item.avatar, name: item.userName, size: 46)
                                    Spacer()
                                    MacLiveBadge(title: statusText(item.roomID), live: library.liveStatus[item.roomID] == true)
                                }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.userName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                                }
                                HStack {
                                    Text("进入直播间").font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                                }.foregroundStyle(MacDesign.accent)
                            }.padding(20).macSurface().macHover()
                        }.buttonStyle(.plain)
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
    }

    private var historyContent: some View {
        Group {
            if library.history.isEmpty {
                MacEmptyState(symbol: "clock.arrow.circlepath", title: "精彩，值得再看", detail: "你打开过的直播间会出现在这里。")
            } else {
                LazyVGrid(columns: MacDesign.columns, spacing: 20) {
                    ForEach(library.history) { item in
                        MacRoomCard(room: LiveRoomItem(roomID: item.roomID, title: item.title, cover: item.cover, userName: item.userName),
                                    live: false, watchedAt: item.watchedAt) { openRoom(item.roomID) }
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

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("搜索范围", selection: $search.scope) {
                ForEach(SearchStore.Scope.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 220)
                .onChange(of: search.scope) { _, _ in search.search() }
            if search.scope == .rooms {
                MacRoomGrid(rooms: search.rooms, phase: search.phase, open: openRoom, retry: { search.search() })
            } else {
                PhaseStateView(phase: search.phase, isEmpty: search.anchors.isEmpty, emptyText: "没有找到主播") { search.search() }
                LazyVGrid(columns: MacDesign.columns, spacing: 20) {
                    ForEach(search.anchors) { anchor in
                        Button { openRoom(anchor.roomID) } label: {
                            HStack(spacing: 12) {
                                MacAvatar(url: anchor.avatar, name: anchor.userName, size: 44)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(anchor.userName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    MacLiveBadge(title: anchor.isLive ? "直播中" : "未开播", live: anchor.isLive)
                                }
                                Spacer(minLength: 0)
                            }.padding(20).macSurface().macHover()
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func statusText(_ id: String) -> String {
        guard let live = library.liveStatus[id] else { return "待查询" }
        return live ? "直播中" : "未开播"
    }
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
        searchFocused = false
    }
    private func refresh() {
        Task {
            switch selection {
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
        VStack(alignment: .trailing, spacing: 18) {
            Button("刷新直播间") { Task { await store.refresh() } }.buttonStyle(.glass).font(.caption)
            MacRoomGrid(rooms: store.rooms, phase: store.phase, open: open,
                        retry: { Task { await store.refresh() } },
                        loadMore: { await store.loadMoreIfNeeded(currentItem: $0) })
        }.task { await store.refresh() }
    }
}
