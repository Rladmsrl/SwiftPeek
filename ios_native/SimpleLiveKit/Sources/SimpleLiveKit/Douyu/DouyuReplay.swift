import Foundation

// MARK: - 录像模型

/// 一段录像。斗鱼把一场直播按约 2 小时切成多段，每段有独立的 hash_id。
public struct DouyuReplayVideo: Identifiable, Hashable, Sendable {
    public var id: String { hashID }
    public let hashID: String
    public let pointID: String
    public let title: String
    public let cover: String
    /// 列表接口只给「120:02」这类文本，解析失败时为 0
    public let duration: TimeInterval
    public let viewCount: Int
    public let recordedAt: Date?

    public init(hashID: String, pointID: String, title: String, cover: String,
                duration: TimeInterval, viewCount: Int, recordedAt: Date?) {
        self.hashID = hashID
        self.pointID = pointID
        self.title = title
        self.cover = cover
        self.duration = duration
        self.viewCount = viewCount
        self.recordedAt = recordedAt
    }
}

/// 一场直播（场次），包含若干段录像
public struct DouyuReplayShow: Identifiable, Hashable, Sendable {
    public var id: String { showID }
    public let showID: String
    public let title: String
    /// 「2026-10-16 12点场」
    public let sessionLabel: String
    /// 「昨天」「前天」或日期
    public let relativeDate: String
    /// 开播时刻「12:28」
    public let startClock: String
    /// 整场总时长「10:00:13」
    public let totalDuration: String
    /// 列表接口只带第一段，完整分段用 `DouyuReplayService.segments` 获取
    public let videos: [DouyuReplayVideo]
    /// 整场的分段数
    public let partCount: Int

    public init(showID: String, title: String, sessionLabel: String, relativeDate: String,
                startClock: String, totalDuration: String, videos: [DouyuReplayVideo], partCount: Int) {
        self.showID = showID
        self.title = title
        self.sessionLabel = sessionLabel
        self.relativeDate = relativeDate
        self.startClock = startClock
        self.totalDuration = totalDuration
        self.videos = videos
        self.partCount = max(partCount, videos.count)
    }
}

/// 录像作者（即主播）
public struct DouyuReplayAuthor: Hashable, Sendable {
    public let upID: String
    public let roomID: String
    public let name: String
    public let avatar: String
}

public struct DouyuReplayPage: Sendable {
    public let shows: [DouyuReplayShow]
    public let hasMore: Bool
}

/// 录像页内嵌的完整信息
public struct DouyuReplayDetail: Hashable, Sendable {
    public let hashID: String
    public let pointID: String
    public let title: String
    public let cover: String
    public let duration: TimeInterval
    public let authorName: String
    public let authorAvatar: String
    public let upID: String
    public let roomID: String
    public let viewCount: Int
    public let danmakuCount: Int
    public let recordedAt: Date?
    public let categoryName: String
    public let showID: String
}

/// 录像清晰度。地址带签名，约 2 小时后失效，需要重新获取。
public struct DouyuReplayQuality: Identifiable, Hashable, Sendable {
    public var id: String { key }
    /// 斗鱼内部名：normal / high / 1080p60 / 1440p60a …
    public let key: String
    public let name: String
    public let url: String
    public let bitRate: Int

    public init(key: String, name: String, url: String, bitRate: Int) {
        self.key = key
        self.name = name
        self.url = url
        self.bitRate = bitRate
    }
}

/// 一次打开录像需要的全部数据：信息与取流只需抓一次页面
public struct DouyuReplaySource: Sendable {
    public let detail: DouyuReplayDetail
    public let qualities: [DouyuReplayQuality]
}

/// 录像弹幕：与直播弹幕相同的内容，多了相对录像开头的时间轴
public struct DouyuReplayDanmaku: Identifiable, Hashable, Sendable {
    public let id: String
    /// 相对录像开头的秒数
    public let offset: TimeInterval
    public let userName: String
    public let text: String
    public let color: LiveMessageColor

    public init(id: String, offset: TimeInterval, userName: String, text: String, color: LiveMessageColor = .white) {
        self.id = id
        self.offset = offset
        self.userName = userName
        self.text = text
        self.color = color
    }
}

public struct DouyuReplayDanmakuBatch: Sendable {
    public let items: [DouyuReplayDanmaku]
    /// 下一窗口的起点（毫秒）。nil 表示已到录像末尾。
    public let nextStart: Int?

    public init(items: [DouyuReplayDanmaku], nextStart: Int?) {
        self.items = items
        self.nextStart = nextStart
    }
}

/// AI 生成的章节。一个章节可能从上一段录像延续过来。
public struct DouyuReplayChapter: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let tag: String
    /// 在当前这段录像中的起点（秒）
    public let start: TimeInterval
    /// 是否从上一段录像延续过来
    public let isContinued: Bool
}

