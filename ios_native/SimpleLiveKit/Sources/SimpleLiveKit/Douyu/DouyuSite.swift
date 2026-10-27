import Foundation
import CoreFoundation

/// 斗鱼取流载荷：签名查询串
public struct DouyuRoomPayload: LiveSitePayload {
    public let signArgs: String
    /// 拉取签名脚本时用的房间号。别名房和 `room_id` 可能不同，重签必须用这一份。
    public let signRoomID: String
    /// 签名里的 `tt` 是计算当时的时间戳，过期后 getH5Play 会拒绝。
    public let signedAt: Date

    public init(signArgs: String, signRoomID: String, signedAt: Date) {
        self.signArgs = signArgs
        self.signRoomID = signRoomID
        self.signedAt = signedAt
    }
}

/// 斗鱼清晰度载荷：码率 + 可用 CDN 列表
public struct DouyuQualityPayload: LiveSitePayload {
    public let rate: Int
    public let cdns: [String]

    public init(rate: Int, cdns: [String]) {
        self.rate = rate
        self.cdns = cdns
    }
}

/// 斗鱼直播站点适配器
public struct DouyuSite: LiveSite {
    public let id = "douyu"
    public let name = "斗鱼直播"

    private let http: HTTPClient
    /// 与 Dart 版一致的客户端版本号，getH5Play 会校验
    private static let clientVersion = "Douyu_223061205"
    /// 进房后紧接着的取清晰度、取流可以复用刚算好的签名。
    /// 再往后的切清晰度、断流重连必须重签，否则 `tt` 过期。
    private static let signReuseWindow: TimeInterval = 5

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func makeDanmakuClient(payload: (any LiveSitePayload)?) throws -> any LiveDanmakuClient {
        guard let payload = payload as? DouyuDanmakuPayload else {
            throw LiveCoreError("斗鱼弹幕载荷缺失")
        }
        return try DouyuDanmakuClient(roomID: payload.roomID)
    }

    // MARK: - 请求头

    private func roomHeaders(_ roomID: String) -> [String: String] {
        ["referer": "https://www.douyu.com/\(roomID)"]
    }

    private func searchHeaders() -> [String: String] {
        let did = Self.randomHexString(length: 32)
        return [
            "referer": "https://www.douyu.com/search/",
            "Cookie": "dy_did=\(did);acf_did=\(did)",
        ]
    }

    // MARK: - 分类

    public func categories() async throws -> [LiveCategory] {
        let result = try await http.getJSON("https://m.douyu.com/api/cate/list")
        let subCategories = result["data"]["cate2Info"].array

        var categories: [LiveCategory] = []
        for item in result["data"]["cate1Info"].array {
            let parentID = item["cate1Id"].stringValue
            let children = subCategories
                .filter { $0["cate1Id"].stringValue == parentID }
                .map {
                    LiveSubCategory(
                        id: $0["cate2Id"].stringValue,
                        name: $0["cate2Name"].stringValue,
                        parentID: parentID,
                        pic: $0["icon"].string
                    )
                }
            categories.append(
                LiveCategory(id: parentID, name: item["cate1Name"].stringValue, children: children)
            )
        }
        // 与 Dart 版一致：按数值 ID 升序
        return categories.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    public func categoryRooms(_ category: LiveSubCategory, page: Int = 1) async throws -> LiveCategoryResult {
        let result = try await http.getJSON(
            "https://www.douyu.com/gapi/rkc/directory/mixList/2_\(category.id)/\(page)"
        )
        return Self.parseRoomList(result, page: page)
    }

    public func recommendRooms(page: Int = 1) async throws -> LiveCategoryResult {
        let result = try await http.getJSON(
            "https://www.douyu.com/japi/weblist/apinc/allpage/6/\(page)"
        )
        return Self.parseRoomList(result, page: page)
    }

    /// `rl` 列表结构在推荐和分类接口中完全一致
    static func parseRoomList(_ result: JSON, page: Int) -> LiveCategoryResult {
        var items: [LiveRoomItem] = []
        for item in result["data"]["rl"].array where item["type"].intValue == 1 {
            items.append(
                LiveRoomItem(
                    roomID: item["rid"].stringValue,
                    title: Self.htmlUnescape(item["rn"].stringValue),
                    cover: item["rs16"].stringValue,
                    userName: item["nn"].stringValue,
                    online: item["ol"].intValue,
                    status: Self.parseListRoomStatus(item)
                )
            )
        }
        let pageCount = result["data"]["pgcnt"].intValue
        return LiveCategoryResult(hasMore: page < pageCount, items: items)
    }

    /// Douyu's list renderer defines rst as horizontal/vertical/voice/carousel.
    /// `type == 1` identifies a room card; `rt` is not its live/loop status.
    static func parseListRoomStatus(_ room: JSON) -> LiveRoomStatus {
        if let number = room["rst"].raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .unknown
        }
        switch room["rst"].string {
        case "0", "1", "2": return .live
        case "3": return .looping
        default: return .unknown
        }
    }

