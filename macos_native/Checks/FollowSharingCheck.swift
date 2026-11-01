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

        try checkDamagedFilesArePreserved(base.appendingPathComponent("damaged"))
        try await checkFollowStatusRefresh(base.appendingPathComponent("status"))
        await checkQuietRefreshKeepsPaging()
        await checkConfirmationNotStranded()
    }

    /// A card that scrolls away while queued must not leave the room stuck unconfirmed for the next card.
    @MainActor private static func checkConfirmationNotStranded() async {
        var calls: [String] = []
        var failOnce = true
        let confirmations = RoomStatusConfirmations(lookup: { id in
            calls.append(id)
            try await Task.sleep(for: .milliseconds(40))
            if id == "flaky", failOnce { failOnce = false; throw LiveCoreError("fixture") }
            return .live
        })
        func room(_ id: String) -> LiveRoomItem { LiveRoomItem(roomID: id, title: "", cover: "", userName: "", status: .loopCandidate) }
        // Fill all four slots, then queue "target" behind them and scroll it away.
        let busy = (0..<RoomStatusConfirmations.concurrency).map { i in Task { await confirmations.confirmIfNeeded(room("busy\(i)")) } }
        try? await Task.sleep(for: .milliseconds(5))
        let away = Task { await confirmations.confirmIfNeeded(room("target")) }
        try? await Task.sleep(for: .milliseconds(5))
        away.cancel()
        await away.value
        // The card reappears: it must get a real confirmation, not return early.
        await confirmations.confirmIfNeeded(room("target"))
        for task in busy { await task.value }
        precondition(confirmations.status(of: room("target")) == .live, "A cancelled waiter stranded the room unconfirmed")
        // Two cards for one room share a single request.
        let before = calls.count
        async let a: Void = confirmations.confirmIfNeeded(room("shared"))
        async let b: Void = confirmations.confirmIfNeeded(room("shared"))
        _ = await (a, b)
        precondition(calls.count == before + 1 && confirmations.status(of: room("shared")) == .live)
        // A failed lookup is retried on the next appearance.
        await confirmations.confirmIfNeeded(room("flaky"))
        precondition(confirmations.status(of: room("flaky")) == .loopCandidate)
        await confirmations.confirmIfNeeded(room("flaky"))
        precondition(confirmations.status(of: room("flaky")) == .live, "A failed confirmation was never retried")
        print("PASS: loop-room confirmations share one request per room, survive cancelled cards and retry failures")
    }

    @MainActor private static func checkDamagedFilesArePreserved(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let follows = directory.appendingPathComponent("follows.json")
        let history = directory.appendingPathComponent("history.json")
        // One good follow, one missing its id, one with a future field and missing display fields.
        let mixed = #"[{"roomID":"1","userName":"甲","avatar":"","title":"t","addedAt":0},{"userName":"坏"},{"roomID":"2","futureField":true}]"#
        try Data(mixed.utf8).write(to: follows)
        try Data("not json".utf8).write(to: history)
        let library = LibraryStore(storageDirectory: directory)
        precondition(library.follows.map(\.roomID) == ["1", "2"], "Tolerant decoding dropped good follows")
        precondition(library.history.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".corrupt-") }
        precondition(backups.contains { $0.hasPrefix("follows.corrupt-") } && backups.contains { $0.hasPrefix("history.corrupt-") },
                     "Damaged files were not set aside before rewriting")
        guard let historyBackup = backups.first(where: { $0.hasPrefix("history.corrupt-") }) else { fatalError("No history backup") }
        let preserved = try String(contentsOf: directory.appendingPathComponent(historyBackup), encoding: .utf8)
        precondition(preserved == "not json", "Backup does not hold the original bytes")
        library.recordHistory(detail: detail("3"), limit: 10)
        precondition(LibraryStore(storageDirectory: directory).history.map(\.roomID) == ["3"])
        print("PASS: damaged follows/history are backed up, good entries survive, and writes resume afterwards")
    }

    @MainActor private static func checkFollowStatusRefresh(_ directory: URL) async throws {
        actor Probe {
            var running = 0, peak = 0, calls: [String] = []
            func enter(_ id: String) { calls.append(id); running += 1; peak = max(peak, running) }
            func leave() { running -= 1 }
            func stats() -> (peak: Int, calls: Int) { (peak, calls.count) }
        }
        let probe = Probe()
        // Follows restored from disk have no status until a lookup succeeds.
        let seed = LibraryStore(storageDirectory: directory)
        for id in (0..<12).map({ "r\($0)" }) + ["bad"] { seed.follow(detail: detail(id)) }
        let library = LibraryStore(storageDirectory: directory, statusLookup: { id in
            await probe.enter(id)
            // The first room is slow; the window must keep the others moving.
            try? await Task.sleep(for: .milliseconds(id == "r0" ? 200 : 10))
            await probe.leave()
            if id == "bad" { throw LiveCoreError("fixture") }
            return LiveRoomBrief(roomID: id, title: "", cover: "", userName: "", userAvatar: "", online: 0,
                                 isLiving: id == "r1", isRecord: id == "r2")
        })
        precondition(library.follows.count == 13 && library.followGroups().unknown.count == 13)
        let followsFile = directory.appendingPathComponent("follows.json")

        let start = ContinuousClock.now
        await library.refreshFollowStatus()
        let peak = await probe.stats().peak
        precondition(peak <= LibraryStore.followStatusConcurrency, "Too many status requests in flight")
        precondition(ContinuousClock.now - start < .milliseconds(400), "One slow room stalled the refresh")
        let groups = library.followGroups()
        precondition(groups.live.map(\.roomID) == ["r1"] && groups.looping.map(\.roomID) == ["r2"])
        precondition(groups.unknown.map(\.roomID) == ["bad"], "A failed lookup was grouped as offline")
        precondition(groups.offline.count == 10 && groups.rest.count == 11)

        // Nothing changed: the file must not be rewritten.
        let stamp = try FileManager.default.attributesOfItem(atPath: followsFile.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(20))
        await library.refreshFollowStatus()
        let after = try FileManager.default.attributesOfItem(atPath: followsFile.path)[.modificationDate] as? Date
        precondition(stamp == after, "An unchanged refresh rewrote follows.json")

        // A room that keeps failing must not trigger a full refresh on every appearance.
        let callsBefore = await probe.stats().calls
        await library.refreshFollowStatusOnAppear()
        let callsOnAppear = await probe.stats().calls
        precondition(callsOnAppear == callsBefore, "Re-entering refetched everything because one room failed")
        library.follow(detail: detail("new", living: true))
        library.unfollow(roomID: "new")
        await library.refreshFollowStatusOnAppear()
        let callsAfterUnfollow = await probe.stats().calls
        precondition(callsAfterUnfollow == callsBefore, "Unfollowed rooms triggered a refresh")
        print("PASS: follow status uses a 5-wide sliding window, keeps unknown separate, skips no-op writes and failed-room storms")
    }

    @MainActor private static func checkQuietRefreshKeepsPaging() async {
        var failNext = false
        var requested: [Int] = []
        let store = RecommendStore(fetch: { page in
            requested.append(page)
            if failNext { failNext = false; throw LiveCoreError("offline") }
            let items = (0..<10).map { LiveRoomItem(roomID: "p\(page)-\($0)", title: "", cover: "", userName: "") }
            return LiveCategoryResult(hasMore: page < 5, items: items)
        })
        await store.refresh()
        await store.loadMoreIfNeeded(currentItem: store.rooms.last!)
        await store.loadMoreIfNeeded(currentItem: store.rooms.last!)
        precondition(store.rooms.count == 30)
        failNext = true
        await store.refresh(quietly: true)
        precondition(store.phase == .loaded && store.rooms.count == 30, "A failed quiet refresh dropped the list")
        await store.loadMoreIfNeeded(currentItem: store.rooms.last!)
        precondition(requested.last == 4 && store.rooms.count == 40, "Quiet failure reset paging; next load re-requested page 2")
        print("PASS: a failed quiet refresh keeps the loaded pages and the paging position")
    }

    private static func detail(_ id: String, living: Bool = false) -> LiveRoomDetail {
        LiveRoomDetail(roomID: id, title: id, cover: "", userName: id, userAvatar: "", online: 0,
                       isLiving: living, payload: Payload(), url: "")
    }
    private struct Payload: LiveSitePayload {}
    @MainActor private static func wait(_ controller: FollowTransferController) async throws {
        for _ in 0..<1000 {
            if !controller.isReading { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Import fixture timed out")
    }
}
