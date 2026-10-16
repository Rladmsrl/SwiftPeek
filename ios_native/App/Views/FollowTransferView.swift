import CoreTransferable
import SimpleLiveKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let simpleLiveFollows = UTType(exportedAs: "com.simplelive.follows", conformingTo: .json)
}

struct SharedFollows: Transferable {
    let document: FollowTransferDocument
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .simpleLiveFollows) { item in
            let data = try item.document.encoded()
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleLiveFollowShares", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // Scope cleanup to this app-owned temporary directory, leaving recent shares valid.
            for old in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   Date().timeIntervalSince(created) > 172800 { try? FileManager.default.removeItem(at: old) }
            }
            let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SwiftPeek 关注.simplelivefollows")
            try data.write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
    }
}

/// Same send/import controls on iPhone, iPad and Mac. Sending is user-driven via
/// the system share sheet, where AirDrop is available when the device supports it.
struct FollowTransferActions: View {
    @Environment(LibraryStore.self) private var library
    @Environment(FollowTransferController.self) private var transfer
    @State private var importing = false

    var body: some View {
        HStack(spacing: 10) {
            ShareLink(item: SharedFollows(document: library.exportFollows()),
                      preview: SharePreview("SwiftPeek · \(library.follows.count) 个关注 · \(library.history.count) 条历史",
                                            image: Image(systemName: "heart.circle"))) {
                Label("分享关注", systemImage: "square.and.arrow.up")
            }.disabled(library.follows.isEmpty && library.history.isEmpty)
            Button { importing = true } label: { Label("导入关注", systemImage: "square.and.arrow.down") }
                .disabled(transfer.isReading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.simpleLiveFollows, .json]) { result in
            switch result {
            case .success(let url):
                if !transfer.receive(url) { transfer.errorMessage = "请选择 SwiftPeek 关注文件" }
            case .failure(let error):
                let nsError = error as NSError
                if nsError.code != NSUserCancelledError { transfer.errorMessage = error.localizedDescription }
            }
        }
    }
}

struct FollowImportPreviewView: View {
    let preview: FollowImportPreview
    @Environment(LibraryStore.self) private var library
    @Environment(FollowTransferController.self) private var transfer
    @Environment(AppSettings.self) private var settings
    @State private var importError: String?

    private var existing: Set<String> { Set(library.follows.map(\.roomID)) }
    private var additions: [FollowTransferRoom] { preview.document.additions(existingIDs: existing) }
    private var repeated: Int { preview.document.uniqueCount - additions.count }
    private var historyEnabled: Bool { settings.data.historyEnabled }
    private var historyUpdates: [FollowTransferHistory] {
        historyEnabled ? library.historyUpdates(from: preview.document) : []
    }
    private var hasChanges: Bool { !additions.isEmpty || !historyUpdates.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "heart.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("合并关注与历史").font(.title2.bold())
                    Text("只添加缺少的主播和更新的观看记录，保留本机已有数据。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                Label("新增 \(additions.count)", systemImage: "plus.circle").foregroundStyle(Theme.accent)
                Label("已关注 \(repeated)", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                if !historyUpdates.isEmpty {
                    Label("历史 \(historyUpdates.count)", systemImage: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                }
            }.font(.subheadline.weight(.medium))
            if additions.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(additions, id: \.roomID) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.userName.isEmpty ? "房间 \(item.roomID)" : item.userName).font(.headline)
                                    Text("斗鱼 · \(item.roomID)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus").foregroundStyle(Theme.accent)
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            Text(historyEnabled || preview.document.historyRecords.isEmpty
                 ? "不会删除关注或历史，也不会导入设置或账号信息。"
                 : "已在设置中关闭观看历史，文件中的历史不会导入。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(hasChanges ? "取消" : "完成") { transfer.pending = nil }
                    .buttonStyle(.glass)
                Spacer()
                if hasChanges {
                    Button("合并") {
                        do {
                            let merged = try library.mergeFollows(
                                preview.document, historyLimit: historyEnabled ? settings.data.historyLimit : nil)
                            transfer.didMerge(follows: merged.follows, history: merged.history)
                        } catch { importError = "未能保存：\(error.localizedDescription)" }
                    }.buttonStyle(.glassProminent).tint(Theme.accent)
                }
            }
        }.padding(24)
        #if os(macOS)
        .frame(width: 480, height: 500)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var emptyTitle: String {
        if !historyUpdates.isEmpty { return "关注无变化，将只合并观看历史" }
        return preview.document.uniqueCount == 0 ? "文件中没有关注" : "这些主播已经在关注列表中"
    }
}

private struct FollowTransferPresentation: ViewModifier {
    @Environment(FollowTransferController.self) private var transfer
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    func body(content: Content) -> some View {
        @Bindable var transfer = transfer
        content
            .sheet(item: $transfer.pending, onDismiss: { transfer.previewDismissed() }) { preview in
                FollowImportPreviewView(preview: preview).environment(library).environment(transfer).environment(settings)
            }
            .alert(transfer.errorMessage != nil ? "无法导入" : "合并完成", isPresented: Binding(
                get: { transfer.pending == nil && (transfer.errorMessage != nil || transfer.completionMessage != nil) },
                set: { if !$0 { transfer.errorMessage = nil; transfer.completionMessage = nil } }
            )) {
                Button("好") { transfer.errorMessage = nil; transfer.completionMessage = nil }
            } message: { Text(transfer.errorMessage ?? transfer.completionMessage ?? "") }
    }
}

extension View {
    func followTransferPresentation() -> some View { modifier(FollowTransferPresentation()) }
}
