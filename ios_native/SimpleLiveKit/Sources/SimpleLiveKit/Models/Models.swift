import Foundation

// MARK: - 站点私有载荷
//
// Dart 版用 `dynamic` 承载各站点私有数据（签名串、清晰度 rate、CDN 列表等）。
// Swift 侧改为协议约束的存在类型，既保留扩展性，又避免 Any 到处蔓延。

public protocol LiveSitePayload: Sendable {}

// MARK: - 分类

public struct LiveCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let children: [LiveSubCategory]

    public init(id: String, name: String, children: [LiveSubCategory]) {
        self.id = id
        self.name = name
        self.children = children
    }
}

public struct LiveSubCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let parentID: String
    public let pic: String?

    public init(id: String, name: String, parentID: String, pic: String? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.pic = pic
    }
}

// MARK: - 房间

/// Status supplied by a room listing; absence of evidence must not imply live.
public enum LiveRoomStatus: Hashable, Sendable {
    case unknown, live, looping
}

public struct LiveRoomItem: Identifiable, Hashable, Sendable {
    public var id: String { roomID }
    public let roomID: String
    public let title: String
    public let cover: String
    public let userName: String
    public let online: Int
    public let status: LiveRoomStatus

    public init(roomID: String, title: String, cover: String, userName: String, online: Int = 0,
                status: LiveRoomStatus = .unknown) {
        self.roomID = roomID
        self.title = title
        self.cover = cover
        self.userName = userName
        self.online = online
        self.status = status
    }
}

public struct LiveAnchorItem: Identifiable, Hashable, Sendable {
    public var id: String { roomID }
    public let roomID: String
    public let avatar: String
    public let userName: String
    public let isLive: Bool

    public init(roomID: String, avatar: String, userName: String, isLive: Bool) {
        self.roomID = roomID
        self.avatar = avatar
        self.userName = userName
        self.isLive = isLive
    }
}

public struct LiveRoomDetail: Sendable {
    public let roomID: String
    public let title: String
    public let cover: String
    public let userName: String
    public let userAvatar: String
    public let online: Int
    public let introduction: String?
    public let notice: String?
    /// 是否正在直播（已排除轮播）
    public let isLiving: Bool
    /// 取流所需的站点私有载荷
    public let payload: (any LiveSitePayload)?
    /// 弹幕连接所需的站点私有载荷
    public let danmakuPayload: (any LiveSitePayload)?
    public let isRecord: Bool
    public let url: String
    /// 开播时间戳（秒），斗鱼由 swf_api/h5room 提供
    public let showTime: String?

    public init(
        roomID: String,
        title: String,
        cover: String,
        userName: String,
        userAvatar: String,
        online: Int,
        introduction: String? = nil,
        notice: String? = nil,
        isLiving: Bool,
        payload: (any LiveSitePayload)? = nil,
        danmakuPayload: (any LiveSitePayload)? = nil,
        isRecord: Bool = false,
        url: String,
        showTime: String? = nil
    ) {
        self.roomID = roomID
        self.title = title
        self.cover = cover
        self.userName = userName
        self.userAvatar = userAvatar
        self.online = online
        self.introduction = introduction
        self.notice = notice
        self.isLiving = isLiving
        self.payload = payload
        self.danmakuPayload = danmakuPayload
        self.isRecord = isRecord
        self.url = url
        self.showTime = showTime
    }

    /// 已开播时长，showTime 缺失或非法时返回 nil
    public var liveDuration: Duration? {
        guard let showTime, let start = Int(showTime), start > 0 else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        guard now > start else { return nil }
        return .seconds(now - start)
    }
}

// MARK: - 播放

/// 轻量房间概览。
///
/// 只承载展示所需字段，不含取流签名与开播时间，
/// 因此实现方可以只打一次房间信息接口就返回，
/// 适合关注列表这类需要批量、低延迟刷新的场景。
public struct LiveRoomBrief: Identifiable, Hashable, Sendable {
    public var id: String { roomID }
    public let roomID: String
    public let title: String
    public let cover: String
    public let userName: String
    public let userAvatar: String
    public let online: Int
    public let isLiving: Bool
    public let isRecord: Bool

