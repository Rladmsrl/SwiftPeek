import Foundation

/// 斗鱼 STT（Serialized Text Type）解析结果。
///
/// STT 是斗鱼自有的文本序列化格式，形如：
/// `type@=chatmsg/rid@=9999/nn@=昵称/txt@=内容/`
/// 其中 `/` 转义为 `@S`，`@` 转义为 `@A`，`//` 分隔数组元素。
public enum STTValue: Sendable, Equatable {
    case text(String)
    case object([String: STTValue])
    case array([STTValue])

    /// 取字符串字段，非字符串或不存在时返回 nil
    public func string(_ key: String) -> String? {
        guard case .object(let dict) = self, case .text(let value)? = dict[key] else { return nil }
        return value
    }

    /// 字段是否存在（用于斗鱼 `dms` 这类「存在即有效」的标记位）
    public func has(_ key: String) -> Bool {
        guard case .object(let dict) = self else { return false }
        return dict[key] != nil
    }

    public func int(_ key: String) -> Int? {
        string(key).flatMap(Int.init)
    }

    public var asText: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    public var asArray: [STTValue] {
        guard case .array(let items) = self else { return [] }
        return items
    }
}

public struct DouyuSTT: Sendable {
    /// 解析 STT 文本。
    ///
    /// 与 Dart 版 `sttToJObject` 的一处差异：Dart 对每个字段值都无条件递归，
    /// 于是弹幕正文里的 `http://...` 在反转义后重新命中 `//` 分支，
    /// 被误判成数组帧、字段直接取不到值。这里只在反转义后仍含 `@=`
    /// （即确实是嵌套 STT 结构）时才递归，纯文本一律按文本收下。
    public static func parse(_ raw: String) -> STTValue {
        if raw.contains("//") {
            let fields = raw.components(separatedBy: "//").filter { !$0.isEmpty }
            return .array(fields.map { parse($0) })
        }
        if raw.contains("@=") {
            var result: [String: STTValue] = [:]
            for field in raw.components(separatedBy: "/") where !field.isEmpty {
                let tokens = field.components(separatedBy: "@=")
                // 无 "@=" 的片段直接丢弃；Dart 版此处会下标越界抛异常
                guard tokens.count >= 2 else { continue }
                let key = tokens[0]
                // 重新拼回剩余部分，避免值中意外出现 "@=" 时丢数据
                let value = unescape(tokens[1...].joined(separator: "@="))
                result[key] = value.contains("@=") ? parse(value) : .text(value)
            }
            return .object(result)
        }
        if raw.contains("@A=") {
            return parse(unescape(raw))
        }
        return .text(unescape(raw))
    }

    /// 反转义。顺序与 Dart 版一致：先还原 `/`，再还原 `@`
    public static func unescape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "@S", with: "/")
            .replacingOccurrences(of: "@A", with: "@")
    }
}

/// 斗鱼弹幕二进制封包编解码
public struct DouyuPacket: Sendable {
    /// 客户端 → 服务端 消息类型
    public static let clientToServer: UInt16 = 689
    /// 头部固定开销：两个 4 字节长度 + 2 字节类型 + 2 字节标志 + 1 字节结尾 0
    private static let headerOverhead = 9

    /// 编码一条 STT 文本为斗鱼封包
    public static func encode(_ body: String) -> Data {
        let payload = Array(body.utf8)
        // 长度字段 = 4(第二个长度) + 2(type) + 2(flags) + body + 1(结尾 0)
        let length = Int32(4 + 4 + payload.count + 1)

        var writer = BinaryWriter()
        writer.writeInt32(length)
        writer.writeInt32(length)
        writer.writeUInt16(clientToServer)
        writer.writeUInt8(0)  // encrypted
        writer.writeUInt8(0)  // reserved
        writer.write(bytes: payload)
        writer.writeUInt8(0)  // 结尾固定 0
        return writer.data
    }

    /// 解码一个 WebSocket 帧中的全部封包。
    ///
    /// 斗鱼会把多条消息合并进同一个帧，Dart 版只解析了第一条，
    /// 导致弹幕丢失。这里循环解析直到字节流耗尽。
    public static func decode(_ data: Data) -> [String] {
        var reader = BinaryReader(data)
        var messages: [String] = []

        while reader.remaining > 12 {
            do {
                let fullLength = try reader.readInt32()
                _ = try reader.readInt32()          // 冗余长度字段
                _ = try reader.readUInt16()         // packType
                _ = try reader.readUInt8()          // encrypted
                _ = try reader.readUInt8()          // reserved

                let bodyLength = Int(fullLength) - headerOverhead
                guard bodyLength > 0, bodyLength <= reader.remaining else { break }

                let bytes = try reader.readBytes(bodyLength)
                _ = try? reader.readUInt8()         // 结尾固定 0

                if let text = String(bytes: bytes, encoding: .utf8) {
                    messages.append(text)
                }
            } catch {
                break
            }
        }
        return messages
    }
}
