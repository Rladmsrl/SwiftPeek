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

    enum CodingKeys: String, CodingKey { case roomID, userName, avatar, title, addedAt }
}

struct HistoryRecord: Codable, Identifiable, Hashable {
    var roomID: String
    var userName: String
    var title: String
    var cover: String
    var watchedAt: Date

    var id: String { roomID }

    enum CodingKeys: String, CodingKey { case roomID, userName, title, cover, watchedAt }
}

// 逐字段宽容解码：只有房间号是必需的。以后增加字段、或某条记录缺了展示字段，
// 都不能让整份关注 / 历史读取失败。写出格式不变。
extension FollowedRoom {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let roomID = try container.decode(String.self, forKey: .roomID)
        guard !roomID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .roomID, in: container, debugDescription: "empty room id")
        }
        self.init(roomID: roomID,
                  userName: (try? container.decodeIfPresent(String.self, forKey: .userName)) ?? "",
                  avatar: (try? container.decodeIfPresent(String.self, forKey: .avatar)) ?? "",
                  title: (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "",
                  addedAt: (try? container.decodeIfPresent(Date.self, forKey: .addedAt)) ?? .distantPast)
    }
}

extension HistoryRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let roomID = try container.decode(String.self, forKey: .roomID)
        guard !roomID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .roomID, in: container, debugDescription: "empty room id")
        }
        self.init(roomID: roomID,
                  userName: (try? container.decodeIfPresent(String.self, forKey: .userName)) ?? "",
                  title: (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "",
                  cover: (try? container.decodeIfPresent(String.self, forKey: .cover)) ?? "",
                  watchedAt: (try? container.decodeIfPresent(Date.self, forKey: .watchedAt)) ?? .distantPast)
    }
}

/// 数组逐条解码，坏掉的条目跳过并计数，不连累其余条目。
private struct TolerantList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var dropped = 0

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
                continue
            }
            dropped += 1
            // 解码失败不会前移游标：用空值或占位类型跳过这一条
            if (try? container.decodeNil()) == true { continue }
            _ = try container.decode(Skipped.self)
        }
    }
}

/// 关注列表按开播状态分组。
struct FollowGroups {
    var live: [FollowedRoom] = []
    var looping: [FollowedRoom] = []
    var offline: [FollowedRoom] = []
    /// 尚未刷新或查询失败。不能归入「未开播」：那会把查不到的主播说成没开播。
    var unknown: [FollowedRoom] = []
    /// 旧调用方使用：未开播与状态未知合在一起
    var rest: [FollowedRoom] { offline + unknown }
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

    /// 关注主播的状态（直播 / 轮播 / 未开播），key 为 roomID。刷新前为 nil（未知）。
    private(set) var roomStatus: [String: LiveRoomStatus] = [:]
    private(set) var isRefreshingFollows = false
    private var followsRefreshedAt: Date?
    /// 回到前台时，距上次刷新不足这么久就不再逐个请求关注主播的状态。
    static let followStatusStaleAfter: TimeInterval = 120
    /// 刷新时同时进行的状态请求上限
    static let followStatusConcurrency = 5
    /// 每个房间最近一次尝试查询状态的时间，成功或失败都记。
    /// 进入关注页时据此判断「从未查过」，查询失败的房间不会每次进入都被重查。
    private var statusAttemptedAt: [String: Date] = [:]
    private let statusLookup: @Sendable (String) async throws -> LiveRoomBrief

    private let directory: URL
    private let followsURL: URL
    private let historyURL: URL
    /// 读取失败且没能备份的文件：本次运行不再写入，避免用空列表覆盖用户数据。
    private var protectedFiles: Set<URL> = []