    public init(
        roomID: String,
        title: String,
        cover: String,
        userName: String,
        userAvatar: String,
        online: Int,
        isLiving: Bool,
        isRecord: Bool
    ) {
        self.roomID = roomID
        self.title = title
        self.cover = cover
        self.userName = userName
        self.userAvatar = userAvatar
        self.online = online
        self.isLiving = isLiving
        self.isRecord = isRecord
    }
}

public struct LivePlayQuality: Identifiable, Sendable {
    public var id: String { quality }
    public let quality: String
    public let payload: any LiveSitePayload
    public let sort: Int

    public init(quality: String, payload: any LiveSitePayload, sort: Int = 0) {
        self.quality = quality
        self.payload = payload
        self.sort = sort
    }
}

public struct LivePlayURL: Sendable {
    /// 同一清晰度下的多条线路，按优先级排序
    public let urls: [String]
    /// Stable CDN identities parallel to urls. Signed URLs and hostnames may change.
    public let lineIDs: [String]
    public let headers: [String: String]?

    public init(urls: [String], lineIDs: [String] = [], headers: [String: String]? = nil) {
        self.urls = urls
        self.lineIDs = lineIDs
        self.headers = headers
    }

    public func lineID(at index: Int) -> String? {
        guard lineIDs.indices.contains(index), !lineIDs[index].isEmpty else { return nil }
        return lineIDs[index]
    }

    public func index(forLineID id: String?) -> Int {
        guard let id, let index = lineIDs.firstIndex(of: id), urls.indices.contains(index) else { return 0 }
        return index
    }
}

// MARK: - 消息

public enum LiveMessageKind: Sendable {
    case chat
    case gift
    case online
    case superChat
}

public struct LiveMessageColor: Hashable, Sendable {
    public let r: Int, g: Int, b: Int

    public init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = LiveMessageColor(255, 255, 255)

    /// 与 Dart 版 numberToColor 等价：兼容 4/6/8 位十六进制
    public static func fromNumber(_ value: Int) -> LiveMessageColor {
        var hex = String(value, radix: 16)
        if hex.count == 4 { hex = "00" + hex }
        func byte(_ start: Int) -> Int {
            let chars = Array(hex)
            guard start + 1 < chars.count else { return 255 }
            return Int(String(chars[start...(start + 1)]), radix: 16) ?? 255
        }
        switch hex.count {
        case 6: return LiveMessageColor(byte(0), byte(2), byte(4))
        case 8: return LiveMessageColor(byte(2), byte(4), byte(6))
        default: return .white
        }
    }
}

public struct LiveMessage: Identifiable, Sendable {
    public let id = UUID()
    public let kind: LiveMessageKind
    public let userName: String
    public let message: String
    /// kind == .online 时为人气值
    public let intValue: Int?
    public let color: LiveMessageColor

    public init(
        kind: LiveMessageKind,
        userName: String,
        message: String,
        intValue: Int? = nil,
        color: LiveMessageColor = .white
    ) {
        self.kind = kind
        self.userName = userName
        self.message = message
        self.intValue = intValue
        self.color = color
    }
}

// MARK: - 分页结果

public struct LiveCategoryResult: Sendable {
    public let hasMore: Bool
    public let items: [LiveRoomItem]

    public init(hasMore: Bool, items: [LiveRoomItem]) {
        self.hasMore = hasMore
        self.items = items
    }
}

public struct LiveSearchRoomResult: Sendable {
    public let hasMore: Bool
    public let items: [LiveRoomItem]

    public init(hasMore: Bool, items: [LiveRoomItem]) {
        self.hasMore = hasMore
        self.items = items
    }
}

public struct LiveSearchAnchorResult: Sendable {
    public let hasMore: Bool
    public let items: [LiveAnchorItem]

    public init(hasMore: Bool, items: [LiveAnchorItem]) {
        self.hasMore = hasMore
        self.items = items
    }
}
