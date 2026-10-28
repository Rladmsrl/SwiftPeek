import Foundation
import Observation
import SimpleLiveKit

// MARK: - 数据模型

struct FollowedRoom: Codable, Identifiable, Hashable {
    var roomID: String
    var userName: String
    var avatar: String
    var title: String
    var addedAt: Date

    var id: String { roomID }
}

struct HistoryRecord: Codable, Identifiable, Hashable {
    var roomID: String
    var userName: String
    var title: String
    var cover: String
    var watchedAt: Date

    var id: String { roomID }
}

// MARK: - 本地库

/// 关注与观看历史的本地存储。
///
/// 刻意用 Codable + JSON 文件而不是 SwiftData：
/// 1. 数据量在数百条量级，JSON 完全够用，且无 schema 迁移风险；
/// 2. 路线图上的「云同步」需要把整份数据序列化后上传，Codable 结构天然可直接复用；
/// 3. 纯值类型便于单元测试，不依赖 ModelContainer。
@MainActor
@Observable
final class LibraryStore {
    private(set) var follows: [FollowedRoom] = []
    private(set) var history: [HistoryRecord] = []

    /// 关注主播的开播状态，key 为 roomID。刷新前为 nil（未知）。
    private(set) var liveStatus: [String: Bool] = [:]
    private(set) var isRefreshingFollows = false

    private let directory: URL
    private let followsURL: URL
    private let historyURL: URL

