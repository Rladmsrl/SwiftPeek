import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("房间状态与线路身份")
struct RoomStateTests {
    @Test("未知开播状态不能被当成下播")
    func rejectsUnknown() {
        for room: [String: Any] in [[:], ["show_status": NSNull()], ["show_status": "bad"],
                                  ["show_status": 99], ["show_status": 1.5], ["show_status": false], ["show_status": true],
                                  ["show_status": 1, "videoLoop": "bad"]] {
            #expect(throws: LiveCoreError.self) { try DouyuSite.parseRoomState(JSON(room)) }
        }
    }

    @Test("正常直播、下播与轮播仍可区分")
    func knownStates() throws {
        #expect(try DouyuSite.parseRoomState(JSON(["show_status": 1, "videoLoop": 0])).isLiving)
        #expect(try DouyuSite.parseRoomState(JSON(["show_status": "1", "videoLoop": "0"])).isLiving)
        #expect(try !DouyuSite.parseRoomState(JSON(["show_status": 2])).isLiving)
        #expect(try !DouyuSite.parseRoomState(JSON(["show_status": "0"])).isLiving)
        let loop = try DouyuSite.parseRoomState(JSON(["show_status": 1, "videoLoop": 1]))
        #expect(loop.isRecord && !loop.isLiving)
    }

    @Test("线路重排或签名变更后按 CDN 身份匹配")
    func lineIdentity() {
        let old = LivePlayURL(urls: ["https://a/old", "https://b/old"], lineIDs: ["a", "b"])
        let fresh = LivePlayURL(urls: ["https://new-b/new", "https://new-a/new"], lineIDs: ["b", "a"])
        #expect(fresh.index(forLineID: old.lineID(at: 1)) == 0)
        #expect(fresh.index(forLineID: old.lineID(at: 0)) == 1)
        #expect(fresh.index(forLineID: "missing") == 0)
        #expect(old.lineID(at: -1) == nil)
    }
}
