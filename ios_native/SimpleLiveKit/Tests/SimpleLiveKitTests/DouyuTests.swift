import Foundation
import Testing

@testable import SimpleLiveKit

// MARK: - STT 文本协议

@Suite("斗鱼 STT 解析")
struct DouyuSTTTests {

    /// 取自真实 chatmsg 帧的字段组合
    private let chatFrame = "type@=chatmsg/rid@=9999/uid@=123456/nn@=测试昵称/txt@=大家好/cid@=abc/level@=32/dms@=10/col@=2/"

    @Test("解析弹幕关键字段")
    func parseChatMessage() {
        let value = DouyuSTT.parse(chatFrame)
        #expect(value.string("type") == "chatmsg")
        #expect(value.string("nn") == "测试昵称")
        #expect(value.string("txt") == "大家好")
        #expect(value.int("col") == 2)
        #expect(value.has("dms") == true)
    }

    @Test("反转义 @S 与 @A")
    func unescapeSpecialChars() {
        // @S -> "/"，@A -> "@"
        #expect(DouyuSTT.unescape("a@Sb@Ac") == "a/b@c")
    }

    @Test("弹幕正文含 URL 时不被误判成数组帧")
    func urlInTextStaysText() {
        // 反转义后是 "http://example.com@user"，其中的 "//" 不应触发数组分支
        let value = DouyuSTT.parse("type@=chatmsg/txt@=http:@S@Sexample.com@Auser/dms@=1/")
        #expect(value.string("txt") == "http://example.com@user")
        #expect(value.string("type") == "chatmsg")
    }

    @Test("嵌套 STT 结构仍能递归解析")
    func nestedStructureStillParses() {
        // 值里用 @A 编码 "@"，反转义后变成 "lv@=5/exp@=100"，属于真正的嵌套结构
        let value = DouyuSTT.parse("type@=chatmsg/dms@=1/bnn@=lv@A=5@Sexp@A=100@S/")
        #expect(value.string("type") == "chatmsg")
        guard case .object(let root) = value, case .object(let nested)? = root["bnn"] else {
            Issue.record("bnn 未解析为嵌套对象")
            return
        }
        #expect(nested["lv"] == .text("5"))
        #expect(nested["exp"] == .text("100"))
    }

    @Test("// 分隔的数组帧")
    func parseArrayFrame() {
        let value = DouyuSTT.parse("type@=a/dms@=1//type@=b/dms@=1")
        let items = value.asArray
        #expect(items.count == 2)
        #expect(items[0].string("type") == "a")
        #expect(items[1].string("type") == "b")
    }

    @Test("缺少 @= 的畸形片段被跳过而不崩溃")
    func malformedFieldIsSkipped() {
        let value = DouyuSTT.parse("type@=chatmsg/garbage/txt@=ok/")
        #expect(value.string("type") == "chatmsg")
        #expect(value.string("txt") == "ok")
        #expect(value.has("garbage") == false)
    }

    @Test("无 dms 字段的异常弹幕可被识别并丢弃")
    func detectsMissingDms() {
        let value = DouyuSTT.parse("type@=chatmsg/nn@=x/txt@=y/")
        #expect(value.has("dms") == false)
    }
}

// MARK: - 二进制封包

@Suite("斗鱼弹幕封包")
struct DouyuPacketTests {

    @Test("心跳包头部逐字节正确")
    func encodeHeartbeat() {
        let data = DouyuPacket.encode("type@=mrkl/")
        let bytes = [UInt8](data)

        // body 11 字节 → 长度字段 = 4 + 4 + 11 + 1 = 20
        #expect(bytes.count == 24)
        #expect(Array(bytes[0..<4]) == [20, 0, 0, 0])   // 长度（小端）
        #expect(Array(bytes[4..<8]) == [20, 0, 0, 0])   // 冗余长度
        #expect(Array(bytes[8..<10]) == [0xB1, 0x02])   // 689 小端
        #expect(bytes[10] == 0)                          // encrypted
        #expect(bytes[11] == 0)                          // reserved
        #expect(bytes[23] == 0)                          // 结尾固定 0
    }

    @Test("编解码往返")
    func roundTrip() {
        let body = "type@=chatmsg/nn@=昵称/txt@=内容/dms@=1/"
        let decoded = DouyuPacket.decode(DouyuPacket.encode(body))
        #expect(decoded == [body])
    }

    @Test("单帧内多条消息全部解出")
    func decodesBatchedFrame() {
        // 斗鱼会把多条消息合并进同一个 WebSocket 帧
        let bodies = ["type@=a/dms@=1/", "type@=b/dms@=1/", "type@=c/dms@=1/"]
        var merged = Data()
        for body in bodies {
            merged.append(DouyuPacket.encode(body))
        }
        #expect(DouyuPacket.decode(merged) == bodies)
    }

