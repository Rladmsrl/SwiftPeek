import SimpleLiveKit

struct PreparedPlaybackStream: Sendable {
    let stream: LivePlayURL
    let lineIndex: Int
    let qualityName: String
    var url: String { stream.urls[lineIndex] }
}
