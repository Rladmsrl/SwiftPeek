import CoreMedia
import Foundation

// MARK: - FLV 结构

enum FLVTagType: UInt8 {
    case audio = 8
    case video = 9
    case script = 18
}

struct FLVTag {
    let type: FLVTagType
    /// 毫秒
    let timestamp: UInt32
    let payload: Data
}

/// 增量式 FLV 解析器。
///
/// 直播流是无限长的字节流，不能等下载完再解析，因此设计成
/// 「喂字节 → 尽可能吐出完整 tag」的消费模型。
/// 内部用读游标而非反复裁剪缓冲区，避免 O(n²) 拷贝。
///
/// 缓冲区刻意用 `[UInt8]` 而不是 `Data`：`Data` 经切片/`removeFirst`
/// 之后下标不保证从 0 开始，混用绝对下标会直接越界崩溃。
/// `Array` 的 `startIndex` 恒为 0，索引语义明确。
struct FLVParser {
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var headerConsumed = false

    /// 已消费字节超过该阈值时压缩缓冲区
    private let compactThreshold = 1 << 20

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// 取下一个完整 tag；数据不足时返回 nil，等待更多字节。
    mutating func nextTag() throws -> FLVTag? {
        if !headerConsumed {
            // FLV header: 'F''L''V' + version(1) + flags(1) + headerSize(4)
            guard available >= 9 else { return nil }
            guard buffer[cursor] == 0x46, buffer[cursor + 1] == 0x4C, buffer[cursor + 2] == 0x56 else {
                throw LivePlayerError.notFLV
            }
            let headerSize = Int(readUInt32BE(at: cursor + 5))
            // headerSize 理论恒为 9，但流是外部输入，必须防御异常值
            guard headerSize >= 9, headerSize < 1024 else { throw LivePlayerError.notFLV }
            guard available >= headerSize + 4 else { return nil }
            cursor += headerSize
            cursor += 4  // PreviousTagSize0
            headerConsumed = true
        }

        while true {
            // Tag header: type(1) + dataSize(3) + timestamp(3) + timestampExtended(1) + streamID(3)
            guard available >= 11 else { return nil }
            let rawType = buffer[cursor]
            let dataSize = Int(readUInt24BE(at: cursor + 1))
            let timestampLow = readUInt24BE(at: cursor + 4)
            let timestampHigh = UInt32(buffer[cursor + 7])
            let timestamp = (timestampHigh << 24) | timestampLow

            // tag 体 + 尾部 PreviousTagSize(4)
            guard available >= 11 + dataSize + 4 else { return nil }

            let payloadStart = cursor + 11
            let payload = Data(buffer[payloadStart..<(payloadStart + dataSize)])
            cursor += 11 + dataSize + 4

            compactIfNeeded()

            guard let type = FLVTagType(rawValue: rawType) else {
                continue  // 未知 tag 跳过，不中断流，也不递归以免爆栈
            }
            return FLVTag(type: type, timestamp: timestamp, payload: payload)
        }
    }

    // MARK: 私有

    private var available: Int { buffer.count - cursor }

    private func readUInt24BE(at index: Int) -> UInt32 {
        (UInt32(buffer[index]) << 16) | (UInt32(buffer[index + 1]) << 8) | UInt32(buffer[index + 2])
    }

    private func readUInt32BE(at index: Int) -> UInt32 {
        (UInt32(buffer[index]) << 24) | (UInt32(buffer[index + 1]) << 16)
            | (UInt32(buffer[index + 2]) << 8) | UInt32(buffer[index + 3])
    }

    private mutating func compactIfNeeded() {
        guard cursor >= compactThreshold else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }
}

// MARK: - 视频 tag

struct FLVVideoTag {
    enum Packet {
        /// AVCDecoderConfigurationRecord（含 SPS/PPS）
        case sequenceHeader(Data)
        /// AVCC 格式 NALU（4 字节长度前缀）
        case nalus(Data)
        case end
    }

    let isKeyframe: Bool
    /// 合成时间偏移，毫秒
    let compositionTimeOffset: Int32
    let packet: Packet

    /// 仅支持 AVC(H.264)；其他编码返回 nil 由上层给出明确提示
    init?(payload: Data) {
        guard payload.count >= 5 else { return nil }
        let frameType = (payload[0] & 0xF0) >> 4
        let codecID = payload[0] & 0x0F
        guard codecID == 7 else { return nil }  // 7 = AVC

        isKeyframe = frameType == 1
        let packetType = payload[1]

        // 24 位有符号合成时间偏移
        let raw = (UInt32(payload[2]) << 16) | (UInt32(payload[3]) << 8) | UInt32(payload[4])
        compositionTimeOffset = raw & 0x800000 != 0
            ? Int32(bitPattern: raw | 0xFF00_0000)
            : Int32(raw)

        let body = payload.subdata(in: 5..<payload.count)
        switch packetType {
        case 0: packet = .sequenceHeader(body)
        case 1: packet = .nalus(body)
        case 2: packet = .end
        default: return nil
        }
    }
}

