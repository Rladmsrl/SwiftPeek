import SimpleLiveKit
import SwiftUI

struct MacRoomCard: View {
    let room: LiveRoomItem
    var showsStatus = true
    var watchedAt: Date?
    let open: () -> Void
    @State private var hovered = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                CoverImage(url: room.cover, cornerRadius: 0)
                    .overlay(alignment: .topLeading) {
                        if showsStatus, room.status != .unknown {
                            MacLiveBadge(title: room.status.label, live: room.status == .live).padding(12)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if settings.data.showHotBadge, room.online > 0 {
                            Label(Theme.formatHot(room.online), systemImage: "flame.fill")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.4), in: .capsule).padding(10)
                        }
                    }
                    .overlay {
                        if hovered {
                            Image(systemName: "play.fill").font(.system(size: 19, weight: .medium))
                                .foregroundStyle(.white).frame(width: 48, height: 48)
                                .glassEffect(.regular.tint(.black.opacity(0.15)), in: .circle)
                                .transition(.opacity)
                        }
                    }
                VStack(alignment: .leading, spacing: 10) {
                    Text(room.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle").font(.system(size: 12))
                        Text(room.userName).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let watchedAt {
                            Text(watchedAt, style: .relative).font(.system(size: 10)).lineLimit(1)
                        }
                    }.foregroundStyle(.secondary)
                }.padding(14)
            }.macSurface(radius: 16).clipShape(.rect(cornerRadius: 16)).macHover(radius: 16)
        }.buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
            .help("打开 \(room.userName) 的直播间")
    }
}

struct MacFeaturedRoom: View {
    let room: LiveRoomItem
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Rectangle().fill(Color.black)
                .frame(height: 248)
                .overlay {
                    AsyncImage(url: URL(string: room.cover)) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { LinearGradient(colors: [.indigo.opacity(0.6), MacDesign.accent.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                    }
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                           .init(color: .black.opacity(0.4), location: 0.52),
                                           .init(color: .black.opacity(0.05), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 8) {
                            if room.status != .unknown {
                                MacLiveBadge(title: room.status.label, live: room.status == .live)
                            }
                            Text("此刻，值得一看").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        }
                        Text(room.title).font(.system(size: 25, weight: .bold)).lineLimit(2)
                            .frame(maxWidth: 400, alignment: .leading)
                        Text(room.userName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: 9) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("进入直播间").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                            .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: .capsule)
                            .padding(.top, 3)
                    }.padding(28).foregroundStyle(.white)
                }
                .clipShape(.rect(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        }.buttonStyle(.plain).macHover(radius: 22)
    }
}

struct MacCategoryCard: View {
    let category: LiveSubCategory
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: category.pic ?? "")) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(5)
                    } else {
                        Image(systemName: "play.tv")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(MacDesign.accent)
                    }
                }
                .frame(width: 44, height: 44)
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))

                Text(category.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 14))
            .macSurface(radius: 14)
            .macHover(radius: 14)
        }.buttonStyle(.plain).help("浏览\(category.name)直播")
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
            if phase == .idle, rooms.isEmpty {
                MacEmptyState(symbol: "magnifyingglass", title: "下一场精彩，从这里开始", detail: "在右上方搜索你想看的主播或内容。")
            } else {
                PhaseStateView(phase: phase, isEmpty: rooms.isEmpty, emptyText: "暂无直播间", retry: retry)
            }
            LazyVGrid(columns: MacDesign.columns, spacing: 22) {
                ForEach(rooms) { room in
                    MacRoomCard(room: room) { open(room.roomID) }
                        .task { await loadMore?(room) }
                }
            }
        }
    }
}
