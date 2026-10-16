import AppKit
import SimpleLiveKit
import SwiftUI

@main
struct SimpleLiveMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var library = LibraryStore()
    @State private var followTransfer = FollowTransferController()

    var body: some Scene {
        Window("SwiftPeek", id: "library") {
            MacLibraryView()
                .followTransferPresentation()
                .environment(followTransfer)
                .environment(settings)
                .environment(library)
                .tint(MacDesign.accent)
                .preferredColorScheme(settings.data.appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands {
            MacWindowCommands()
            CommandGroup(replacing: .help) {
                Button("打开播放日志文件夹", action: MacDiagnostics.reveal)
            }
        }

        WindowGroup("直播间", id: "room", for: String.self) { $roomID in
            if let roomID {
                MacRoomView(roomID: roomID)
                    .environment(settings)
                    .environment(library)
                    .tint(MacDesign.accent)
                    .preferredColorScheme(settings.data.appearance.colorScheme)
                    .frame(minWidth: 760, minHeight: 500)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        // Live sessions are transient: reopening the app must not resume a room.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("录像", id: "replay", for: ReplayRoute.self) { $route in
            if let route {
                MacReplayView(route: route)
                    .environment(settings)
                    .environment(library)
                    .tint(MacDesign.accent)
                    .preferredColorScheme(settings.data.appearance.colorScheme)
                    .frame(minWidth: 820, minHeight: 540)
            }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(library)
                .tint(MacDesign.accent)
                .preferredColorScheme(settings.data.appearance.colorScheme)
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LiveDiagnostics.record("app.launch", fields: [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        LiveDiagnostics.record("app.terminate")
        LiveDiagnostics.flush()
    }

}

struct MacWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("显示主窗口") { openWindow(id: "library") }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

enum MacDiagnostics {
    static func reveal() {
        LiveDiagnostics.flush()
        try? FileManager.default.createDirectory(at: LiveDiagnostics.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LiveDiagnostics.directory)
    }
}

enum MacRoomLink {
    /// Explicit supported schemes/hosts only; search text stays search text.
    static func roomID(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) { return text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if ["simplelive", "douyu"].contains(scheme), url.host == "room", parts.count == 1 {
            candidate = parts.first
        } else if ["https", "http"].contains(scheme),
                  ["douyu.com", "www.douyu.com", "m.douyu.com"].contains(url.host?.lowercased() ?? ""),
                  parts.count == 1 {
            candidate = parts.first
        } else {
            return nil
        }
        guard let candidate, !candidate.isEmpty,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return candidate
    }
}
