import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("发现与分类列表状态")
struct RoomListStatusTests {
    @Test("横屏、竖屏、语音房是直播；轮播类型只是待确认")
    func listStatusMapping() {
        for value: Any in [0, 1, 2, 4, "0", "1", "2", "4"] {
            #expect(DouyuSite.parseListRoomStatus(JSON(["rst": value])) == .live)
        }
        for value: Any in [3, "3"] {
            #expect(DouyuSite.parseListRoomStatus(JSON(["rst": value])) == .loopCandidate)
        }
    }

    @Test("缺失、畸形和未识别状态不能默认直播")
    func unknownIsNotLive() {
        for room: [String: Any] in [[:], ["type": 1], ["rt": 0], ["iv": 0],
                                  ["rst": NSNull()], ["rst": true], ["rst": false],
                                  ["rst": 1.5], ["rst": 5], ["rst": -1], ["rst": "bad"]] {
            #expect(DouyuSite.parseListRoomStatus(JSON(room)) == .unknown)
        }
        #expect(LiveRoomItem(roomID: "history", title: "", cover: "", userName: "").status == .unknown)
    }

    @Test("轮播类型房间贯穿列表解析，等待逐房确认")
    func loopCandidateSurvivesParsing() {
        // Public list state captured 2026-10-29. 6979222 was looping; 479079 had the
        // same rst while its anchor was live; 12487085 is a voice room (rst 4).
        // Keep only status fields; no playback URLs, cookies or identities.
        let response = JSON(["data": ["pgcnt": 2, "rl": [
            ["type": 1, "rid": 6979222, "rst": 3, "rt": 0, "ioa": 0],
            ["type": 1, "rid": 479079, "rst": 3, "rt": 2102, "ioa": 1],
            ["type": 1, "rid": 12487085, "rst": 4, "rt": 0, "ioa": 0],
            ["type": 1, "rid": 1, "rst": 0, "rt": 2115],
            ["type": 1, "rid": 2],
            ["type": 2, "rid": 3, "rst": 0]
        ]]])
        let result = DouyuSite.parseRoomList(response, page: 1)
        #expect(result.items.map(\.roomID) == ["6979222", "479079", "12487085", "1", "2"])
        #expect(result.items.map(\.status) == [.loopCandidate, .loopCandidate, .live, .live, .unknown])
        #expect(result.hasMore)
        #expect(!DouyuSite.parseRoomList(response, page: 2).hasMore)
    }

    @Test("推荐接口页数恒为 0 时，翻到空页为止")
    func recommendPagingWithoutPageCount() {
        let page = JSON(["data": ["pgcnt": 0, "rl": [["type": 1, "rid": 1, "rst": 0]]]])
        #expect(DouyuSite.parseRoomList(page, page: 9).hasMore)
        let end = JSON(["data": ["pgcnt": 0, "rl": [Any]()]])
        #expect(!DouyuSite.parseRoomList(end, page: 300).hasMore)
    }

    @Test("房间自身状态：直播、轮播、下播")
    func briefStatus() {
        #expect(LiveRoomStatus(isLiving: true, isRecord: false) == .live)
        #expect(LiveRoomStatus(isLiving: false, isRecord: true) == .looping)
        #expect(LiveRoomStatus(isLiving: false, isRecord: false) == .offline)
    }

    @Test("搜索房间：在播、下播与轮播类型")
    func searchRoomStatus() {
        #expect(DouyuSite.parseSearchRoomStatus(JSON(["isLive": 1, "roomType": 0])) == .live)
        #expect(DouyuSite.parseSearchRoomStatus(JSON(["isLive": 1, "roomType": 2])) == .live)
        #expect(DouyuSite.parseSearchRoomStatus(JSON(["isLive": 1, "roomType": 3])) == .loopCandidate)
        #expect(DouyuSite.parseSearchRoomStatus(JSON(["isLive": 2, "roomType": 3])) == .offline)
        #expect(DouyuSite.parseSearchRoomStatus(JSON([:])) == .unknown)
    }

    @Test("搜索主播按轮播标记区分，轮播类型房间仍可能在直播")
    func anchorStatus() {
        // Captured anchor states: a live anchor in a loop-type room (roomType 3, isLoop 0)
        // was previously reported as offline.
        #expect(DouyuSite.parseAnchorStatus(JSON(["isLive": 1, "isLoop": 0, "videoLoop": 0, "roomType": 3])) == .live)
        #expect(DouyuSite.parseAnchorStatus(JSON(["isLive": 1, "isLoop": 1, "videoLoop": 1, "roomType": 3])) == .looping)
        #expect(DouyuSite.parseAnchorStatus(JSON(["isLive": 1, "isLoop": 0, "videoLoop": 0, "roomType": 0])) == .live)
        #expect(DouyuSite.parseAnchorStatus(JSON(["isLive": 2, "isLoop": 0, "videoLoop": 0, "roomType": 3])) == .offline)
        #expect(DouyuSite.parseAnchorStatus(JSON(["isLive": 2, "roomType": 0])) == .offline)
        #expect(DouyuSite.parseAnchorStatus(JSON([:])) == .unknown)
        let anchor = LiveAnchorItem(roomID: "1", avatar: "", userName: "", status: .looping)
        #expect(!anchor.isLive)
    }
}
