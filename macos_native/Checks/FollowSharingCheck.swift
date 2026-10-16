import Foundation
import SimpleLiveKit

@main
struct FollowSharingCheck {
    @MainActor static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sender = LibraryStore(storageDirectory: base.appendingPathComponent("sender"))
        let receiverDirectory = base.appendingPathComponent("receiver")
        let receiver = LibraryStore(storageDirectory: receiverDirectory)
        let a = FollowTransferRoom(roomID: "1", userName: "本机名称", title: "本机标题")
        let remoteA = FollowTransferRoom(roomID: "1", userName: "远端名称", title: "远端标题")
        let b = FollowTransferRoom(roomID: "2", userName: "新增主播", title: "新增标题")
        _ = try receiver.mergeFollows(FollowTransferDocument(rooms: [a]))
        _ = try sender.mergeFollows(FollowTransferDocument(rooms: [remoteA, b]))
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
        let count = try receiver.mergeFollows(preview.document)
        precondition(count == 1 && receiver.follows.count == 2)
        precondition(receiver.follows.first(where: { $0.roomID == "1" })?.userName == "本机名称")
        let duplicateCount = try receiver.mergeFollows(preview.document)
        precondition(duplicateCount == 0)
        let reloaded = LibraryStore(storageDirectory: receiverDirectory)
        precondition(reloaded.follows.count == 2)
        let historyAfter = try Data(contentsOf: history)
        precondition(historyAfter == sentinel)
        print("PASS: file preview is non-mutating; merge deduplicates, preserves local metadata/history and survives reload")

        controller.didMerge(count: count)
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
        do { _ = try broken.mergeFollows(FollowTransferDocument(rooms: [b])); fatalError("Write failure ignored") }
        catch { precondition(broken.follows.isEmpty) }
        print("PASS: failed persistence leaves the in-memory follow list unchanged")

        // Exchange back to the original device: a union is repeatable in both directions.
        _ = try receiver.mergeFollows(FollowTransferDocument(rooms: [FollowTransferRoom(roomID: "3", userName: "第三位", title: "")]))
        let reverse = try FollowTransferDocument.decode(receiver.exportFollows().encoded())
        let reverseCount = try sender.mergeFollows(reverse)
        precondition(reverseCount == 1 && Set(sender.follows.map(\.roomID)) == Set(receiver.follows.map(\.roomID)))
        print("PASS: sharing back merges the union in both directions without duplicates")
    }
    @MainActor private static func wait(_ controller: FollowTransferController) async throws {
        for _ in 0..<1000 {
            if !controller.isReading { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Import fixture timed out")
    }
}
