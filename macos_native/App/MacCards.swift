import SimpleLiveKit
import SwiftUI

/// 直播间卡片：与 iOS 共用 `RoomCard`，悬停时封面在圆角内轻微放大。
struct MacRoomCard: View {
    let room: LiveRoomItem
    var watchedAt: Date?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            RoomCard(room: room, watchedAt: watchedAt, highlighted: hovered)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .help("打开 \(room.userName) 的直播间")
    }
}

struct MacCategoryButton: View {
    let category: LiveSubCategory
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            CategoryTile(category: category, highlighted: hovered)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .help("浏览\(category.name)直播")
    }
}

/// 关注的主播：头像、名字和当前标题一行排开，正在直播的带橙色细环和脉冲点。
struct MacFollowTile: View {
    let item: FollowedRoom
    let isLive: Bool?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AvatarImage(url: item.avatar, name: item.userName, size: 40, live: isLive == true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.userName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if isLive == true { LiveDot() }
            }
            .padding(10)
            .macHoverFill(radius: 12)
        }
        .buttonStyle(PressableStyle())
        .help("进入 \(item.userName) 的直播间")
        .accessibilityValue(isLive == true ? "直播中" : isLive == false ? "未开播" : "")
    }
}

struct MacRoomGrid: View {
    let rooms: [LiveRoomItem]
    let phase: LoadPhase
    let open: (String) -> Void
    let retry: () -> Void
    var loadMore: ((LiveRoomItem) async -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            PhaseStateView(phase: phase, isEmpty: rooms.isEmpty, emptyText: "暂无直播间", retry: retry)
            LazyVGrid(columns: MacDesign.columns, spacing: 28) {
                ForEach(rooms) { room in
                    MacRoomCard(room: room) { open(room.roomID) }
                        .task { await loadMore?(room) }
                }
            }
        }
    }
}
