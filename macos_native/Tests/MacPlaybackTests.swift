import Foundation
import Testing
@testable import SwiftPeek

@Suite("Mac 链接入口")
struct MacRoomLinkTests {
    @Test("识别房间号、网页和深链", arguments: [" 74751 ", "https://www.douyu.com/74751?from=search", "douyu://room/74751", "simplelive://room/74751", "https://m.douyu.com/74751/"])
    func acceptsRoom(_ input: String) { #expect(MacRoomLink.roomID(input) == "74751") }

    @Test("搜索词和不可信链接不作为房间号", arguments: ["主播名字", "https://douyu.com.evil.example/123", "https://example.com/123", "file:///123", "simplelive://wrong/123", "https://www.douyu.com/", "https://www.douyu.com/123/456", ""])
    func rejectsInvalid(_ input: String) { #expect(MacRoomLink.roomID(input) == nil) }
}

@Suite("Mac 共享 FLV 管线")
struct FLVTransportTests {
    // An FLV header followed by one AVC tag, split at every byte boundary.
    private let stream: [UInt8] = [0x46, 0x4c, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0,
                                   9, 0, 0, 5, 0, 0, 42, 1, 0, 0, 0,
                                   0x17, 1, 0, 0, 0, 0, 0, 0, 16]
    @Test("任意网络分块边界不丢帧")
    func chunkBoundaries() throws {
        for split in 1..<stream.count {
            var parser = FLVParser()
            parser.append(Data(stream.prefix(split)))
            #expect(try parser.nextTag() == nil)
            parser.append(Data(stream.dropFirst(split)))
            let parsed = try parser.nextTag()
            let tag = try #require(parsed)
            #expect(tag.type == .video)
            #expect(tag.timestamp == 0x0100002a)
            #expect(tag.payload == Data([0x17, 1, 0, 0, 0]))
            #expect(try parser.nextTag() == nil)
        }
    }

    @Test("CDN 错误页面被识别为非 FLV")
    func errorPage() {
        var parser = FLVParser()
        parser.append(Data("<html>expired ticket</html>".utf8))
        #expect(throws: LivePlayerError.self) { try parser.nextTag() }
    }
}