    init(storageDirectory: URL? = nil, statusLookup: (@Sendable (String) async throws -> LiveRoomBrief)? = nil) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = storageDirectory ?? base.appendingPathComponent("SimpleLive", isDirectory: true)
        followsURL = directory.appendingPathComponent("follows.json")
        historyURL = directory.appendingPathComponent("history.json")
        let site = Sites.douyu
        self.statusLookup = statusLookup ?? { try await site.roomBrief(roomID: $0) }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        follows = loadList(FollowedRoom.self, from: followsURL)
        history = loadList(HistoryRecord.self, from: historyURL)
    }

    // MARK: 关注

    func isFollowed(_ roomID: String) -> Bool {
        follows.contains { $0.roomID == roomID }
    }

    func toggleFollow(detail: LiveRoomDetail) {
        if isFollowed(detail.roomID) { unfollow(roomID: detail.roomID) } else { follow(detail: detail) }
    }

    /// 显式关注。界面上的按钮状态若来自别名房间号而过期，toggle 会做相反的事；
    /// 按用户看到的意图调用这两个方法则不会。已关注时什么也不做。
    func follow(detail: LiveRoomDetail) {
        guard !isFollowed(detail.roomID) else { return }
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
        roomStatus[detail.roomID] = LiveRoomStatus(isLiving: detail.isLiving, isRecord: detail.isRecord)
        save(follows, to: followsURL)
    }

    /// 显式取消关注。未关注时什么也不做。
    func unfollow(roomID: String) {
        guard let index = follows.firstIndex(where: { $0.roomID == roomID }) else { return }
        follows.remove(at: index)
        roomStatus.removeValue(forKey: roomID)
        save(follows, to: followsURL)
    }

    func removeFollows(at offsets: IndexSet) {
        for index in offsets {
            roomStatus.removeValue(forKey: follows[index].roomID)
        }
        follows.remove(atOffsets: offsets)
        save(follows, to: followsURL)
    }

    func clearFollows() {
        follows.removeAll()
        roomStatus.removeAll()
        save(follows, to: followsURL)
    }

    /// 刷新关注列表的开播状态。
    ///
    /// 用 `roomBrief`（单请求）而不是 `roomDetail`（3 请求 + JS 签名）；
    /// 最多 5 个请求同时进行，避免一次性对斗鱼发起几十个请求被限流。
    /// 用滑动窗口而不是整批等待：一个慢请求（最长 20 秒超时）不会卡住后面所有房间。
    /// 结果攒齐后一次写入：逐个写会让分组列表跟着反复重排。内容没变时不重写文件。
    func refreshFollowStatus() async {
        guard !follows.isEmpty, !isRefreshingFollows else { return }
        isRefreshingFollows = true
        defer { isRefreshingFollows = false }
        let startedAt = Date()
        followsRefreshedAt = startedAt

        let ids = follows.map(\.roomID)
        for id in ids { statusAttemptedAt[id] = startedAt }
        let lookup = statusLookup
        let limit = Self.followStatusConcurrency
        let results = await withTaskGroup(of: (String, LiveRoomBrief?).self) { group -> [(String, LiveRoomBrief?)] in
            var next = 0
            while next < min(limit, ids.count) {
                let id = ids[next]
                next += 1
                group.addTask { (id, try? await lookup(id)) }
            }
            var collected: [(String, LiveRoomBrief?)] = []
            while let result = await group.next() {
                collected.append(result)
                if next < ids.count {
                    let id = ids[next]
                    next += 1
                    group.addTask { (id, try? await lookup(id)) }
                }
            }
            return collected
        }

        // 最后一次 await 之后才取当前列表，刷新期间增删的关注不会被覆盖。
        // 按请求时的房间号记录：别名房间返回的是真实房间号，按返回值记就对不上关注项。
        var status = roomStatus
        var updated = follows
        for (id, brief) in results {
            guard let brief else { continue }
            status[id] = brief.status
            guard let position = updated.firstIndex(where: { $0.roomID == id }) else { continue }
            if !brief.title.isEmpty { updated[position].title = brief.title }
            if !brief.userAvatar.isEmpty { updated[position].avatar = brief.userAvatar }
            if !brief.userName.isEmpty { updated[position].userName = brief.userName }
        }

        // 直播排前面，其次轮播、未开播，状态未知放最后；同组按关注时间倒序
        updated.sort { lhs, rhs in
            let l = Self.followRank(status[lhs.roomID])
            let r = Self.followRank(status[rhs.roomID])
            if l != r { return l < r }
            return lhs.addedAt > rhs.addedAt
        }
        if status != roomStatus { roomStatus = status }
        if updated != follows {
            follows = updated
            save(follows, to: followsURL)
        }
    }

    func refreshFollowStatusIfStale(now: Date = Date()) async {
        if let followsRefreshedAt, now.timeIntervalSince(followsRefreshedAt) < Self.followStatusStaleAfter { return }
        await refreshFollowStatus()
    }

    /// 关注页出现时调用：有从未查过状态的关注（例如刚导入的）就立即整体刷新，
    /// 否则按过期时间刷新。查询失败的房间已经记过尝试，不会让每次进入都重查全部。
    func refreshFollowStatusOnAppear(now: Date = Date()) async {
        if follows.contains(where: { roomStatus[$0.roomID] == nil && statusAttemptedAt[$0.roomID] == nil }) {
            await refreshFollowStatus()
        } else {
            await refreshFollowStatusIfStale(now: now)
        }
    }

    func followStatus(_ roomID: String) -> LiveRoomStatus? { roomStatus[roomID] }

    /// 关注列表分组：直播、轮播、未开播、状态未知。
    func followGroups() -> FollowGroups {
        var groups = FollowGroups()
        for item in follows {
            switch roomStatus[item.roomID] {
            case .live: groups.live.append(item)
            case .looping: groups.looping.append(item)
            case .offline: groups.offline.append(item)
            default: groups.unknown.append(item)
            }
        }
        return groups
    }

    private static func followRank(_ status: LiveRoomStatus?) -> Int {
        switch status {
        case .live: 0
        case .looping: 1
        case .offline: 2
        default: 3
        }
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
            try persist(merged, to: followsURL)
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
            try persist(merged, to: historyURL)
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
        try persist([HistoryRecord](), to: historyURL)
        history.removeAll()
    }

    /// 设置中调小上限时立即生效
    func trimHistory(to limit: Int) {
        guard history.count > limit else { return }
        history.removeLast(history.count - limit)
        save(history, to: historyURL)
    }

    // MARK: 读写

    /// 文件不存在时返回空列表。文件读不出或有条目解码失败时，先把原文件复制一份
    /// `follows.corrupt-<时间>.json` 再继续；连备份都失败就本次运行不再写这个文件。
    /// 原先解码失败直接当空列表，下一次 recordHistory / 关注就会把整份数据覆盖掉。
    private func loadList<Element: Decodable>(_ type: Element.Type, from url: URL) -> [Element] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(TolerantList<Element>.self, from: data) {
            if decoded.dropped > 0, !Self.preserveDamagedFile(at: url) { protectedFiles.insert(url) }
            return decoded.elements
        }
        if !Self.preserveDamagedFile(at: url) { protectedFiles.insert(url) }
        return []
    }

    private static func preserveDamagedFile(at url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let directory = url.deletingLastPathComponent()
        for suffix in 0..<100 {
            let name = suffix == 0 ? "\(stem).corrupt-\(stamp).json" : "\(stem).corrupt-\(stamp)-\(suffix).json"
            let backup = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: backup.path) else { continue }
            return (try? FileManager.default.copyItem(at: url, to: backup)) != nil
        }
        return false
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        guard !protectedFiles.contains(url) else {
            throw LiveCoreError("本地数据文件无法读取也无法备份，已停止写入以免覆盖")
        }
        // 原子写入，避免进程被杀时留下半个文件
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        try? persist(value, to: url)
    }
}
