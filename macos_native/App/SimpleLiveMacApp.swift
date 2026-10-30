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
                .tint(Theme.accent)
                .preferredColorScheme(settings.data.appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 620)
                .registersMainWindowOpener()
        }
        .defaultSize(width: 1240, height: 820)
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
                    .tint(Theme.accent)
                    .preferredColorScheme(settings.data.appearance.colorScheme)
                    .frame(minWidth: 760, minHeight: 500)
                    .registersMainWindowOpener()
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
                    .tint(Theme.accent)
                    .preferredColorScheme(settings.data.appearance.colorScheme)
                    .frame(minWidth: 820, minHeight: 540)
                    .registersMainWindowOpener()
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
                .tint(Theme.accent)
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

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Clicking the Dock icon with no visible windows brings back the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MacMainWindow.show()
        return false
    }

    @MainActor @objc private func showMainWindow() { MacMainWindow.show() }
}

/// AppKit entry points (Dock menu, reopen) can't reach SwiftUI's `openWindow`,
/// so any app window registers it when it appears.
@MainActor
enum MacMainWindow {
    fileprivate static var open: OpenWindowAction?

    static func show() {
        NSApp.activate()
        open?(id: "library")
    }
}

private struct MainWindowOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { MacMainWindow.open = openWindow }
    }
}

extension View {
    fileprivate func registersMainWindowOpener() -> some View {
        modifier(MainWindowOpenerRegistration())
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
