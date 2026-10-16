import SimpleLiveKit
import SwiftUI

struct RecommendView: View {
    let store: RecommendStore
    @Binding var path: NavigationPath
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var grid: AdaptiveGrid { AdaptiveGrid(horizontalSizeClass: horizontalSizeClass) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: grid.columns, spacing: 18) {
                    ForEach(store.rooms) { room in
                        NavigationLink(value: RoomRoute(roomID: room.roomID, title: room.title)) {
                            RoomCard(room: room)
                        }
                        .buttonStyle(.plain)
                        .task { await store.loadMoreIfNeeded(currentItem: room) }
                    }
                }
                .padding(.horizontal, 16)

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
            .navigationDestination(for: RoomRoute.self) { route in
                RoomView(roomID: route.roomID, fallbackTitle: route.title)
            }
            .refreshable { await store.refresh() }
            .task {
                if store.rooms.isEmpty { await store.refresh() }
            }
        }
    }
}

struct CategoryView: View {
    let store: CategoryStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.categories) { category in
                    Section(category.name) {
                        ForEach(category.children) { sub in
                            NavigationLink(value: sub) {
                                Text(sub.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("分类")
            .navigationDestination(for: LiveSubCategory.self) { sub in
                CategoryRoomsView(category: sub)
            }
            .navigationDestination(for: RoomRoute.self) { route in
                RoomView(roomID: route.roomID, fallbackTitle: route.title)
            }
            .overlay {
                PhaseStateView(phase: store.phase, isEmpty: store.categories.isEmpty) {
                    Task { await store.load() }
                }
            }
            .task { await store.load() }
        }
    }
}

struct CategoryRoomsView: View {
    @State private var store: CategoryRoomsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(category: LiveSubCategory) {
        _store = State(initialValue: CategoryRoomsStore(category: category))
    }

    private var grid: AdaptiveGrid { AdaptiveGrid(horizontalSizeClass: horizontalSizeClass) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: grid.columns, spacing: 18) {
                ForEach(store.rooms) { room in
                    NavigationLink(value: RoomRoute(roomID: room.roomID, title: room.title)) {
                        RoomCard(room: room)
                    }
                    .buttonStyle(.plain)
                    .task { await store.loadMoreIfNeeded(currentItem: room) }
                }
            }
            .padding(.horizontal, 16)

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(store: SearchStore) {
        self.store = store
    }

    private var grid: AdaptiveGrid { AdaptiveGrid(horizontalSizeClass: horizontalSizeClass) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("范围", selection: $store.scope) {
                    ForEach(SearchStore.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onChange(of: store.scope) { store.search() }

                switch store.scope {
                case .rooms:
                    LazyVGrid(columns: grid.columns, spacing: 18) {
                        ForEach(store.rooms) { room in
                            NavigationLink(value: RoomRoute(roomID: room.roomID, title: room.title)) {
                                RoomCard(room: room)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                case .anchors:
                    LazyVStack(spacing: 0) {
                        ForEach(store.anchors) { anchor in
                            NavigationLink(
                                value: RoomRoute(roomID: anchor.roomID, title: anchor.userName)
                            ) {
                                AnchorRow(anchor: anchor)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if store.phase == .idle {
                    ContentUnavailableView("搜索斗鱼", systemImage: "magnifyingglass")
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
            .searchable(text: $store.keyword, prompt: "主播昵称或直播间")
            .onSubmit(of: .search) { store.search() }
            .navigationDestination(for: RoomRoute.self) { route in
                RoomView(roomID: route.roomID, fallbackTitle: route.title)
            }
        }
    }
}
