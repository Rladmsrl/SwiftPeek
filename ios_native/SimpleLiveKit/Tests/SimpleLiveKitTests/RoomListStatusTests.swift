import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("发现与分类列表状态")
struct RoomListStatusTests {
    @Test("横屏、竖屏和语音是直播，轮播独立标记")
    func listStatusMapping() {
        for value: Any in [0, 1, 2, "0", "1", "2"] {
            #expect(DouyuSite.parseListRoomStatus(JSON(["rst": value])) == .live)
        }
        for value: Any in [3, "3"] {
            #expect(DouyuSite.parseListRoomStatus(JSON(["rst": value])) == .looping)
        }
    }

    @Test("缺失、畸形和未识别状态不能默认直播")
    func unknownIsNotLive() {
        for room: [String: Any] in [[:], ["type": 1], ["rt": 0], ["iv": 0],
                                  ["rst": NSNull()], ["rst": true], ["rst": false],
                                  ["rst": 1.5], ["rst": 4], ["rst": -1], ["rst": "bad"]] {
            #expect(DouyuSite.parseListRoomStatus(JSON(room)) == .unknown)
        }
        #expect(LiveRoomItem(roomID: "history", title: "", cover: "", userName: "").status == .unknown)
    }

    @Test("6657 轮播样本贯穿列表解析，卡片类型不代表开播状态")
    func loopSurvivesParsing() {
        // Public list state captured for alias /6657, canonical room 6979222.
        // Keep only status fields; no playback URLs, cookies or identities.
        let response = JSON(["data": ["pgcnt": 2, "rl": [
            ["type": 1, "rid": 6979222, "rst": 3, "rt": 1901, "iv": 0, "rn": "轮播样本"],
            ["type": 1, "rid": 1, "rst": 0, "rt": 2115],
            ["type": 1, "rid": 2],
            ["type": 2, "rid": 3, "rst": 0]
        ]]])
        let result = DouyuSite.parseRoomList(response, page: 1)
        #expect(result.items.map(\.roomID) == ["6979222", "1", "2"])
        #expect(result.items.map(\.status) == [.looping, .live, .unknown])
        #expect(result.hasMore)
        #expect(!DouyuSite.parseRoomList(response, page: 2).hasMore)
    }
}
