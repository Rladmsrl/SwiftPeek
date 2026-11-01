import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("外部链接解析")
struct RoomLinkTests {
    @Test("识别房间号、网页和深链", arguments: [
        " 74751 ", "https://www.douyu.com/74751?from=search", "douyu://room/74751", "simplelive://room/74751",
        "https://m.douyu.com/74751/", "http://douyu.com/74751", "SimpleLive://room/74751",
        // 旧版 iOS 支持的形式
        "douyu:74751", "simplelive:74751", "DOUYU:74751", "douyu://74751",
    ])
    func acceptsRoom(_ input: String) { #expect(RoomLink.roomID(from: input) == "74751") }

    @Test("别名房间号保留原样")
    func acceptsAlias() {
        #expect(RoomLink.roomID(from: "simplelive://room/abc_1") == "abc_1")
        #expect(RoomLink.roomID(from: "https://www.douyu.com/abc_1") == "abc_1")
    }

    @Test("搜索词和不可信链接不作为房间号", arguments: [
        "主播名字", "https://douyu.com.evil.example/123", "https://example.com/123", "file:///123",
        "simplelive://wrong/123", "https://www.douyu.com/", "https://www.douyu.com/123/456", "",
        "   ", "simplelive://room/74751/extra", "simplelive://room/", "simplelive://room/a-b",
        "douyu:abc", "douyu:74751?from=2", "douyu://74751/extra",
    ])
    func rejectsInvalid(_ input: String) { #expect(RoomLink.roomID(from: input) == nil) }

    @Test("不从查询参数里拼凑数字")
    func neverScrapesDigits() {
        #expect(RoomLink.roomID(from: "simplelive://open?rid=74751&from=2") == nil)
        #expect(RoomLink.roomID(from: "douyu://share?room=74751") == nil)
        #expect(RoomLink.roomID(from: "simplelive://room/74751?from=2") == "74751")
    }
}
