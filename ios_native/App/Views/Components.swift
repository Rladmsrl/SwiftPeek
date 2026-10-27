import SimpleLiveKit
import SwiftUI

// MARK: - 封面

/// 房间封面。固定 16:9，加载中显示低对比占位，失败显示图标而不是空白。
struct CoverImage: View {
    let url: String
    var cornerRadius: CGFloat = Theme.cardCorner

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(Theme.coverAspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

// MARK: - 房间卡片

extension LiveRoomStatus {
    var label: String {
        switch self {
        case .unknown: "状态待确认"
        case .live: "直播中"
        case .looping: "轮播"
        }
    }
}

struct RoomStatusBadge: View {
    let status: LiveRoomStatus

    var body: some View {
        Label(status.label, systemImage: status == .live ? "dot.radiowaves.left.and.right" : "repeat")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }
}

struct RoomCard: View {
    let room: LiveRoomItem
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: room.cover)
                .overlay(alignment: .topLeading) {
                    if room.status != .unknown {
                        RoomStatusBadge(status: room.status).padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if settings.data.showHotBadge {
                        HotBadge(value: room.online)
                            .padding(6)
                    }
                }

            Text(room.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            Text(room.userName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

/// 热度徽标。用 Liquid Glass 承载，浮在封面上仍能保证可读性。
struct HotBadge: View {
    let value: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 9))
            Text(Theme.formatHot(value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

struct AnchorRow: View {
    let anchor: LiveAnchorItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: anchor.avatar)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(anchor.userName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(anchor.isLive ? "直播中" : "未开播")
                    .font(.caption)
                    .foregroundStyle(anchor.isLive ? Theme.accent : .secondary)
            }

            Spacer(minLength: 0)

            if anchor.isLive {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
            }
        }
        .contentShape(.rect)
    }
}

// MARK: - 状态视图

/// 统一的加载 / 失败 / 空态。失败一定给出可重试入口和真实错误文案。
struct PhaseStateView: View {
    let phase: LoadPhase
    let isEmpty: Bool
    var emptyText: String = "暂无内容"
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .loading where isEmpty:
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, minHeight: 220)
        case .failed(let message):
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试", action: retry)
                    .buttonStyle(.glassProminent)
            }
        case .loaded where isEmpty:
            ContentUnavailableView(emptyText, systemImage: "tray")
        default:
            EmptyView()
        }
    }
}