// MARK: - 服务

/// 斗鱼录像（v.douyu.com）接口。
///
/// 全部接口无需登录。取流签名与直播相同（`ub98484234`），
/// 区别是签名脚本内联在录像页面里、签名对象是录像的 `point_id`。
public struct DouyuReplayService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    private func headers(_ hashID: String? = nil) -> [String: String] {
        ["referer": hashID.map { "https://v.douyu.com/show/\($0)" } ?? "https://v.douyu.com/"]
    }

    // MARK: 列表

    /// 直播间号 → 主播的录像作者信息
    public func author(roomID: String) async throws -> DouyuReplayAuthor {
        let text = try await http.getText(
            "https://www.douyu.com/betard/\(roomID)",
            headers: ["referer": "https://www.douyu.com/\(roomID)"]
        )
        let json = try JSON(data: Data(text.utf8))
        return try Self.parseAuthor(json["room"], roomID: roomID)
    }

    static func parseAuthor(_ room: JSON, roomID: String) throws -> DouyuReplayAuthor {
        guard let upID = room["up_id"].string, !upID.isEmpty else {
            throw LiveCoreError("这个直播间没有公开录像")
        }
        return DouyuReplayAuthor(
            upID: upID,
            roomID: room["room_id"].string ?? roomID,
            name: room["owner_name"].stringValue,
            avatar: room["owner_avatar"].stringValue
        )
    }

    public func replays(upID: String, page: Int, pageSize: Int = 10) async throws -> DouyuReplayPage {
        let result = try await http.getJSON(
            "https://v.douyu.com/wgapi/vod/center/authorShowVideoList",
            query: ["up_id": upID, "page": "\(page)", "limit": "\(pageSize)"],
            headers: headers()
        )
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "获取录像列表失败")
        }
        return Self.parseReplayPage(result["data"], page: page, pageSize: pageSize)
    }

    static func parseReplayPage(_ data: JSON, page: Int, pageSize: Int) -> DouyuReplayPage {
        let list = data["list"].array
        let shows = list.compactMap { show -> DouyuReplayShow? in
            let videos = show["video_list"].array.compactMap { video -> DouyuReplayVideo? in
                guard let hashID = video["hash_id"].string, isValidHashID(hashID) else { return nil }
                let start = video["start_time"].intValue
                let exact = TimeInterval(video["video_duration"].intValue)
                return DouyuReplayVideo(
                    hashID: hashID,
                    pointID: video["point_id"].stringValue,
                    title: video["title"].stringValue,
                    cover: video["video_pic"].stringValue,
                    duration: exact > 0 ? exact : parseClock(video["video_str_duration"].stringValue),
                    viewCount: video["view_num"].intValue,
                    recordedAt: start > 0 ? Date(timeIntervalSince1970: TimeInterval(start)) : nil
                )
            }
            guard !videos.isEmpty else { return nil }
            return DouyuReplayShow(
                showID: show["show_id"].stringValue,
                title: show["title"].stringValue,
                sessionLabel: show["time"].stringValue,
                relativeDate: show["date_format"].stringValue,
                startClock: show["time_format"].stringValue,
                totalDuration: show["replay_duration"].stringValue,
                videos: videos,
                partCount: show["re_num"].intValue
            )
        }
        let total = data["count"].intValue
        let hasMore = total > 0 ? page * pageSize < total : list.count >= pageSize
        return DouyuReplayPage(shows: shows, hasMore: hasMore && !list.isEmpty)
    }

    /// 同一场直播的全部分段，按时间顺序
    public func segments(hashID: String, upID: String) async throws -> [DouyuReplayVideo] {
        let result = try await http.getJSON(
            "https://v.douyu.com/wgapi/vod/center/getShowReplayList",
            query: ["vid": hashID, "up_id": upID],
            headers: headers(hashID)
        )
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "获取分段失败")
        }
        return Self.parseSegments(result["data"])
    }

    static func parseSegments(_ data: JSON) -> [DouyuReplayVideo] {
        data["list"].array.compactMap { item -> (Int, DouyuReplayVideo)? in
            guard let hashID = item["hash_id"].string, isValidHashID(hashID) else { return nil }
            let remark = item["show_remark"].stringValue
            return (item["rank"].intValue, DouyuReplayVideo(
                hashID: hashID,
                pointID: item["vid"].stringValue,
                title: remark.isEmpty ? item["title"].stringValue : remark,
                cover: item["cover"].stringValue,
                duration: parseClock(item["video_duration"].stringValue),
                viewCount: item["view_num"].intValue,
                recordedAt: nil
            ))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    // MARK: 信息与取流

    /// 抓一次录像页，同时得到录像信息和各清晰度地址
    public func source(hashID: String) async throws -> DouyuReplaySource {
        let html = try await page(hashID)
        let detail = try Self.parseDetail(html: html)
        let qualities = try await qualities(hashID: hashID, pointID: detail.pointID, html: html)
        return DouyuReplaySource(detail: detail, qualities: qualities)
    }

    /// 地址过期后重新取流。签名脚本的版本号按天变化，必须重新抓页面。
    public func qualities(hashID: String, pointID: String) async throws -> [DouyuReplayQuality] {
        let html = try await page(hashID)
        return try await qualities(hashID: hashID, pointID: pointID, html: html)
    }

    private func page(_ hashID: String) async throws -> String {
        guard Self.isValidHashID(hashID) else { throw LiveCoreError("录像编号非法") }
        return try await http.getText("https://v.douyu.com/show/\(hashID)", headers: headers())
    }

    private func qualities(hashID: String, pointID: String, html: String) async throws -> [DouyuReplayQuality] {
        guard let script = Self.extractSignScript(html: html) else {
            throw LiveCoreError("录像页未包含签名脚本，接口可能已变更")
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let signArgs = try await Task.detached(priority: .userInitiated) {
            try DouyuSign.sign(roomJS: script, roomID: pointID, timestamp: stamp)
        }.value
        let result = try await http.postForm(
            "https://v.douyu.com/wgapi/vodnc/front/stream/getStreamUrlWeb",
            body: signArgs + "&vid=\(hashID)",
            headers: headers(hashID)
        )
        LiveDiagnostics.record("replay.streamResponse", fields: [
            "error": result["error"].string ?? "missing",
            "message": result["msg"].string ?? "",
        ])
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "获取录像地址失败")
        }
        let qualities = Self.parseQualities(result["data"])
        guard !qualities.isEmpty else { throw LiveCoreError("这段录像暂时没有可播放的地址") }
        return qualities
    }

    static func parseQualities(_ data: JSON) -> [DouyuReplayQuality] {
        data["thumb_video"].dictionary.compactMap { key, item -> DouyuReplayQuality? in
            guard let url = item["url"].string, url.hasPrefix("http") else { return nil }
            return DouyuReplayQuality(key: key, name: qualityName(key), url: url, bitRate: item["bit_rate"].intValue)
        }
        .sorted { $0.bitRate > $1.bitRate }
    }

    static func qualityName(_ key: String) -> String {
        switch key.lowercased() {
        case "normal": return "高清"
        case "high": return "超清"
        case "super": return "蓝光"
        default:
            // 1080p60 / 1440p60a / 2k60 → 1080P60 / 1440P60 / 2K60
            var name = key.uppercased()
            if name.last == "A", name.dropLast().last?.isNumber == true { name.removeLast() }
            return name
        }
    }

    // MARK: 弹幕

    /// 按时间窗口取弹幕。每次最多 500 条，用返回的 `nextStart` 接着取。
    public func danmaku(hashID: String, from milliseconds: Int) async throws -> DouyuReplayDanmakuBatch {
        let result = try await http.getJSON(
            "https://v.douyu.com/wgapi/vod/center/getBarrageList",
            query: ["vid": hashID, "start_time": "\(max(0, milliseconds))", "end_time": "-1"],
            headers: headers(hashID)
        )
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "获取录像弹幕失败")
        }
        return Self.parseDanmaku(result["data"], requestedStart: milliseconds)
    }

    static func parseDanmaku(_ data: JSON, requestedStart: Int) -> DouyuReplayDanmakuBatch {
        let items = data["list"].array.compactMap { item -> DouyuReplayDanmaku? in
            let text = item["ctt"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let tl = item["tl"].int else { return nil }
            let id = item["mid"].string ?? "\(tl)-\(item["uid"].stringValue)-\(text.hashValue)"
            return DouyuReplayDanmaku(
                id: id,
                offset: TimeInterval(tl) / 1000,
                userName: item["nn"].stringValue,
                text: text,
                color: DouyuDanmakuClient.color(for: item["col"].intValue)
            )
        }
        .sorted { $0.offset < $1.offset }
        // end_time 为 -1 或不前进时说明已到末尾，避免死循环
        let end = data["end_time"].int ?? -1
        let next = items.isEmpty || end < 0 || end <= requestedStart ? nil : end
        return DouyuReplayDanmakuBatch(items: items, nextStart: next)
    }

    // MARK: 章节

    public func chapters(hashID: String) async throws -> [DouyuReplayChapter] {
        let result = try await http.getJSON(
            "https://v.douyu.com/wgapi/vod/center/aivideo/mainV1",
            query: ["vid": hashID],
            headers: headers(hashID)
        )
        guard result["error"].intValue == 0 else { return [] }
        return Self.parseChapters(result["data"], hashID: hashID)
    }

    /// 章节按整场直播编排，跨越多段录像。只保留与当前这段有交集的部分。
    static func parseChapters(_ data: JSON, hashID: String) -> [DouyuReplayChapter] {
        var chapters: [DouyuReplayChapter] = []
        for group in data.array {
            let tag = group["mainTag"].stringValue
            for item in group["list"].array {
                let title = item["firstTitle"].stringValue
                guard !title.isEmpty else { continue }
                let startsHere = item["startVidHash"].string == hashID
                let endsHere = item["endVidHash"].string == hashID
                guard startsHere || endsHere else { continue }
                if !startsHere, item["endSecond"].intValue <= 0 { continue }
                chapters.append(DouyuReplayChapter(
                    id: item["firstId"].string ?? "\(hashID)-\(chapters.count)",
                    title: title,
                    summary: item["describe"].stringValue,
                    tag: tag,
                    start: startsHere ? TimeInterval(item["startSecond"].intValue) : 0,
                    isContinued: !startsHere
                ))
            }
        }
        var seen = Set<String>()
        return chapters
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
    }

    // MARK: 页面解析

    static func parseDetail(html: String) throws -> DouyuReplayDetail {
        guard let marker = html.range(of: "window.$DATA") else {
            throw LiveCoreError("录像页结构已变化，无法解析")
        }
        let tail = html[marker.upperBound...]
        guard let roomText = extractObject(in: tail, after: "ROOM:"),
              let room = try? JSON(data: Data(roomText.utf8)), room.exists
        else {
            throw LiveCoreError("录像不存在或已被删除")
        }
        let content = extractObject(in: tail, after: "content:")
            .flatMap { try? JSON(data: Data($0.utf8)) } ?? .null

        let hashID = room["vid"].stringValue
        let pointID = room["point_id"].stringValue
        guard isValidHashID(hashID), !pointID.isEmpty else {
            throw LiveCoreError("录像信息不完整")
        }
        let start = content["start_time"].int ?? content["create_time"].intValue
        var avatar = content["authorIcon"].stringValue
        if avatar.hasPrefix("//") { avatar = "https:" + avatar }
        let duration = room["duration"].raw as? NSNumber
        return DouyuReplayDetail(
            hashID: hashID,
            pointID: pointID,
            title: room["name"].string ?? content["title"].stringValue,
            cover: room["pic"].string ?? content["video_pic"].stringValue,
            duration: duration?.doubleValue ?? (content["video_duration"].raw as? NSNumber)?.doubleValue ?? 0,
            authorName: room["author_name"].string ?? content["author"].stringValue,
            authorAvatar: avatar,
            upID: room["up_id"].string ?? content["up_id"].stringValue,
            roomID: content["room_id"].stringValue,
            viewCount: content["view_num"].intValue,
            danmakuCount: content["danmu_num"].intValue,
            recordedAt: start > 0 ? Date(timeIntervalSince1970: TimeInterval(start)) : nil,
            categoryName: content["cate2_name"].stringValue,
            showID: content["show_id"].stringValue
        )
    }

    /// 签名脚本以内联 `<script>` 下发，与直播 homeH5Enc 返回的脚本同构
    static func extractSignScript(html: String) -> String? {
        var searchStart = html.startIndex
        while let open = html.range(of: "<script", range: searchStart..<html.endIndex),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: openEnd.upperBound..<html.endIndex) {
            let body = html[openEnd.upperBound..<close.lowerBound]
            if body.contains("ub98484234") { return String(body) }
            searchStart = close.upperBound
        }
        return nil
    }

    /// 从 marker 之后的第一个 `{` 开始，按括号配对截出一个完整 JSON 对象。
    /// `$DATA` 外层是 JS 字面量（键不带引号），只有内层对象是合法 JSON。
    static func extractObject(in text: Substring, after marker: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: 链接

    /// 识别 `https://v.douyu.com/show/<hash>`（含移动版 vmobile）。
    /// 返回录像编号与链接里的起播秒数 `t`。
    public static func parseLink(_ raw: String) -> (hashID: String, start: TimeInterval?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(),
              ["v.douyu.com", "vmobile.douyu.com"].contains(host)
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "show", isValidHashID(parts[1]) else { return nil }
        let start = components.queryItems?.first { $0.name == "t" }?.value.flatMap(TimeInterval.init)
        return (parts[1], start.flatMap { $0 > 0 ? $0 : nil })
    }

    static func isValidHashID(_ value: String) -> Bool {
        (8...40).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 「120:02」「1:02:03」→ 秒
    static func parseClock(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ":").count else { return 0 }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }
}
