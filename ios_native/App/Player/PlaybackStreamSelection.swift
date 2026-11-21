import Foundation
import SimpleLiveKit

struct PreparedPlaybackStream: Sendable {
    let stream: LivePlayURL
    let lineIndex: Int
    let qualityName: String
    var url: String { stream.urls[lineIndex] }
}

/// 后台续流已通过两次有效房间状态查询确认主播下播/轮播，播放器应终止重试而非继续空转 60 秒。
struct LiveStreamOfflineError: LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}
