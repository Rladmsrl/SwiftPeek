import SimpleLiveKit
import SwiftUI

// MARK: - 关注

struct FollowView: View {
    @Environment(LibraryStore.self) private var library
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.follows.isEmpty {
                    ContentUnavailableView {
                        Label("还没有关注的主播", systemImage: "star")
                    } description: {
                        Text("在直播间右上角点星标即可关注")
                    }
                } else {
                    List {
                        ForEach(library.follows) { item in
                            NavigationLink(
                                value: RoomRoute(roomID: item.roomID, title: item.title)
                            ) {
                                FollowRow(item: item, isLive: library.liveStatus[item.roomID])
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
                        .onDelete { library.removeFollows(at: $0) }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 7) {
                    FollowTransferActions().buttonStyle(.glass).controlSize(.regular)
                    Text("通过隔空投送，把关注和观看历史合并到另一台设备")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity).background(.bar)
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
                   library.liveStatus.count < library.follows.count {
                    await library.refreshFollowStatus()
                }
            }
        }
    }
}

private struct FollowRow: View {
    let item: FollowedRoom
    /// nil 表示尚未刷新
    let isLive: Bool?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.avatar)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.circle)
            .overlay(alignment: .bottomTrailing) {
                if isLive == true {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.userName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch isLive {
        case .some(true):
            Text("直播中")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
        case .some(false):
            Text("未开播")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case nil:
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 历史

struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showClearConfirm = false

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
                "清空全部观看历史？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) { library.clearHistory() }
                Button("取消", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var content: some View {
        if library.history.isEmpty {
            ContentUnavailableView("暂无观看记录", systemImage: "clock.arrow.circlepath")
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

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(item.userName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.watchedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
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
                    NavigationLink(value: MineRoute.history) {
                        Label("观看历史", systemImage: "clock.arrow.circlepath")
                            .badge(library.history.count)
                    }
                    NavigationLink(value: MineRoute.settings) {
                        Label("设置", systemImage: "gearshape")
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

                Section("关于") {
                    LabeledContent("应用", value: "SwiftPeek")
                    LabeledContent("站点", value: Sites.douyu.name)
                    LabeledContent("版本", value: Self.appVersion)
                    LabeledContent("解码", value: "自研 FLV + VideoToolbox 硬解")
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
