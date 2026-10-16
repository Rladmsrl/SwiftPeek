import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "通用", playback = "播放", danmaku = "弹幕", storage = "记录与诊断"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .playback: "play.rectangle"
        case .danmaku: "text.bubble"
        case .storage: "clock.arrow.circlepath"
        }
    }
}

struct MacSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @State private var pane: SettingsPane = .general
    @State private var keyword = ""
    @State private var clearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("让直播更合你意").font(.system(size: 22, weight: .bold))
                    Text("每一点偏好，都会自动保存。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3").font(.system(size: 27, weight: .light))
                    .foregroundStyle(MacDesign.accent)
            }.padding(28)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SettingsPane.allCases) { item in
                        Button { pane = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 12, weight: pane == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                // Hit-test the padded label, including the empty space beside the text.
                                .contentShape(.interaction, Capsule())
                                .foregroundStyle(pane == item ? MacDesign.accent : .secondary)
                        }.buttonStyle(.plain)
                            .glassEffect(.regular.tint(pane == item ? MacDesign.accent.opacity(0.13) : .clear).interactive(), in: .capsule)
                            .accessibilityAddTraits(pane == item ? [.isSelected] : [])
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Form {
                switch pane {
                case .general: general
                case .playback: playback
                case .danmaku: danmaku
                case .storage: storage
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width: 620, height: 600)
            .background(MacBackdrop())
            .confirmationDialog("清空所有观看历史？", isPresented: $clearHistory) {
                Button("清空", role: .destructive) { library.clearHistory() }
            }
    }

    private var general: some View {
        @Bindable var settings = settings
        return Group {
            Section("外观") {
                Picker("窗口主题", selection: $settings.data.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Text("玻璃导航与控制条随系统外观变化，内容始终清晰可读。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                        Text("macOS 27 · 原生直播客户端 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
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
                LabeledContent("字号 · \(Int(settings.data.danmakuFontSize))") {
                    Slider(value: $settings.data.danmakuFontSize, in: 12...32, step: 1)
                }
                LabeledContent("不透明度") { Slider(value: $settings.data.danmakuOpacity, in: 0.2...1) }
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
                Button("清空观看历史", role: .destructive) { clearHistory = true }
                    .disabled(library.history.isEmpty)
            }
            Section("播放诊断") {
                Text("遇到断流时，可以在直播间菜单中记录当前状态，再打开日志文件夹查看。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("打开日志文件夹", action: MacDiagnostics.reveal).buttonStyle(.glass)
                Text("日志仅保存在本机，自动轮转，最多约 8 MB；不记录完整播放地址或弹幕正文。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
    private func addKeyword() { settings.addBlockKeyword(keyword); keyword = "" }
}
