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
                .appAppearance()
                .environment(followTransfer)
                .environment(settings)
                .environment(library)
                .tint(Theme.accent)
                .frame(minWidth: 900, minHeight: 620)
                .registersMainWindowOpener()
        }
        .defaultSize(width: 1240, height: 820)
        .defaultLaunchBehavior(.presented)
        // 链接与关注文件只由主窗口处理；直播间 / 录像窗口不会因外部事件被新建
        .handlesExternalEvents(matching: ["*"])
        .commands {
            MacWindowCommands()
            // 直播间 / 录像窗口必须带值打开，“新建窗口”只会得到空白窗口
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("打开播放日志文件夹", action: MacDiagnostics.reveal)
            }
        }

        WindowGroup("直播间", id: "room", for: String.self) { $roomID in
            if let roomID {
                MacRoomView(roomID: roomID)
                    .appAppearance()
                    .environment(settings)
                    .environment(library)
                    .tint(Theme.accent)
                    .frame(minWidth: 760, minHeight: 500)
                    .registersMainWindowOpener()
            }
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        // Live sessions are transient: reopening the app must not resume a room.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("录像", id: "replay", for: ReplayRoute.self) { $route in
            if let route {
                MacReplayView(route: route)
                    .appAppearance()
                    .environment(settings)
                    .environment(library)
                    .tint(Theme.accent)
                    .frame(minWidth: 820, minHeight: 540)
                    .registersMainWindowOpener()
            }
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            MacSettingsView()
                .appAppearance()
                .environment(settings)
                .environment(library)
                .tint(Theme.accent)
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
        // ⌘Q 不经过窗口关闭：在这里保存音量和录像进度
        MainActor.assumeIsolated { MacSessionRegistry.closeAll() }
        LiveDiagnostics.record("app.terminate")
        LiveDiagnostics.flush()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: MacMainWindow.menuTitle, action: #selector(showMainWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Clicking the Dock icon with no visible windows brings back the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // 只剩最小化的窗口时按系统惯例把它还原，而不是另开主窗口
        if sender.windows.contains(where: \.isMiniaturized) { return true }
        MacMainWindow.show()
        return false
    }

    @MainActor @objc private func showMainWindow() { MacMainWindow.show() }
}

/// AppKit entry points (Dock menu, reopen) can't reach SwiftUI's `openWindow`,
/// so any app window registers it when it appears. When no window has appeared yet
/// (e.g. only Settings is open), the ⌘0 menu item does the same job.
@MainActor
enum MacMainWindow {
    fileprivate static var open: OpenWindowAction?
    fileprivate static let menuTitle = "显示主窗口"

    static func show() {
        NSApp.activate()
        if let open { open(id: "library"); return }
        if let menu = NSApp.mainMenu, performMenuItem(titled: menuTitle, in: menu) { return }
    }

    private static func performMenuItem(titled title: String, in menu: NSMenu) -> Bool {
        for (index, item) in menu.items.enumerated() {
            if item.title == title, item.isEnabled {
                menu.performActionForItem(at: index)
                return true
            }
            if let submenu = item.submenu, performMenuItem(titled: title, in: submenu) { return true }
        }
        return false
    }
}

/// Open playback sessions, so ⌘Q can persist them and an alias room ID does not
/// open a second window for a room that is already playing.
@MainActor
enum MacSessionRegistry {
    private final class Weak<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }
    private static var rooms: [Weak<MacRoomSession>] = []
    private static var replays: [Weak<ReplaySession>] = []

    static func register(_ session: MacRoomSession) {
        rooms.removeAll { $0.value == nil || $0.value === session }
        rooms.append(Weak(session))
    }
    static func unregister(_ session: MacRoomSession) {
        rooms.removeAll { $0.value == nil || $0.value === session }
    }
    static func register(_ session: ReplaySession) {
        replays.removeAll { $0.value == nil || $0.value === session }
        replays.append(Weak(session))
    }
    static func unregister(_ session: ReplaySession) {
        replays.removeAll { $0.value == nil || $0.value === session }
    }

    /// Another open window already playing the same resolved room.
    static func room(resolvedID: String, excluding session: MacRoomSession) -> MacRoomSession? {
        rooms.lazy.compactMap(\.value).first { other in
            other !== session && (other.store.detail?.roomID ?? other.roomID) == resolvedID
        }
    }

    static func closeAll() {
        rooms.compactMap(\.value).forEach { $0.close() }
        replays.compactMap(\.value).forEach { $0.close() }
        rooms.removeAll()
        replays.removeAll()
    }
}

/// External links and follow files are handled by the library window only.
/// A room or replay window that receives one forwards it there.
@MainActor
enum MacExternalLinks {
    private static var handler: (@MainActor (URL) -> Void)?
    private static var pending: [URL] = []

    static func register(_ handler: @escaping @MainActor (URL) -> Void) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        queued.forEach(handler)
    }
    static func unregister() { handler = nil }

    static func deliver(_ url: URL) {
        MacMainWindow.show()
        if let handler { handler(url) } else { pending.append(url) }
    }
}

private struct AppAppearance: ViewModifier {
    @Environment(AppSettings.self) private var settings
    // 只有这个修饰器读取外观设置：改其他设置时不会重建窗口内容（和其中的播放器）
    func body(content: Content) -> some View {
        content.preferredColorScheme(settings.data.appearance.colorScheme)
    }
}

/// Builds an expensive object on first use only. `@State` evaluates its initial
/// value on every view init, so players are kept behind this cheap box.
@MainActor
final class LazyBox<Value: AnyObject> {
    private var value: Value?
    func get(_ make: () -> Value) -> Value {
        if let value { return value }
        let made = make()
        value = made
        return made
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
    fileprivate func appAppearance() -> some View {
        modifier(AppAppearance())
    }
}

struct MacWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(MacMainWindow.menuTitle) { openWindow(id: "library") }
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
    /// Shared with iOS so both apps accept exactly the same links.
    static func roomID(_ raw: String) -> String? { RoomLink.roomID(from: raw) }
}
