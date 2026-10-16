import SwiftUI
import SimpleLiveKit

/// 只为一件事存在：把「当前允许哪些方向」交给 SceneBridge 决定。
///
/// `requestGeometryUpdate` 是一次性请求，之后系统仍按
/// `supportedInterfaceOrientations` 跟随重力。没有这个代理，
/// 用户横着拿手机点「退出全屏」会被立刻转回横屏，等于退不出来。
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

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { SceneBridge.allowedOrientations }
    }
}

@main
struct SimpleLiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = Router()
    @State private var settings = AppSettings()
    @State private var library = LibraryStore()
    @State private var followTransfer = FollowTransferController()

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .followTransferPresentation()
                .environment(followTransfer)
                .tint(Theme.accent)
                .environment(settings)
                .environment(library)
                .environment(router)
                .preferredColorScheme(settings.data.appearance.colorScheme)
                .onOpenURL { url in
                    if !followTransfer.receive(url) { router.handle(url: url) }
                }
                .task {
                    #if DEBUG
                    router.applyLaunchArguments()
                    #endif
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
        // sidebarAdaptable：compact 宽度显示底部 Tab Bar，
        // regular 宽度（iPad / iPhone Duo 内屏）自动切换为侧边栏。
        // 这是 Apple 推荐的 Duo 折叠姿态适配方式，靠 size class 而非 orientation。
        .tabViewStyle(.sidebarAdaptable)
        // iOS 26 起的 Liquid Glass 行为：下滑时 Tab Bar 收缩，让内容成为主角
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