/// AVCDecoderConfigurationRecord 解析结果
struct AVCConfig {
    let sps: [Data]
    let pps: [Data]
    let nalUnitLength: Int

    init?(record: Data) {
        // configurationVersion(1) profile(1) compat(1) level(1) lengthSizeMinusOne(1) numSPS(1)
        guard record.count > 6 else { return nil }
        nalUnitLength = Int(record[4] & 0x03) + 1

        var index = 5
        var sps: [Data] = []
        var pps: [Data] = []

        let spsCount = Int(record[index] & 0x1F)
        index += 1
        for _ in 0..<spsCount {
            guard index + 2 <= record.count else { return nil }
            let length = (Int(record[index]) << 8) | Int(record[index + 1])
            index += 2
            guard index + length <= record.count else { return nil }
            sps.append(record.subdata(in: index..<(index + length)))
            index += length
        }

        guard index < record.count else { return nil }
        let ppsCount = Int(record[index])
        index += 1
        for _ in 0..<ppsCount {
            guard index + 2 <= record.count else { return nil }
            let length = (Int(record[index]) << 8) | Int(record[index + 1])
            index += 2
            guard index + length <= record.count else { return nil }
            pps.append(record.subdata(in: index..<(index + length)))
            index += length
        }

        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        self.sps = sps
        self.pps = pps
    }

    /// 生成 VideoToolbox 可用的格式描述
    func makeFormatDescription() throws -> CMVideoFormatDescription {
        let parameterSets = sps + pps
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var retained: [UnsafeMutablePointer<UInt8>] = []
        defer { retained.forEach { $0.deallocate() } }

        for set in parameterSets {
            let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: raw, count: set.count)
            retained.append(raw)
            pointers.append(UnsafePointer(raw))
            sizes.append(set.count)
        }

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSets.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(nalUnitLength),
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw LivePlayerError.videoFormatFailed(status)
        }
        return description
    }
}

// MARK: - 音频 tag

struct FLVAudioTag {
    enum Packet {
        /// AudioSpecificConfig
        case sequenceHeader(Data)
        case raw(Data)
    }

    let packet: Packet

    /// 仅支持 AAC
    init?(payload: Data) {
        guard payload.count >= 2 else { return nil }
        let soundFormat = (payload[0] & 0xF0) >> 4
        guard soundFormat == 10 else { return nil }  // 10 = AAC

        let body = payload.subdata(in: 2..<payload.count)
        switch payload[1] {
        case 0: packet = .sequenceHeader(body)
        case 1: packet = .raw(body)
        default: return nil
        }
    }
}

/// AudioSpecificConfig → CMAudioFormatDescription
struct AACConfig {
    let sampleRate: Double
    let channels: UInt32
    let magicCookie: Data

    private static let sampleRates: [Double] = [
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    init?(config: Data) {
        guard config.count >= 2 else { return nil }
        let byte0 = config[0]
        let byte1 = config[1]

        // 5 bits objectType | 4 bits frequencyIndex | 4 bits channelConfig
        let frequencyIndex = Int(((byte0 & 0x07) << 1) | ((byte1 & 0x80) >> 7))
        let channelConfig = UInt32((byte1 & 0x78) >> 3)

        guard frequencyIndex < Self.sampleRates.count, channelConfig > 0 else { return nil }
        sampleRate = Self.sampleRates[frequencyIndex]
        channels = channelConfig
        magicCookie = config
    }

    func makeFormatDescription() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description: CMAudioFormatDescription?
        let status = magicCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw LivePlayerError.audioFormatFailed(status)
        }
        return description
    }
}

// MARK: - 错误

enum LivePlayerError: LocalizedError {
    case notFLV
    case unsupportedCodec
    case videoFormatFailed(OSStatus)
    case audioFormatFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notFLV:
            return "响应不是 FLV 流，线路可能已失效"
        case .unsupportedCodec:
            return "流编码不是 H.264 + AAC，当前解码管线不支持"
        case .videoFormatFailed(let status):
            return "创建视频格式描述失败（\(status)）"
        case .audioFormatFailed(let status):
            return "创建音频格式描述失败（\(status)）"
        case .sampleBufferFailed(let status):
            return "封装采样缓冲失败（\(status)）"
        case .network(let message):
            return "拉流失败：\(message)"
        }
    }
}