    init(storageDirectory: URL? = nil) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = storageDirectory ?? base.appendingPathComponent("SimpleLive", isDirectory: true)
        followsURL = directory.appendingPathComponent("follows.json")
        historyURL = directory.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        follows = Self.load([FollowedRoom].self, from: followsURL) ?? []
        history = Self.load([HistoryRecord].self, from: historyURL) ?? []
    }

    // MARK: 关注

    func isFollowed(_ roomID: String) -> Bool {
        follows.contains { $0.roomID == roomID }
    }

    func toggleFollow(detail: LiveRoomDetail) {
        if let index = follows.firstIndex(where: { $0.roomID == detail.roomID }) {
            follows.remove(at: index)
            liveStatus.removeValue(forKey: detail.roomID)
        } else {
            follows.insert(
                FollowedRoom(
                    roomID: detail.roomID,
                    userName: detail.userName,
                    avatar: detail.userAvatar,
                    title: detail.title,
                    addedAt: Date()
                ),
                at: 0
            )
            liveStatus[detail.roomID] = detail.isLiving
        }
        save(follows, to: followsURL)
    }

    func removeFollows(at offsets: IndexSet) {
        for index in offsets {
            liveStatus.removeValue(forKey: follows[index].roomID)
        }
        follows.remove(atOffsets: offsets)
        save(follows, to: followsURL)
    }

    func clearFollows() {
        follows.removeAll()
        liveStatus.removeAll()
        save(follows, to: followsURL)
    }

    /// 刷新关注列表的开播状态。
    ///
    /// 用 `roomBrief`（单请求）而不是 `roomDetail`（3 请求 + JS 签名）；
    /// 并按 5 个一批分组并发，避免一次性对斗鱼发起几十个请求被限流。
    /// 结果攒齐后一次写入：逐批写会让分组列表跟着每批重排一次。
    func refreshFollowStatus() async {
        guard !follows.isEmpty, !isRefreshingFollows else { return }
        isRefreshingFollows = true
        defer { isRefreshingFollows = false }

        let site = Sites.douyu
        let ids = follows.map(\.roomID)
        let batchSize = 5

        var briefs: [LiveRoomBrief] = []
        var index = 0
        while index < ids.count {
            let batch = Array(ids[index..<min(index + batchSize, ids.count)])
            index += batchSize

            briefs += await withTaskGroup(of: LiveRoomBrief?.self) { group in
                for roomID in batch {
                    group.addTask { try? await site.roomBrief(roomID: roomID) }
                }
                var collected: [LiveRoomBrief] = []
                for await brief in group {
                    if let brief { collected.append(brief) }
                }
                return collected
            }
        }

        // 最后一次 await 之后才取当前列表，刷新期间增删的关注不会被覆盖
        var status = liveStatus
        var updated = follows
        for brief in briefs {
            status[brief.roomID] = brief.isLiving
            guard let position = updated.firstIndex(where: { $0.roomID == brief.roomID })
            else { continue }
            if !brief.title.isEmpty { updated[position].title = brief.title }
            if !brief.userAvatar.isEmpty { updated[position].avatar = brief.userAvatar }
            if !brief.userName.isEmpty { updated[position].userName = brief.userName }
        }

        // 开播的排前面，其次按关注时间倒序
        updated.sort { lhs, rhs in
            let l = status[lhs.roomID] ?? false
            let r = status[rhs.roomID] ?? false
            if l != r { return l }
            return lhs.addedAt > rhs.addedAt
        }
        liveStatus = status
        follows = updated
        save(follows, to: followsURL)
    }

    // MARK: 跨设备关注分享

    func exportFollows(includeHistory: Bool = false) -> FollowTransferDocument {
        FollowTransferDocument(
            rooms: follows.map {
                FollowTransferRoom(roomID: $0.roomID, userName: $0.userName, title: $0.title, avatar: $0.avatar)
            },
            history: (includeHistory ? history : []).map {
                FollowTransferHistory(roomID: $0.roomID, userName: $0.userName, title: $0.title, cover: $0.cover, watchedAt: $0.watchedAt)
            }
        )
    }

    /// 导入的历史中比本机更新的条目（同一房间取最近一次观看）。
    func historyUpdates(from document: FollowTransferDocument) -> [FollowTransferHistory] {
        document.historyUpdates(existing: Dictionary(history.map { ($0.roomID, $0.watchedAt) }, uniquingKeysWith: max))
    }

    /// Recompute additions at confirmation time. Persist first, then publish;
    /// failure must not leave the UI claiming an import that was never saved.
    /// History is merged by roomID keeping the newest watch, then trimmed to `historyLimit`;
    /// pass `historyLimit: nil` to leave local history untouched.
    func mergeFollows(_ document: FollowTransferDocument, historyLimit: Int?) throws -> (follows: Int, history: Int) {
        // Even programmatically created documents must pass the same validation.
        _ = try document.encoded()
        let added = document.additions(existingIDs: Set(follows.map(\.roomID)))
        let updates = historyLimit == nil ? [] : historyUpdates(from: document)

        if !added.isEmpty {
            let importedAt = Date()
            let merged = added.map {
                FollowedRoom(roomID: $0.roomID, userName: $0.userName, avatar: $0.avatar, title: $0.title, addedAt: importedAt)
            } + follows
            try JSONEncoder().encode(merged).write(to: followsURL, options: .atomic)
            follows = merged
        }
        var keptHistory = 0
        if let historyLimit, !updates.isEmpty {
            let updatedIDs = Set(updates.map(\.roomID))
            var merged = history.filter { !updatedIDs.contains($0.roomID) } + updates.map {
                HistoryRecord(roomID: $0.roomID, userName: $0.userName, title: $0.title, cover: $0.cover, watchedAt: $0.watchedAt)
            }
            merged.sort { $0.watchedAt > $1.watchedAt }
            if merged.count > historyLimit { merged.removeLast(merged.count - historyLimit) }
            keptHistory = merged.lazy.filter { updatedIDs.contains($0.roomID) }.count
            try JSONEncoder().encode(merged).write(to: historyURL, options: .atomic)
            history = merged
        }
        return (added.count, keptHistory)
    }

    // MARK: 历史

    /// 记录一次观看。同一房间只保留最近一条，并按上限裁剪。
    func recordHistory(detail: LiveRoomDetail, limit: Int) {
        history.removeAll { $0.roomID == detail.roomID }
        history.insert(
            HistoryRecord(
                roomID: detail.roomID,
                userName: detail.userName,
                title: detail.title,
                cover: detail.cover,
                watchedAt: Date()
            ),
            at: 0
        )
        if history.count > limit {
            history.removeLast(history.count - limit)
        }
        save(history, to: historyURL)
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        save(history, to: historyURL)
    }

    func clearHistory() throws {
        // Persist before publishing success; clearing must not silently fail.
        try JSONEncoder().encode([HistoryRecord]()).write(to: historyURL, options: .atomic)
        history.removeAll()
    }

    /// 设置中调小上限时立即生效
    func trimHistory(to limit: Int) {
        guard history.count > limit else { return }
        history.removeLast(history.count - limit)
        save(history, to: historyURL)
    }

    // MARK: 读写

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // 原子写入，避免进程被杀时留下半个文件
        try? data.write(to: url, options: .atomic)
    }
}
