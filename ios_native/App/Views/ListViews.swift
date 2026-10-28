import SimpleLiveKit
import SwiftUI

/// 直播间封面网格。推荐、分类和搜索共用同一种列宽与间距。
private struct RoomGrid<Rooms: RandomAccessCollection>: View where Rooms.Element == LiveRoomItem {
    let rooms: Rooms
    var loadMore: ((LiveRoomItem) async -> Void)?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ResponsiveMediaGrid(minimumWidth: horizontalSizeClass == .regular ? 216 : 160, spacing: 12, rowSpacing: 20) {
            ForEach(rooms) { room in
                NavigationLink(value: RoomRoute(roomID: room.roomID, title: room.title)) {
                    RoomCard(room: room)
                }
                .buttonStyle(PressableStyle())
                .task { await loadMore?(room) }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct RecommendView: View {
    let store: RecommendStore
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                RoomGrid(rooms: store.rooms) { await store.loadMoreIfNeeded(currentItem: $0) }
                    .padding(.top, 4)

                if store.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 16)
                }

                PhaseStateView(phase: store.phase, isEmpty: store.rooms.isEmpty) {
                    Task { await store.refresh() }
                }
            }
            .navigationTitle("斗鱼推荐")
            .liveDestinations()
            .refreshable { await store.refresh() }
            .task {
                if store.rooms.isEmpty { await store.refresh() }
            }
        }
    }
}

/// 分类：上方一条分区滑块，下方是当前分区的图标网格。
/// 取代原来把全部分区一次铺开的长列表，常用分区一屏可见。
struct CategoryView: View {
    let store: CategoryStore
    @State private var group: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var children: [LiveSubCategory] {
        store.categories.first { $0.id == group }?.children ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 96 : 76), spacing: 8, alignment: .top)],
                          spacing: 20) {
                    ForEach(children) { sub in
                        NavigationLink(value: sub) {
                            CategoryTile(category: sub)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .id(group)
            }
            .safeAreaBar(edge: .top) {
                if !store.categories.isEmpty {
                    ChipBar(items: store.categories.map { ChipItem(id: $0.id, title: $0.name) }, selection: $group)
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .padding(.bottom, 4)
                }
            }
            .navigationTitle("分类")
            .navigationDestination(for: LiveSubCategory.self) { sub in
                CategoryRoomsView(category: sub)
            }
            .liveDestinations()
            .overlay {
                PhaseStateView(phase: store.phase, isEmpty: store.categories.isEmpty) {
                    Task { await store.load() }
                }
            }
            .task {
                await store.load()
                if group == nil { group = store.categories.first?.id }
            }
        }
    }
}

struct CategoryRoomsView: View {
    @State private var store: CategoryRoomsStore

    init(category: LiveSubCategory) {
        _store = State(initialValue: CategoryRoomsStore(category: category))
    }

    var body: some View {
        ScrollView {
            RoomGrid(rooms: store.rooms) { await store.loadMoreIfNeeded(currentItem: $0) }
                .padding(.top, 4)

            PhaseStateView(phase: store.phase, isEmpty: store.rooms.isEmpty) {
                Task { await store.refresh() }
            }
        }
        .navigationTitle(store.category.name)
        .refreshable { await store.refresh() }
        .task {
            if store.rooms.isEmpty { await store.refresh() }
        }
    }
}

struct SearchView: View {
    @Bindable var store: SearchStore
    @State private var path = NavigationPath()

    init(store: SearchStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                Picker("范围", selection: $store.scope) {
                    ForEach(SearchStore.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .onChange(of: store.scope) { store.search() }

                switch store.scope {
                case .rooms:
                    RoomGrid(rooms: store.rooms)
                case .anchors:
                    LazyVStack(spacing: 0) {
                        ForEach(store.anchors) { anchor in
                            NavigationLink(
                                value: RoomRoute(roomID: anchor.roomID, title: anchor.userName)
                            ) {
                                AnchorRow(anchor: anchor)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(PressableStyle())
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if store.phase == .idle {
                    ContentUnavailableView {
                        Label("搜索斗鱼", systemImage: "magnifyingglass")
                    } description: {
                        Text("输入主播昵称或房间号\n也可以直接粘贴直播间、录像链接")
                    }
                    .padding(.top, 40)
                } else {
                    PhaseStateView(
                        phase: store.phase,
                        isEmpty: store.scope == .rooms ? store.rooms.isEmpty : store.anchors.isEmpty,
                        emptyText: "没有找到结果"
                    ) {
                        store.search()
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $store.keyword, prompt: "主播昵称、直播间或录像链接")
            .onSubmit(of: .search) {
                // 粘贴的录像链接直接打开，不当作关键词搜索
                if let replay = DouyuReplayService.parseLink(store.keyword) {
                    path.append(ReplayRoute(hashID: replay.hashID, start: replay.start))
                } else {
                    store.search()
                }
            }
            .liveDestinations()
        }
    }
}
