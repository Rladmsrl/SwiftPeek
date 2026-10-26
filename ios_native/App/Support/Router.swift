import Observation
import SwiftUI

enum AppTab: Hashable {
    case recommend, category, follow, mine, search
}

/// 房间路由值。单独建类型而不是直接用 roomID 字符串，
/// 避免和其他 String 目的地在 navigationDestination 上冲突。
struct RoomRoute: Hashable {
    let roomID: String
    let title: String
}

/// 「我的」栈内的目的地
enum MineRoute: Hashable {
    case settings, history
}

/// 全局路由。支撑 `douyu://room/9999` 这类深链，
/// 同时让自动化测试可以直接跳到任意房间。
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .recommend
    var recommendPath = NavigationPath()
    var minePath = NavigationPath()

    /// 处理外部链接，返回是否成功识别。
    /// 同时支持 `simplelive://` 与按站点命名的 `douyu://`。
    @discardableResult
    func handle(url: URL) -> Bool {
        let supportedSchemes = ["simplelive", "douyu"]
        guard let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme) else {
            return false
        }

        // 支持 simplelive://room/9999 与 douyu:9999
        var roomID: String?
        if url.host == "room" {
            roomID = url.pathComponents.first { $0 != "/" }
        } else if let host = url.host, host.allSatisfy(\.isNumber) {
            roomID = host
        } else {
            let path = url.absoluteString.replacingOccurrences(of: "\(scheme):", with: "")
            let digits = path.filter(\.isNumber)
            roomID = digits.isEmpty ? nil : digits
        }

        guard let roomID, !roomID.isEmpty else { return false }
        open(roomID: roomID)
        return true
    }

    func open(roomID: String, title: String? = nil) {
        selectedTab = .recommend
        recommendPath = NavigationPath()
        recommendPath.append(RoomRoute(roomID: roomID, title: title ?? "房间 \(roomID)"))
    }

    #if DEBUG
    /// 自动化验证入口。仅 Debug 构建可用，用于绕过 URL Scheme 的系统确认弹窗：
    ///   --args -launchRoom 9999      直接进入房间
    ///   --args -launchTab follow     直接切到某个 Tab
    ///   --args -launchRoute settings 直接打开「我的」下的设置或历史
    func applyLaunchArguments() {
        let defaults = UserDefaults.standard

        if let tab = defaults.string(forKey: "launchTab") {
            switch tab {
            case "recommend": selectedTab = .recommend
            case "category": selectedTab = .category
            case "follow": selectedTab = .follow
            case "mine": selectedTab = .mine
            case "search": selectedTab = .search
            default: break
            }
        }

        if let route = defaults.string(forKey: "launchRoute") {
            switch route {
            case "settings":
                selectedTab = .mine
                minePath = NavigationPath()
                minePath.append(MineRoute.settings)
            case "history":
                selectedTab = .mine
                minePath = NavigationPath()
                minePath.append(MineRoute.history)
            default: break
            }
        }

        if let room = defaults.string(forKey: "launchRoom"), !room.isEmpty {
            open(roomID: room)
        }
        if defaults.bool(forKey: "launchRoomLayout") {
            open(roomID: "layout-origin", title: "当前直播")
        }

        // Empty playback page for offline layout checks; no network or fake media.
        if defaults.bool(forKey: "launchReplayLayout") {
            selectedTab = .recommend
            recommendPath = NavigationPath()
            recommendPath.append(ReplayRoute())
        }

        if let hashID = defaults.string(forKey: "launchReplayHash"), !hashID.isEmpty {
            selectedTab = .recommend
            recommendPath = NavigationPath()
            recommendPath.append(ReplayRoute(hashID: hashID))
        }
    }
    #endif
}
