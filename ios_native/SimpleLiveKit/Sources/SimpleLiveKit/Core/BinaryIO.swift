import Foundation

/// 对应 Dart 版 `BinaryWriter`。
/// 斗鱼弹幕封包是小端定长头 + UTF-8 body + 结尾 0x00，需要精确控制字节序。
public struct BinaryWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func write(bytes newBytes: [UInt8]) {
        bytes.append(contentsOf: newBytes)
    }

    public mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16, littleEndian: Bool = true) {
        let v = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeInt32(_ value: Int32, littleEndian: Bool = true) {
        let v = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) }
    }

    public var data: Data { Data(bytes) }
}

/// 对应 Dart 版 `BinaryReader`。越界一律抛错，不返回脏数据。
public struct BinaryReader {
    public let bytes: [UInt8]
    public private(set) var position: Int = 0

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var remaining: Int { bytes.count - position }

    private mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= bytes.count else {
            throw LiveCoreError("字节流读取越界：需要 \(count) 字节，剩余 \(remaining)")
        }
        let slice = Array(bytes[position..<(position + count)])
        position += count
        return slice
    }

    public mutating func readUInt8() throws -> UInt8 {
        try take(1)[0]
    }

    public mutating func readUInt16(littleEndian: Bool = true) throws -> UInt16 {
        let raw = try take(2)
        let value = UInt16(raw[0]) | (UInt16(raw[1]) << 8)
        return littleEndian ? value : value.byteSwapped
    }

    public mutating func readInt32(littleEndian: Bool = true) throws -> Int32 {
        let raw = try take(4)
        let value = UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
        return Int32(bitPattern: littleEndian ? value : value.byteSwapped)
    }

    /// 大端 24 位无符号整数，FLV tag 头使用
    public mutating func readUInt24BE() throws -> UInt32 {
        let raw = try take(3)
        return (UInt32(raw[0]) << 16) | (UInt32(raw[1]) << 8) | UInt32(raw[2])
    }

    public mutating func readUInt32BE() throws -> UInt32 {
        let raw = try take(4)
        return (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try take(count)
    }

    public mutating func skip(_ count: Int) throws {
        _ = try take(count)
    }
}