    @Test("截断数据不会崩溃")
    func handlesTruncatedData() {
        let full = DouyuPacket.encode("type@=chatmsg/dms@=1/")
        let truncated = full.prefix(full.count - 6)
        #expect(DouyuPacket.decode(Data(truncated)).isEmpty)
        #expect(DouyuPacket.decode(Data()).isEmpty)
        #expect(DouyuPacket.decode(Data([1, 2, 3])).isEmpty)
    }
}

// MARK: - 签名

@Suite("斗鱼签名（JavaScriptCore）")
struct DouyuSignTests {

    private func loadFixture() throws -> String {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "douyu_room_enc", withExtension: "js", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "douyu_room_enc", withExtension: "js")
        let path = try #require(url, "缺少签名脚本固件")
        return try String(contentsOf: path, encoding: .utf8)
    }

    @Test("用真实混淆脚本产出合法签名串")
    func producesValidSignature() throws {
        let roomJS = try loadFixture()
        let args = try DouyuSign.sign(roomJS: roomJS, roomID: "9999", timestamp: 1_789_881_548)

        #expect(args.hasPrefix("v="))
        #expect(args.contains("&did=\(DouyuSign.defaultDeviceID)"))
        #expect(args.contains("&tt=1789881548"))

        // sign 必须是 32 位小写十六进制（MD5）
        let sign = try #require(
            args.components(separatedBy: "&sign=").last,
            "签名串缺少 sign 字段"
        )
        #expect(sign.count == 32)
        #expect(sign.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("相同输入签名稳定")
    func signatureIsDeterministic() throws {
        let roomJS = try loadFixture()
        let first = try DouyuSign.sign(roomJS: roomJS, roomID: "9999", timestamp: 1_700_000_000)
        let second = try DouyuSign.sign(roomJS: roomJS, roomID: "9999", timestamp: 1_700_000_000)
        #expect(first == second)
    }

    @Test("脚本无效时抛出明确错误")
    func rejectsInvalidScript() {
        #expect(throws: LiveCoreError.self) {
            _ = try DouyuSign.sign(roomJS: "var x = 1;", roomID: "9999")
        }
    }
}

// MARK: - 工具与解析

@Suite("斗鱼工具方法")
struct DouyuHelperTests {

    @Test("热度文本解析", arguments: [
        ("1234", 1234),
        ("12.3万", 123_000),
        ("1万", 10_000),
        ("abc", -999),
    ])
    func parseHotNumber(input: String, expected: Int) {
        #expect(DouyuSite.parseHotNumber(input) == expected)
    }

    @Test("rtmp_live 的 &amp; 必须还原，否则鉴权参数失效")
    func htmlUnescape() {
        let raw = "9999abc_900.flv?wsAuth=xx&amp;token=yy&amp;expire=0"
        #expect(DouyuSite.htmlUnescape(raw) == "9999abc_900.flv?wsAuth=xx&token=yy&expire=0")
        #expect(DouyuSite.htmlUnescape("a&lt;b&gt;c&quot;d") == "a<b>c\"d")
    }

    @Test("弹幕颜色编号映射")
    func danmakuColors() {
        #expect(DouyuDanmakuClient.color(for: 1) == LiveMessageColor(255, 0, 0))
        #expect(DouyuDanmakuClient.color(for: 2) == LiveMessageColor(30, 135, 240))
        #expect(DouyuDanmakuClient.color(for: 6) == LiveMessageColor(255, 105, 180))
        #expect(DouyuDanmakuClient.color(for: 0) == .white)
        #expect(DouyuDanmakuClient.color(for: 99) == .white)
    }

    @Test("设备号为 32 位十六进制")
    func randomDeviceID() {
        let did = DouyuSite.randomHexString(length: 32)
        #expect(did.count == 32)
        #expect(did.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - JSON 访问器

@Suite("JSON 安全访问")
struct JSONTests {

    @Test("缺失路径返回安全默认值，不崩溃")
    func missingPathsAreSafe() throws {
        let json = try JSON(data: Data(#"{"data":{"rl":[{"rid":9999,"rn":"标题"}],"pgcnt":5}}"#.utf8))
        #expect(json["data"]["pgcnt"].intValue == 5)
        #expect(json["data"]["rl"][0]["rid"].stringValue == "9999")
        #expect(json["data"]["rl"][0]["rn"].stringValue == "标题")

        // 越界与缺失
        #expect(json["data"]["rl"][99].exists == false)
        #expect(json["nope"]["deeper"].stringValue == "")
        #expect(json["data"]["pgcnt"]["wrong"].intValue == 0)
    }

    @Test("数字与字符串互转")
    func numberStringCoercion() throws {
        let json = try JSON(data: Data(#"{"a":123,"b":"456","c":"12.5"}"#.utf8))
        #expect(json["a"].stringValue == "123")
        #expect(json["b"].intValue == 456)
        #expect(json["c"].int == 12)
    }
}