    // MARK: - 房间详情

    public func roomDetail(roomID: String) async throws -> LiveRoomDetail {
        let room = try await fetchRoomInfo(roomID)
        let state = try Self.parseRoomState(room)

        // 开播时间与签名脚本可以并发取，减少首屏等待
        async let showTimeTask = fetchShowTime(roomID)
        async let roomJSTask = fetchSignScript(roomID)
        let showTime = try? await showTimeTask
        let roomJS = try await roomJSTask

        // 签名要执行一整份 CryptoJS 和房间下发的混淆脚本，不能占着主线程。
        let signedAt = Date()
        let signArgs = try await Self.computeSign(
            roomJS: roomJS,
            roomID: roomID,
            timestamp: Int(signedAt.timeIntervalSince1970)
        )
        let isLoop = state.isRecord

        return LiveRoomDetail(
            roomID: room["room_id"].stringValue,
            title: Self.htmlUnescape(room["room_name"].stringValue),
            cover: room["room_pic"].stringValue,
            userName: room["owner_name"].stringValue,
            userAvatar: room["owner_avatar"].stringValue,
            online: room["room_biz_all"]["hot"].intValue,
            introduction: room["show_details"].string,
            notice: nil,
            isLiving: state.isLiving,
            payload: DouyuRoomPayload(signArgs: signArgs, signRoomID: roomID, signedAt: signedAt),
            danmakuPayload: DouyuDanmakuPayload(roomID: room["room_id"].stringValue),
            isRecord: isLoop,
            url: "https://www.douyu.com/\(roomID)",
            showTime: showTime
        )
    }

    public func liveStatus(roomID: String) async throws -> Bool {
        let room = try await fetchRoomInfo(roomID)
        return try Self.parseRoomState(room).isLiving
    }

    /// 只打一次 betard，不做签名、不查开播时间。
    /// 关注列表刷新 N 个房间时，比 roomDetail 少 2N 次请求和 N 次 JS 执行。
    public func roomBrief(roomID: String) async throws -> LiveRoomBrief {
        let room = try await fetchRoomInfo(roomID)
        let state = try Self.parseRoomState(room)
        let isLoop = state.isRecord
        return LiveRoomBrief(
            roomID: room["room_id"].string ?? roomID,
            title: Self.htmlUnescape(room["room_name"].stringValue),
            cover: room["room_pic"].stringValue,
            userName: room["owner_name"].stringValue,
            userAvatar: room["owner_avatar"].stringValue,
            online: room["room_biz_all"]["hot"].intValue,
            isLiving: state.isLiving,
            isRecord: isLoop
        )
    }

