import SimpleLiveKit
import SwiftUI

// MARK: - 关注

/// 正在直播的主播排在最前；状态尚未刷新时不分组，保持用户的关注顺序。
struct FollowView: View {
    @Environment(LibraryStore.self) private var library
    @State private var path = NavigationPath()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.follows.isEmpty {
                    ContentUnavailableView {
                        Label("还没有关注的主播", systemImage: "heart")
                    } description: {
                        Text("在直播间点主播旁的“关注”\n下次就能在这里找到")
                    } actions: {
                        FollowTransferActions().buttonStyle(.bordered)
                    }
                } else {
                    let groups = library.followGroups()
                    List {
                        if !groups.live.isEmpty {
                            Section {
                                rows(groups.live)
                            } header: {
                                HStack(spacing: 8) {
                                    LiveDot(pulses: true)
                                    Text("正在直播 · \(groups.live.count)")
                                }
                            }
                        }
                        if !groups.looping.isEmpty {
                            Section {
                                rows(groups.looping)
                            } header: {
                                Label("轮播中 · \(groups.looping.count)", systemImage: "repeat")
                            }
                        }
                        if !groups.rest.isEmpty {
                            Section {
                                rows(groups.rest)
                            } header: {
                                if !groups.live.isEmpty || !groups.looping.isEmpty { Text("未开播") }
                            }
                        }
                        Section {
                        } footer: {
                            VStack(alignment: .leading, spacing: 10) {
                                FollowTransferActions()
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                Text("通过隔空投送，把关注合并到另一台设备。")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    .animation(reduceMotion ? nil : Theme.glide, value: groups.live.map(\.roomID) + groups.looping.map(\.roomID))
                }
            }
            .navigationTitle("关注")
            .liveDestinations()
            .toolbar {
                if !library.follows.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
            .refreshable { await library.refreshFollowStatus() }
            .task {
                // 状态未知时首次进入自动刷新一次
                if !library.follows.isEmpty,
                   library.roomStatus.count < library.follows.count {
                    await library.refreshFollowStatus()
                } else {
                    await library.refreshFollowStatusIfStale()
                }
            }
            .refreshesWhenReturning { await library.refreshFollowStatusIfStale() }
        }
    }

    private func rows(_ items: [FollowedRoom]) -> some View {
        ForEach(items) { item in
            NavigationLink(value: RoomRoute(roomID: item.roomID, title: item.title)) {
                FollowRow(item: item, status: library.followStatus(item.roomID))
            }
            .contextMenu {
                Button("查看录像", systemImage: "play.rectangle.on.rectangle") {
                    path.append(ReplayRoute(roomID: item.roomID))
                }
            }
            .swipeActions(edge: .leading) {
                Button("录像", systemImage: "play.rectangle.on.rectangle") {
                    path.append(ReplayRoute(roomID: item.roomID))
                }
                .tint(Theme.accent)
            }
        }
        .onDelete { offsets in
            // 分组后的下标映射回关注列表本身的下标
            let ids = Set(offsets.map { items[$0].roomID })
            library.removeFollows(at: IndexSet(library.follows.indices.filter { ids.contains(library.follows[$0].roomID) }))
        }
    }
}

private struct FollowRow: View {
    let item: FollowedRoom
    /// nil 表示尚未刷新
    let status: LiveRoomStatus?

    var body: some View {
        HStack(spacing: 12) {
            AvatarImage(url: item.avatar, name: item.userName, size: 44, live: status == .live)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.userName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if status == .live {
                LiveDot()
            } else if status == .looping {
                Image(systemName: "repeat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status?.label ?? "")
    }
}

// MARK: - 历史

struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showClearConfirm = false
    @State private var clearFailed = false

    var body: some View {
        content
            .navigationTitle("观看历史")
            .toolbar {
                if !library.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空", systemImage: "trash", role: .destructive) { showClearConfirm = true }
                    }
                }
            }
            .confirmationDialog(
                "清空列表中的直播观看历史？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    do { try library.clearHistory() } catch { clearFailed = true }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("未能清空历史，请重试。", isPresented: $clearFailed) {
                Button("好", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var content: some View {
        if library.history.isEmpty {
            ContentUnavailableView("暂无观看记录", systemImage: "clock.arrow.circlepath",
                                   description: Text("打开过的直播间会出现在这里。"))
        } else {
            List {
                ForEach(library.history) { item in
                    NavigationLink(value: RoomRoute(roomID: item.roomID, title: item.title)) {
                        HistoryRow(item: item)
                    }
                }
                .onDelete { library.removeHistory(at: $0) }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryRecord

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: item.cover, cornerRadius: 8)
                .frame(width: 96)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.userName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.watchedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 我的

struct MineView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.minePath) {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("BrandIcon")
                            .resizable().scaledToFit()
                            .frame(width: 52, height: 52)
                            .clipShape(.rect(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("SwiftPeek").font(.headline)
                            Text("版本 \(Self.appVersion)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    // 行图标用中性灰，品牌橙只留给选中与直播状态
                    NavigationLink(value: MineRoute.history) {
                        Label { Text("观看历史") } icon: {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        }
                        .badge(library.history.count)
                    }
                    NavigationLink(value: MineRoute.settings) {
                        Label { Text("设置") } icon: {
                            Image(systemName: "gearshape").foregroundStyle(.secondary)
                        }
                    }
                }

                if !library.history.isEmpty {
                    Section("最近观看") {
                        ForEach(library.history.prefix(5)) { item in
                            NavigationLink(
                                value: RoomRoute(roomID: item.roomID, title: item.title)
                            ) {
                                HistoryRow(item: item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("我的")
            .navigationDestination(for: MineRoute.self) { route in
                switch route {
                case .settings: SettingsView()
                case .history: HistoryView()
                }
            }
            .liveDestinations()
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
