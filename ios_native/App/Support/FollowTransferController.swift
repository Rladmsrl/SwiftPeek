import Foundation
import Observation
import SimpleLiveKit

struct FollowImportPreview: Identifiable {
    let id = UUID()
    let document: FollowTransferDocument
}

@MainActor
@Observable
final class FollowTransferController {
    var pending: FollowImportPreview?
    var errorMessage: String?
    var completionMessage: String?
    private(set) var isReading = false
    private var generation = 0
    private var queuedCompletion: String?

    func didMerge(follows: Int, history: Int) {
        var parts: [String] = []
        if follows > 0 { parts.append("\(follows) 个关注") }
        if history > 0 { parts.append("\(history) 条观看历史") }
        queuedCompletion = parts.isEmpty ? "没有需要合并的内容。" : "已合并 \(parts.joined(separator: "、"))，原有数据已保留。"
        pending = nil
    }

    func previewDismissed() {
        completionMessage = queuedCompletion
        queuedCompletion = nil
    }

    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.isFileURL, ["simplelivefollows", "json"].contains(url.pathExtension.lowercased()) else { return false }
        generation += 1
        let token = generation
        pending = nil
        queuedCompletion = nil
        errorMessage = nil
        completionMessage = nil
        isReading = true
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: FollowTransferDocument.maximumBytes + 1) ?? Data()
                    return try FollowTransferDocument.decode(data)
                }.value
                guard token == generation else { return }
                isReading = false
                errorMessage = nil
                completionMessage = nil
                pending = FollowImportPreview(document: document)
            } catch {
                guard token == generation else { return }
                isReading = false
                errorMessage = error.localizedDescription
            }
        }
        return true
    }
}
