import SwiftUI
import SimpleLiveKit

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "通用", playback = "播放", danmaku = "弹幕", storage = "记录与诊断"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.rectangle"
        case .danmaku: "text.bubble"
        case .storage: "clock.arrow.circlepath"
        }
    }
}

struct MacSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @State private var privacyError: String?
    @State private var pane: SettingsPane = .general
    @State private var keyword = ""
    @State private var clearHistory = false

    var body: some View {
        // 原生偏好设置窗口：顶部工具栏标签由系统绘制与切换
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { item in
                Tab(item.rawValue, systemImage: item.symbol, value: item) {
                    Form {
                        switch item {
                        case .general: general
                        case .playback: playback
                        case .danmaku: danmaku
                        case .storage: storage
                        }
                    }
                    .formStyle(.grouped)
                }
            }
        }
        .frame(width: 560, height: 500)
        .alert("清理未完成", isPresented: Binding(get: { privacyError != nil }, set: { if !$0 { privacyError = nil } })) {
            Button("好") { privacyError = nil }
        } message: { Text(privacyError ?? "") }
        .confirmationDialog("清空观看历史、录像进度和诊断日志？", isPresented: $clearHistory) {
            Button("清空", role: .destructive) { clearViewingData() }
        }
    }

    private var general: some View {
        @Bindable var settings = settings
        return Group {
            Section("外观") {
                Picker("窗口主题", selection: $settings.data.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("浏览") {
                Toggle("在直播卡片上显示热度", isOn: $settings.data.showHotBadge)
            }
            Section {
                HStack(spacing: 14) {
                    Image("BrandIcon").resizable().scaledToFit()
                        .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SwiftPeek").font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("macOS 26 · 原生直播客户端 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
        }
    }

    private var playback: some View {
        @Bindable var settings = settings
        return Group {
            Section("播放偏好") {
                Picker("默认清晰度", selection: $settings.data.qualityPreference) {
                    ForEach(QualityPreference.allCases) { Text($0.label).tag($0) }
                }
                Toggle("进入直播间自动播放", isOn: $settings.data.autoPlay)
                Toggle("显示视频分辨率", isOn: $settings.data.showResolutionBadge)
                LabeledContent("自动播放缓冲", value: "约 4 秒")
                Text("使用内存缓冲和后台换流减少中断，会增加少量直播延迟。网络长时间中断时仍可能暂停。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("画中画") {
                Toggle("小窗始终置顶", isOn: $settings.data.floatingWindowOnTop)
                Text("拖动画面移动小窗，拖动右下角调整大小。小窗内也可切换置顶和弹幕，直播与录像均适用。弹幕遵循播放器的开关与屏蔽词。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("窗口与快捷键") {
                LabeledContent("播放 / 停止", value: "空格")
                LabeledContent("静音", value: "M")
                LabeledContent("进入 / 退出全屏", value: "⌃ ⌘ F  或双击画面")
                LabeledContent("搜索", value: "⌘ F")
                Text("直播间独立播放。浏览其他页面时继续播放，关闭直播窗口时停止。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var danmaku: some View {
        @Bindable var settings = settings
        return Group {
            Section("弹幕显示") {
                Toggle("默认显示弹幕", isOn: $settings.data.danmakuVisibleByDefault)
                Text("字体、字号、可见度与画中画弹幕，可在播放页的“弹幕”下拉面板中调整。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                LabeledContent("显示区域") { Slider(value: $settings.data.danmakuAreaRatio, in: 0.2...1) }
                LabeledContent("滚动速度") { Slider(value: $settings.data.danmakuSpeed, in: 60...240) }
                Toggle("文字描边", isOn: $settings.data.danmakuStroke)
            }
            Section("屏蔽词") {
                HStack {
                    TextField("不想看到的词语", text: $keyword).onSubmit(addKeyword)
                    Button("添加", action: addKeyword).buttonStyle(.glass)
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.data.blockKeywords.isEmpty {
                    Text("含有这些词语的弹幕将自动隐藏。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(settings.data.blockKeywords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { settings.data.blockKeywords.removeAll { $0 == word } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除屏蔽词")
                    }
                }
            }
        }
    }

    private var storage: some View {
        @Bindable var settings = settings
        return Group {
            Section("观看历史") {
                Toggle("记录观看历史", isOn: $settings.data.historyEnabled)
                Picker("最多保留", selection: $settings.data.historyLimit) {
                    ForEach([50, 100, 200, 500], id: \.self) { Text("\($0) 条").tag($0) }
                }.onChange(of: settings.data.historyLimit) { _, limit in library.trimHistory(to: limit) }
                Text("历史开关同时控制录像续播记录。清理也会删除本机分享临时文件，保留关注。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空观看记录与日志", role: .destructive) { clearHistory = true }

            }
            Section("播放诊断") {
                Toggle("记录本地诊断日志", isOn: $settings.data.diagnosticsEnabled)
                Text("遇到断流时，可以在直播间菜单中记录当前状态，再打开日志文件夹查看。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("打开日志文件夹", action: MacDiagnostics.reveal).buttonStyle(.glass)
                Text("默认关闭。开启后记录房间号、时间和播放状态，仅保存在本机，最多约 8 MB。分享前请检查内容。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func clearViewingData() {
        do {
            try LiveDiagnostics.clear()
            let shares = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleLiveFollowShares", isDirectory: true)
            if FileManager.default.fileExists(atPath: shares.path) { try FileManager.default.removeItem(at: shares) }
            ReplayProgressStore.shared.clear()
            try library.clearHistory()
        } catch {
            privacyError = "未能清除全部记录，请重试。"
        }
    }

    private func addKeyword() { settings.addBlockKeyword(keyword); keyword = "" }
}
