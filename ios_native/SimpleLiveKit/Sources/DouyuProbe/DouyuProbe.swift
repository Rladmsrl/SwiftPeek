import Foundation
import SimpleLiveKit

/// 斗鱼核心库联调探针，对应原项目的 simple_live_console。
/// 用法：douyu-probe [房间号]
///      douyu-probe replay <房间号|录像链接>
@main
struct DouyuProbe {
    static func main() async {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "replay" {
            await probeReplay(CommandLine.arguments[2])
            return
        }
        let roomID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "9999"
        let site = DouyuSite()

        print("═══ SimpleLiveKit 斗鱼联调 ═══")
        print("站点：\(site.name)（\(site.id)）  房间：\(roomID)\n")

        do {
            // 1. 分类
            let categories = try await site.categories()
            let subCount = categories.reduce(0) { $0 + $1.children.count }
            print("[1] 分类     一级 \(categories.count) 个，二级 \(subCount) 个")
            if let first = categories.first {
                print("             示例：\(first.name) → \(first.children.prefix(3).map(\.name).joined(separator: "、"))")
            }

            // 2. 推荐
            let recommend = try await site.recommendRooms(page: 1)
            print("[2] 推荐     \(recommend.items.count) 个房间，hasMore=\(recommend.hasMore)")
            if let first = recommend.items.first {
                print("             示例：[\(first.roomID)] \(first.userName) · \(first.title) · 热度 \(first.online)")
            }

            // 3. 分类下房间
            if let sub = categories.first?.children.first {
                let rooms = try await site.categoryRooms(sub, page: 1)
                print("[3] 分类房间 \(sub.name) → \(rooms.items.count) 个")
            }

            // 4. 搜索
            let search = try await site.searchRooms("英雄联盟", page: 1)
            print("[4] 搜索     \(search.items.count) 个结果")
            if let first = search.items.first {
                print("             示例：[\(first.roomID)] \(first.userName) · 热度 \(first.online)")
            }

            // 5. 房间详情（含 JavaScriptCore 签名）
            let detail = try await site.roomDetail(roomID: roomID)
            print("[5] 房间详情 \(detail.userName) · \(detail.title)")
            print("             直播中=\(detail.isLiving) 轮播=\(detail.isRecord) 热度=\(detail.online)")
            if let duration = detail.liveDuration {
                print("             已开播 \(format(duration))")
            }
            if let payload = detail.payload as? DouyuRoomPayload {
                print("             签名 OK：\(payload.signArgs.prefix(72))…")
            }

            guard detail.isLiving else {
                print("\n房间未在直播，跳过取流与弹幕。")
                return
            }

            // 6. 清晰度
            let qualities = try await site.playQualities(detail: detail)
            print("[6] 清晰度   \(qualities.map(\.quality).joined(separator: " / "))")
            if let payload = qualities.first?.payload as? DouyuQualityPayload {
                print("             CDN：\(payload.cdns.joined(separator: ", "))")
            }

            // 7. 播放地址
            guard let best = qualities.first else {
                print("无可用清晰度")
                return
            }
            let playURL = try await site.playURL(detail: detail, quality: best)
            print("[7] 播放地址 \(best.quality) 共 \(playURL.urls.count) 条线路")
            for (index, url) in playURL.urls.enumerated() {
                let container = url.contains(".flv") ? "FLV" : (url.contains(".m3u8") ? "HLS" : "未知")
                print("             线路\(index + 1) [\(container)] \(url.prefix(96))…")
            }

            // 8. 弹幕（实时抓 12 秒）
            print("[8] 弹幕     连接中，采集 12 秒…")
            let danmaku = try site.makeDanmakuClient(payload: detail.danmakuPayload)
            let collector = Task {
                var count = 0
                for await event in danmaku.events {
                    switch event {
                    case .ready:
                        print("             ✓ 已加入房间")
                    case .message(let message):
                        count += 1
                        if count <= 8 {
                            print("             \(message.color) \(message.userName)：\(message.message)")
                        }
                    case .notice(let text):
                        print("             ! \(text)")
                    case .closed(let reason):
                        print("             × 连接关闭：\(reason)")
                        return count
                    }
                }
                return count
            }
            await danmaku.start()
            try? await Task.sleep(for: .seconds(12))
            await danmaku.stop()
            let total = await collector.value
            print("             共收到 \(total) 条弹幕")

            print("\n═══ 全部通过 ═══")
        } catch {
            print("\n✗ 失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    /// 录像链路：列表 → 信息与取流 → 弹幕窗口 → 章节。只打印地址前缀，不输出完整签名地址。
    static func probeReplay(_ target: String) async {
        let service = DouyuReplayService()
        print("═══ 斗鱼录像联调 ═══")
        do {
            var hashID = DouyuReplayService.parseLink(target)?.hashID
            if hashID == nil {
                let author = try await service.author(roomID: target)
                let page = try await service.replays(upID: author.upID, page: 1)
                print("[0] 主播     \(author.name)（\(author.upID)）")
                print("[1] 录像列表 \(page.shows.count) 场，hasMore=\(page.hasMore)")
                for show in page.shows.prefix(3) {
                    print("             \(show.sessionLabel)（\(show.relativeDate)）\(show.videos.count) 段 · \(show.totalDuration)")
                }
                hashID = page.shows.first?.videos.last?.hashID
            }
            guard let hashID else { print("没有录像"); return }
            let source = try await service.source(hashID: hashID)
            let detail = source.detail
            print("[2] 录像信息 \(detail.authorName) · \(detail.title)")
            print("             时长 \(Int(detail.duration))s 播放 \(detail.viewCount) 弹幕 \(detail.danmakuCount) 房间 \(detail.roomID)")
            for quality in source.qualities {
                print("             \(quality.name)（\(quality.key)）\(quality.bitRate / 1000)kbps \(quality.url.prefix(48))…")
            }
            var start = 0
            var total = 0
            var windows = 0
            while windows < 3 {
                let batch = try await service.danmaku(hashID: hashID, from: start)
                windows += 1
                total += batch.items.count
                if windows == 1 {
                    for item in batch.items.prefix(3) {
                        print("             [\(Int(item.offset))s] \(item.userName)：\(item.text)")
                    }
                }
                guard let next = batch.nextStart else { break }
                start = next
            }
            print("[3] 弹幕     \(windows) 个窗口共 \(total) 条，读到 \(start / 1000)s")
            let chapters = try await service.chapters(hashID: hashID)
            print("[4] 章节     \(chapters.count) 个")
            for chapter in chapters.prefix(5) {
                print("             \(Int(chapter.start))s \(chapter.isContinued ? "(续) " : "")\(chapter.title)")
            }
            print("\n═══ 录像链路通过 ═══")
        } catch {
            print("\n✗ 失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    static func format(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

extension LiveMessageColor: CustomStringConvertible {
    public var description: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }
}