    /// Missing/unknown status is an API failure, never evidence of an offline room.
    static func parseRoomState(_ room: JSON) throws -> (isLiving: Bool, isRecord: Bool) {
        if let number = room["show_status"].raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw LiveCoreError("斗鱼开播状态暂时无法确认，请重试")
        }
        guard let status = room["show_status"].string, ["0", "1", "2"].contains(status) else {
            throw LiveCoreError("斗鱼开播状态暂时无法确认，请重试")
        }
        let loop = room["videoLoop"].string ?? "0"
        guard ["0", "1"].contains(loop) else {
            throw LiveCoreError("斗鱼轮播状态暂时无法确认，请重试")
        }
        return (status == "1" && loop != "1", loop == "1")
    }

    /// betard 偶发返回 text/plain，这里统一按文本取回再解析
    private func fetchRoomInfo(_ roomID: String) async throws -> JSON {
        let text = try await http.getText(
            "https://www.douyu.com/betard/\(roomID)",
            headers: roomHeaders(roomID)
        )
        guard let data = text.data(using: .utf8) else {
            throw LiveCoreError("斗鱼房间信息编码异常")
        }
        let json = try JSON(data: data)
        let room = json["room"]
        LiveDiagnostics.record("douyu.roomStatus", roomID: roomID, fields: [
            "roomPresent": String(room.exists),
            "canonicalRoom": room["room_id"].string ?? "missing",
            "showStatus": room["show_status"].string ?? "missing",
            "videoLoop": room["videoLoop"].string ?? "missing",
            "statusValid": String((try? Self.parseRoomState(room)) != nil),
        ])
        guard room.exists else {
            throw LiveCoreError("未找到斗鱼房间 \(roomID)")
        }
        return room
    }

    private func fetchShowTime(_ roomID: String) async throws -> String? {
        let result = try await http.getJSON(
            "https://www.douyu.com/swf_api/h5room/\(roomID)",
            headers: roomHeaders(roomID)
        )
        return result["data"]["show_time"].string
    }

    private func fetchSignScript(_ roomID: String) async throws -> String {
        let text = try await http.getText(
            "https://www.douyu.com/swf_api/homeH5Enc",
            query: ["rids": roomID],
            headers: roomHeaders(roomID)
        )
        guard let data = text.data(using: .utf8) else {
            throw LiveCoreError("斗鱼签名脚本编码异常")
        }
        let json = try JSON(data: data)
        guard let script = json["data"]["room\(roomID)"].string, !script.isEmpty else {
            throw LiveCoreError("斗鱼未下发签名脚本，房间号可能不存在")
        }
        return script
    }

    // MARK: - 取流

    public func playQualities(detail: LiveRoomDetail) async throws -> [LivePlayQuality] {
        guard let payload = detail.payload as? DouyuRoomPayload else {
            throw LiveCoreError("斗鱼房间载荷缺失，无法获取清晰度")
        }
        let signArgs = try await freshSignArgs(payload)
        let body = signArgs
            + "&cdn=&rate=-1&ver=\(Self.clientVersion)&iar=1&ive=1&hevc=0&fa=0"
        let result = try await http.postForm(
            "https://www.douyu.com/lapi/live/getH5Play/\(detail.roomID)",
            body: body,
            headers: roomHeaders(detail.roomID)
        )
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "斗鱼取流失败")
        }

        // scdn 线路稳定性较差，排到最后
        let cdns = result["data"]["cdnsWithName"].array
            .compactMap { $0["cdn"].string }
            .sorted { lhs, rhs in
                let lhsIsSecondary = lhs.hasPrefix("scdn")
                let rhsIsSecondary = rhs.hasPrefix("scdn")
                if lhsIsSecondary != rhsIsSecondary { return !lhsIsSecondary }
                return false
            }

        return result["data"]["multirates"].array.enumerated().map { index, item in
            LivePlayQuality(
                quality: item["name"].stringValue,
                payload: DouyuQualityPayload(rate: item["rate"].intValue, cdns: cdns),
                sort: index
            )
        }
    }

    public func playURL(detail: LiveRoomDetail, quality: LivePlayQuality) async throws -> LivePlayURL {
        guard let roomPayload = detail.payload as? DouyuRoomPayload,
              let qualityPayload = quality.payload as? DouyuQualityPayload
        else {
            throw LiveCoreError("斗鱼取流载荷缺失")
        }

        let signArgs = try await freshSignArgs(roomPayload)
        // 各 CDN 互不依赖。串行会把首帧推迟成「线路数 × 一次往返」。
        let indexed = await withTaskGroup(of: (Int, String, String?).self) { group in
            for (index, cdn) in qualityPayload.cdns.enumerated() {
                group.addTask {
                    do {
                        let url = try await self.fetchStreamURL(
                            roomID: detail.roomID,
                            signArgs: signArgs,
                            rate: qualityPayload.rate,
                            cdn: cdn
                        )
                        return (index, url, nil)
                    } catch {
                        return (index, "", error.localizedDescription)
                    }
                }
            }
            var collected: [(Int, String, String?)] = []
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var urls: [String] = []
        var lineIDs: [String] = []
        var lastError: String?
        for (index, url, failure) in indexed {
            if !url.isEmpty {
                urls.append(url)
                lineIDs.append(qualityPayload.cdns[index])
            } else if let failure {
                lastError = failure
            }
        }
        guard !urls.isEmpty else {
            throw LiveCoreError("未取到可用线路：\(lastError ?? "全部 CDN 返回空")")
        }
        return LivePlayURL(
            urls: urls,
            lineIDs: lineIDs,
            headers: [
                "User-Agent": HTTPClient.desktopUserAgent,
                "Referer": "https://www.douyu.com/\(detail.roomID)",
            ]
        )
    }

    /// 进房瞬间的签名直接复用；超过窗口就重新拉脚本并在后台线程执行。
    private func freshSignArgs(_ payload: DouyuRoomPayload) async throws -> String {
        LiveDiagnostics.record("douyu.signature", roomID: payload.signRoomID, fields: [
            "ageSeconds": String(Int(Date().timeIntervalSince(payload.signedAt))),
            "renew": String(Date().timeIntervalSince(payload.signedAt) >= Self.signReuseWindow),
        ])
        if Date().timeIntervalSince(payload.signedAt) < Self.signReuseWindow {
            return payload.signArgs
        }
        let roomJS = try await fetchSignScript(payload.signRoomID)
        return try await Self.computeSign(roomJS: roomJS, roomID: payload.signRoomID)
    }

    /// JavaScriptCore 会占住调用线程。从主 actor 进来时必须挪走，否则进房卡界面。
    private static func computeSign(roomJS: String, roomID: String, timestamp: Int? = nil) async throws -> String {
        let stamp = timestamp ?? Int(Date().timeIntervalSince1970)
        return try await Task.detached(priority: .userInitiated) {
            try DouyuSign.sign(roomJS: roomJS, roomID: roomID, timestamp: stamp)
        }.value
    }

    private func fetchStreamURL(
        roomID: String,
        signArgs: String,
        rate: Int,
        cdn: String
    ) async throws -> String {
        let body = signArgs + "&cdn=\(cdn)&rate=\(rate)"
        let result = try await http.postForm(
            "https://www.douyu.com/lapi/live/getH5Play/\(roomID)",
            body: body,
            headers: roomHeaders(roomID)
        )
        LiveDiagnostics.record("douyu.streamResponse", roomID: roomID, fields: [
            "cdn": cdn, "rate": String(rate),
            "error": result["error"].string ?? "missing",
            "message": result["msg"].string ?? "",
            "hasStream": String(!(result["data"]["rtmp_live"].string ?? "").isEmpty),
        ])
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "斗鱼取流失败")
        }
        guard let base = result["data"]["rtmp_url"].string,
              let live = result["data"]["rtmp_live"].string,
              !base.isEmpty, !live.isEmpty
        else {
            return ""
        }
        return base + "/" + Self.htmlUnescape(live)
    }

    // MARK: - 搜索

    public func searchRooms(_ keyword: String, page: Int = 1) async throws -> LiveSearchRoomResult {
        let result = try await http.getJSON(
            "https://www.douyu.com/japi/search/api/searchShow",
            query: ["kw": keyword, "page": "\(page)", "pageSize": "20"],
            headers: searchHeaders()
        )
        if result["error"].intValue != 0 {
            throw LiveCoreError(result["msg"].string ?? "斗鱼搜索失败")
        }
        let list = result["data"]["relateShow"].array
        let items = list.map {
            LiveRoomItem(
                roomID: $0["rid"].stringValue,
                title: Self.htmlUnescape($0["roomName"].stringValue),
                cover: $0["roomSrc"].stringValue,
                userName: $0["nickName"].stringValue,
                online: Self.parseHotNumber($0["hot"].stringValue)
            )
        }
        return LiveSearchRoomResult(hasMore: !list.isEmpty, items: items)
    }

    public func searchAnchors(_ keyword: String, page: Int = 1) async throws -> LiveSearchAnchorResult {
        let result = try await http.getJSON(
            "https://www.douyu.com/japi/search/api/searchUser",
            query: ["kw": keyword, "page": "\(page)", "pageSize": "20", "filterType": "1"],
            headers: searchHeaders()
        )
        let list = result["data"]["relateUser"].array
        let items = list.map { item -> LiveAnchorItem in
            let info = item["anchorInfo"]
            let isLive = info["isLive"].intValue == 1 && info["roomType"].intValue == 0
            return LiveAnchorItem(
                roomID: info["rid"].stringValue,
                avatar: info["avatar"].stringValue,
                userName: info["nickName"].stringValue,
                isLive: isLive
            )
        }
        return LiveSearchAnchorResult(hasMore: !list.isEmpty, items: items)
    }

    // MARK: - 工具

    /// 解析「12.3万」这类热度文本，无法解析时返回 -999（沿用 Dart 版约定）
    static func parseHotNumber(_ raw: String) -> Int {
        let trimmed = raw.replacingOccurrences(of: "万", with: "")
        guard let value = Double(trimmed) else { return -999 }
        return Int((raw.contains("万") ? value * 10_000 : value).rounded())
    }

    /// rtmp_live 中的 `&` 被转义为 `&amp;`，必须还原否则查询参数失效
    static func htmlUnescape(_ raw: String) -> String {
        var text = raw
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),  // 必须最后处理，避免二次解码
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }

    static func randomHexString(length: Int) -> String {
        let digits = "0123456789abcdef"
        return String((0..<length).map { _ in digits.randomElement()! })
    }
}
