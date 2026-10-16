import Foundation

/// 弹幕客户端对外事件
public enum DanmakuEvent: Sendable {
    /// 连接就绪
    case ready
    case message(LiveMessage)
    /// 连接状态提示，直接用于 UI 展示
    case notice(String)
    case closed(String)
}

/// 弹幕客户端。各站点协议差异极大，统一收口为「事件流 + 启停」。
public protocol LiveDanmakuClient: Sendable {
    /// 单消费者事件流，由实现方在初始化时创建
    var events: AsyncStream<DanmakuEvent> { get }
    func start() async
    func stop() async
}

/// 直播站点适配器。方法签名与 Dart 版 `LiveSite` 一一对应，
/// 但把 `dynamic` 换成了 `any LiveSitePayload`，并全面 async throws。
public protocol LiveSite: Sendable {
    var id: String { get }
    var name: String { get }

    func makeDanmakuClient(payload: (any LiveSitePayload)?) throws -> any LiveDanmakuClient

    func categories() async throws -> [LiveCategory]
    func recommendRooms(page: Int) async throws -> LiveCategoryResult
    func categoryRooms(_ category: LiveSubCategory, page: Int) async throws -> LiveCategoryResult
    func roomDetail(roomID: String) async throws -> LiveRoomDetail
    /// 轻量房间概览：不做取流签名、不查开播时间，仅一次房间信息请求。
    /// 关注列表批量刷新等场景用它，避免 roomDetail 的 3 次请求 + JS 签名开销。
    func roomBrief(roomID: String) async throws -> LiveRoomBrief
    func playQualities(detail: LiveRoomDetail) async throws -> [LivePlayQuality]
    func playURL(detail: LiveRoomDetail, quality: LivePlayQuality) async throws -> LivePlayURL
    func searchRooms(_ keyword: String, page: Int) async throws -> LiveSearchRoomResult
    func searchAnchors(_ keyword: String, page: Int) async throws -> LiveSearchAnchorResult
    func liveStatus(roomID: String) async throws -> Bool
}

public extension LiveSite {
    func recommendRooms() async throws -> LiveCategoryResult {
        try await recommendRooms(page: 1)
    }
}
