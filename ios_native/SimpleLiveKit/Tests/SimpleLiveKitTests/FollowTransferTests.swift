import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("跨设备关注文件")
struct FollowTransferTests {
    private func room(_ id: String, name: String = "主播") -> FollowTransferRoom {
        FollowTransferRoom(roomID: id, userName: name, title: "标题", avatar: "https://example.com/avatar.png")
    }
    @Test("跨设备编码解码后按房间去重")
    func roundTripAndMerge() throws {
        let document = FollowTransferDocument(rooms: [room("1"), room("2"), room("2", name: "重复")])
        let received = try FollowTransferDocument.decode(document.encoded())
        #expect(received.uniqueCount == 2)
        let additions = received.additions(existingIDs: ["1"])
        #expect(additions.count == 1 && additions[0].roomID == "2" && additions[0].userName == "主播")
        #expect(received.additions(existingIDs: ["1", "2"]).isEmpty)
        let text = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(!text.contains("history") && !text.contains("settings") && !text.contains("cookie"))
    }
    @Test("拒绝未知版本、畸形数据与超限文件")
    func limits() throws {
        let valid = try FollowTransferDocument(rooms: [room("1")]).encoded()
        let future = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument.decode(Data(future.utf8)) }
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument.decode(Data("[]".utf8)) }
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument.decode(Data(repeating: 0, count: FollowTransferDocument.maximumBytes + 1)) }
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument(rooms: Array(repeating: room("1"), count: 2001)).encoded() }
    }
    @Test("拒绝错误平台、非法房间号与本地文件头像")
    func validatesFields() {
        let invalid = [
            FollowTransferRoom(roomID: "1", userName: "", title: "", site: "unsupported"),
            FollowTransferRoom(roomID: "../local", userName: "", title: ""),
            FollowTransferRoom(roomID: "", userName: "", title: ""),
            FollowTransferRoom(roomID: "1", userName: "", title: "", avatar: "file:///private/secret"),
            FollowTransferRoom(roomID: "1", userName: String(repeating: "x", count: 161), title: "")
        ]
        for room in invalid {
            #expect(throws: FollowTransferError.self) { try FollowTransferDocument(rooms: [room]).encoded() }
        }
    }
}
