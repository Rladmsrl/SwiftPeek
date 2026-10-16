import Foundation

/// Portable, versioned document. Contains follows only: never credentials/history/settings.
public struct FollowTransferDocument: Codable, Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumRooms = 2000
    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let rooms: [FollowTransferRoom]

    public init(rooms: [FollowTransferRoom], exportedAt: Date = Date()) {
        self.format = "simple-live-follows"
        self.version = 1
        self.exportedAt = exportedAt
        self.rooms = rooms
    }

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
        guard format == "simple-live-follows", version == 1 else {
            throw FollowTransferError("不支持此关注文件版本，请更新 SwiftPeek 后重试")
        }
        guard rooms.count <= Self.maximumRooms else { throw FollowTransferError("单次最多导入 2,000 个关注") }
        for room in rooms {
            guard room.site == "douyu" else { throw FollowTransferError("文件包含当前版本尚未支持的平台") }
            guard !room.roomID.isEmpty, room.roomID.count <= 64,
                  room.roomID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  room.userName.count <= 160, room.title.count <= 512, room.avatar.utf8.count <= 2048 else {
                throw FollowTransferError("关注文件含有无效的房间信息")
            }
            if !room.avatar.isEmpty {
                guard let url = URL(string: room.avatar), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else {
                    throw FollowTransferError("关注文件含有无效的头像地址")
                }
            }
        }
    }

    public func additions(existingIDs: Set<String>) -> [FollowTransferRoom] {
        var seen = existingIDs
        return rooms.filter { seen.insert($0.roomID).inserted }
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

public struct FollowTransferError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
