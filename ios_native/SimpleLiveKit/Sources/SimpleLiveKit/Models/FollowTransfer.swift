import Foundation

/// Portable, versioned document. Contains follows and watch history only: never credentials/settings.
/// Version 1 carries follows only; version 2 adds `history`. Documents without history are still
/// written as version 1 so older installs can import them.
public struct FollowTransferDocument: Codable, Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumRooms = 2000
    public static let maximumHistory = 2000
    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let rooms: [FollowTransferRoom]
    private let history: [FollowTransferHistory]?

    public init(rooms: [FollowTransferRoom], history: [FollowTransferHistory] = [], exportedAt: Date = Date()) {
        self.format = "simple-live-follows"
        self.version = history.isEmpty ? 1 : 2
        self.exportedAt = exportedAt
        self.rooms = rooms
        self.history = history.isEmpty ? nil : history
    }

    public var historyRecords: [FollowTransferHistory] { history ?? [] }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw FollowTransferError("关注文件超过 2 MB 上限") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw FollowTransferError("关注文件超过 2 MB 上限") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: Self
        do { document = try decoder.decode(Self.self, from: data) }
        catch { throw FollowTransferError("这不是有效的 SwiftPeek 关注文件") }
        try document.validate()
        return document
    }

    private func validate() throws {
        guard format == "simple-live-follows", version == 1 || version == 2 else {
            throw FollowTransferError("不支持此关注文件版本，请更新 SwiftPeek 后重试")
        }
        guard version == 2 || history == nil else { throw FollowTransferError("关注文件格式无效") }
        guard rooms.count <= Self.maximumRooms else { throw FollowTransferError("单次最多导入 2,000 个关注") }
        guard historyRecords.count <= Self.maximumHistory else { throw FollowTransferError("单次最多导入 2,000 条观看历史") }
        for room in rooms {
            try Self.validate(site: room.site, roomID: room.roomID, userName: room.userName, title: room.title)
            guard Self.isValidImageURL(room.avatar) else { throw FollowTransferError("关注文件含有无效的头像地址") }
        }
        for record in historyRecords {
            try Self.validate(site: record.site, roomID: record.roomID, userName: record.userName, title: record.title)
            guard Self.isValidImageURL(record.cover) else { throw FollowTransferError("关注文件含有无效的封面地址") }
        }
    }

    private static func validate(site: String, roomID: String, userName: String, title: String) throws {
        guard site == "douyu" else { throw FollowTransferError("文件包含当前版本尚未支持的平台") }
        guard !roomID.isEmpty, roomID.count <= 64,
              roomID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              userName.count <= 160, title.count <= 512 else {
            throw FollowTransferError("关注文件含有无效的房间信息")
        }
    }

    private static func isValidImageURL(_ string: String) -> Bool {
        if string.isEmpty { return true }
        guard string.utf8.count <= 2048, let url = URL(string: string),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return url.host != nil && url.user == nil && url.password == nil
    }

    public func additions(existingIDs: Set<String>) -> [FollowTransferRoom] {
        var seen = existingIDs
        return rooms.filter { seen.insert($0.roomID).inserted }
    }

    /// History entries that are new to this device, or were watched more recently than the local
    /// record (keyed by roomID). One entry per room, newest first.
    public func historyUpdates(existing: [String: Date]) -> [FollowTransferHistory] {
        var newest: [String: FollowTransferHistory] = [:]
        for record in historyRecords where record.watchedAt > (existing[record.roomID] ?? .distantPast) {
            if let current = newest[record.roomID], current.watchedAt >= record.watchedAt { continue }
            newest[record.roomID] = record
        }
        return newest.values.sorted { $0.watchedAt > $1.watchedAt }
    }

    public var uniqueCount: Int { Set(rooms.map(\.roomID)).count }
}

public struct FollowTransferRoom: Codable, Sendable {
    public let site: String
    public let roomID: String
    public let userName: String
    public let title: String
    public let avatar: String
    public init(roomID: String, userName: String, title: String, avatar: String = "", site: String = "douyu") {
        self.site = site; self.roomID = roomID; self.userName = userName; self.title = title; self.avatar = avatar
    }
}

public struct FollowTransferHistory: Codable, Sendable {
    public let site: String
    public let roomID: String
    public let userName: String
    public let title: String
    public let cover: String
    public let watchedAt: Date
    public init(roomID: String, userName: String, title: String, cover: String = "", watchedAt: Date, site: String = "douyu") {
        self.site = site; self.roomID = roomID; self.userName = userName; self.title = title
        self.cover = cover; self.watchedAt = watchedAt
    }
}

public struct FollowTransferError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
