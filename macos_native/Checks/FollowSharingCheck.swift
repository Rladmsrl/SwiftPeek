import Foundation
import SimpleLiveKit

@main
struct FollowSharingCheck {
    @MainActor static func main() async throws {
        let legacySettings = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        precondition(!legacySettings.diagnosticsEnabled, "Upgrading must not opt users into diagnostics")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sender = LibraryStore(storageDirectory: base.appendingPathComponent("sender"))
        let receiverDirectory = base.appendingPathComponent("receiver")
        let receiver = LibraryStore(storageDirectory: receiverDirectory)
        let a = FollowTransferRoom(roomID: "1", userName: "本机名称", title: "本机标题")
        let remoteA = FollowTransferRoom(roomID: "1", userName: "远端名称", title: "远端标题")
        let b = FollowTransferRoom(roomID: "2", userName: "新增主播", title: "新增标题")
        _ = try receiver.mergeFollows(FollowTransferDocument(rooms: [a]), historyLimit: 100)
        _ = try sender.mergeFollows(FollowTransferDocument(rooms: [remoteA, b]), historyLimit: 100)
        let history = receiverDirectory.appendingPathComponent("history.json")
        let sentinel = Data("[]".utf8)
        try sentinel.write(to: history)
        let sharedFile = base.appendingPathComponent("exchange.simplelivefollows")
        try sender.exportFollows().encoded().write(to: sharedFile)
        let controller = FollowTransferController()
        precondition(controller.receive(sharedFile))
        try await wait(controller)
        guard let preview = controller.pending else { fatalError("No import preview") }
        precondition(receiver.follows.count == 1, "Preview must not import automatically")
        precondition(preview.document.additions(existingIDs: Set(receiver.follows.map(\.roomID))).count == 1)
        let count = try receiver.mergeFollows(preview.document, historyLimit: 100).follows
        precondition(count == 1 && receiver.follows.count == 2)
        precondition(receiver.follows.first(where: { $0.roomID == "1" })?.userName == "本机名称")
        let duplicateCount = try receiver.mergeFollows(preview.document, historyLimit: 100).follows
        precondition(duplicateCount == 0)
        let reloaded = LibraryStore(storageDirectory: receiverDirectory)
        precondition(reloaded.follows.count == 2)
        let historyAfter = try Data(contentsOf: history)
        precondition(historyAfter == sentinel)
        print("PASS: file preview is non-mutating; merge deduplicates, preserves local metadata/history and survives reload")

        controller.didMerge(follows: count, history: 0)
        precondition(controller.pending == nil && controller.completionMessage == nil)
        controller.previewDismissed()
        precondition(controller.completionMessage != nil)
        try Data("not a document".utf8).write(to: sharedFile)
        precondition(controller.receive(sharedFile))
        try await wait(controller)
        precondition(controller.pending == nil && controller.errorMessage != nil && receiver.follows.count == 2)
        precondition(!controller.receive(URL(string: "simplelive://room/123")!))
        precondition(!controller.receive(URL(string: "https://example.com/follows.json")!))
        print("PASS: malformed documents and non-file URLs do not import or interfere with room links")

        let brokenPath = base.appendingPathComponent("broken")
        let broken = LibraryStore(storageDirectory: brokenPath)
        try FileManager.default.removeItem(at: brokenPath)
        try Data("not a directory".utf8).write(to: brokenPath)
        do { _ = try broken.mergeFollows(FollowTransferDocument(rooms: [b]), historyLimit: 100); fatalError("Write failure ignored") }
        catch { precondition(broken.follows.isEmpty) }
        print("PASS: failed persistence leaves the in-memory follow list unchanged")

        // Exchange back to the original device: a union is repeatable in both directions.
        _ = try receiver.mergeFollows(FollowTransferDocument(rooms: [FollowTransferRoom(roomID: "3", userName: "第三位", title: "")]), historyLimit: 100)
        let reverse = try FollowTransferDocument.decode(receiver.exportFollows().encoded())
        let reverseCount = try sender.mergeFollows(reverse, historyLimit: 100).follows
        precondition(reverseCount == 1 && Set(sender.follows.map(\.roomID)) == Set(receiver.follows.map(\.roomID)))
        print("PASS: sharing back merges the union in both directions without duplicates")

        // Watch history travels with the file: newest watch per room wins, then the local limit applies.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func watch(_ id: String, _ title: String, _ offset: TimeInterval) -> FollowTransferHistory {
            FollowTransferHistory(roomID: id, userName: "主播\(id)", title: title, watchedAt: t0.addingTimeInterval(offset))
        }
        _ = try receiver.mergeFollows(FollowTransferDocument(rooms: [], history: [watch("1", "本机较新", 100), watch("2", "本机较旧", 0)]), historyLimit: 100)
        _ = try sender.mergeFollows(FollowTransferDocument(rooms: [], history: [watch("1", "远端较旧", 50), watch("2", "远端较新", 60), watch("4", "远端新增", 10)]), historyLimit: 100)
        let privateExport = try FollowTransferDocument.decode(sender.exportFollows().encoded())
        precondition(privateExport.historyRecords.isEmpty, "Default share must not disclose history")
        let withHistory = try FollowTransferDocument.decode(sender.exportFollows(includeHistory: true).encoded())
        precondition(receiver.historyUpdates(from: withHistory).count == 2, "Preview counts only newer history")
        let disabled = try receiver.mergeFollows(withHistory, historyLimit: nil)
        precondition(disabled.history == 0, "History disabled must not import")
        let merged = try receiver.mergeFollows(withHistory, historyLimit: 100)
        precondition(merged.follows == 0 && merged.history == 2)
        precondition(receiver.history.map(\.title) == ["本机较新", "远端较新", "远端新增"])
        precondition(LibraryStore(storageDirectory: receiverDirectory).history.map(\.roomID) == ["1", "2", "4"])
        let repeated = try receiver.mergeFollows(withHistory, historyLimit: 100)
        precondition(repeated.history == 0)
        try receiver.clearHistory()
        precondition(receiver.history.isEmpty && LibraryStore(storageDirectory: receiverDirectory).history.isEmpty,
                     "Clearing history must persist, while keeping follows")
        precondition(!receiver.follows.isEmpty)
        do { try broken.clearHistory(); fatalError("Clear failure ignored") }
        catch { /* Failed persistence must be surfaced to the settings UI. */ }
        let trimmed = LibraryStore(storageDirectory: base.appendingPathComponent("trimmed"))
        let trimmedCount = try trimmed.mergeFollows(withHistory, historyLimit: 2).history
        precondition(trimmedCount == 2 && trimmed.history.map(\.roomID) == ["2", "1"])
        print("PASS: history merges newest-per-room, respects the disabled toggle and limit, and survives reload")
    }
    @MainActor private static func wait(_ controller: FollowTransferController) async throws {
        for _ in 0..<1000 {
            if !controller.isReading { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Import fixture timed out")
    }
}
