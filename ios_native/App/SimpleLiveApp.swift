import SwiftUI
import SimpleLiveKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LiveDiagnostics.record("app.launch", fields: [
            "platform": "iOS",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        return true
    }

}

@main
struct SimpleLiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = Router()
    @State private var settings = AppSettings()
    @State private var library = LibraryStore()
    @State private var followTransfer = FollowTransferController()
    @State private var multiWatch = PhoneMultiWatch(makePlayer: { FLVLivePlayer() })

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .followTransferPresentation()
                .environment(followTransfer)
                .tint(Theme.accent)
                .environment(settings)
                .environment(library)
                .environment(router)
                .environment(multiWatch)
                .preferredColorScheme(settings.data.appearance.colorScheme)
                .onOpenURL { url in
                    if !followTransfer.receive(url) { router.handle(url: url) }
                }
                .task {
                    multiWatch.configure(settings: settings, library: library)
                    #if DEBUG
                    router.applyLaunchArguments()
                    multiWatch.suppressConnectionsForLayoutPreview = UserDefaults.standard.bool(forKey: "launchRoomLayout")
                    let layoutCount = UserDefaults.standard.integer(forKey: "launchMultiWatchLayout")
                    if layoutCount > 0 {
                        router.selectedTab = .mine
                        multiWatch.showLayoutPreview(count: layoutCount)
                    }
                    #endif
                }
                .fullScreenCover(isPresented: $multiWatch.isPresented, onDismiss: { multiWatch.finish() }) {
                    MultiWatchView()
                        .environment(multiWatch)
                        .environment(settings)
                        .environment(library)
                        .tint(Theme.accent)
                        .preferredColorScheme(settings.data.appearance.colorScheme)
                }
        }
    }
}

struct RootView: View {
    @Bindable var router: Router

    @State private var recommend = RecommendStore()
    @State private var categories = CategoryStore()
    @State private var search = SearchStore()

    init(router: Router) {
        self.router = router
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("推荐", systemImage: "sparkles.tv", value: AppTab.recommend) {
                RecommendView(store: recommend, path: $router.recommendPath)
            }
            Tab("分类", systemImage: "square.grid.2x2", value: AppTab.category) {
                CategoryView(store: categories)
            }
            Tab("关注", systemImage: "star", value: AppTab.follow) {
                FollowView()
            }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.mine) {
                MineView()
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView(store: search)
            }
        }
        // 系统决定底部、侧边工具栏与侧边栏的呈现；不通过设备型号推断。
        // iOS 26 起的 Liquid Glass 行为：下滑时 Tab Bar 收缩，让内容成为主角
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
