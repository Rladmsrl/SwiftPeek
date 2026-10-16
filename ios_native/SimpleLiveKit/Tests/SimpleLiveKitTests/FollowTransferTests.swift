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
        #expect(text.contains("\"version\" : 1"))
    }
    @Test("观看历史随文件同步，同一房间保留最近一次")
    func historyRoundTripAndMerge() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [
            FollowTransferHistory(roomID: "1", userName: "A", title: "旧", watchedAt: t0),
            FollowTransferHistory(roomID: "2", userName: "B", title: "新", cover: "https://example.com/c.jpg", watchedAt: t0.addingTimeInterval(60)),
            FollowTransferHistory(roomID: "2", userName: "B", title: "更早", watchedAt: t0)
        ]
        let data = try FollowTransferDocument(rooms: [room("1")], history: history).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\" : 2"))
        let received = try FollowTransferDocument.decode(data)
        #expect(received.historyRecords.count == 3)
        let all = received.historyUpdates(existing: [:])
        #expect(all.map(\.roomID) == ["2", "1"] && all[0].title == "新")
        // 本机房间 1 看得更晚则不覆盖；房间 2 本机较早则更新
        let updates = received.historyUpdates(existing: ["1": t0.addingTimeInterval(1), "2": t0.addingTimeInterval(30)])
        #expect(updates.map(\.roomID) == ["2"])
        #expect(received.historyUpdates(existing: ["1": t0, "2": t0.addingTimeInterval(60)]).isEmpty)
    }
    @Test("旧版本文件不含历史仍可导入，带历史的 v1 文件被拒绝")
    func versionCompatibility() throws {
        let v1 = try FollowTransferDocument(rooms: [room("1")]).encoded()
        #expect(try FollowTransferDocument.decode(v1).historyRecords.isEmpty)
        let v2 = try FollowTransferDocument(rooms: [], history: [FollowTransferHistory(roomID: "1", userName: "", title: "", watchedAt: Date())]).encoded()
        let forged = String(decoding: v2, as: UTF8.self).replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 1")
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument.decode(Data(forged.utf8)) }
        let invalid = FollowTransferHistory(roomID: "1", userName: "", title: "", cover: "file:///private/secret", watchedAt: Date())
        #expect(throws: FollowTransferError.self) { try FollowTransferDocument(rooms: [], history: [invalid]).encoded() }
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
