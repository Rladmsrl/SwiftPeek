import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library

    @State private var newKeyword = ""
    @State private var showResetConfirm = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            // MARK: 外观
            Section("外观") {
                Picker("主题", selection: $settings.data.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("列表显示热度", isOn: $settings.data.showHotBadge)
            }

            // MARK: 播放
            Section {
                Picker("默认清晰度", selection: $settings.data.qualityPreference) {
                    ForEach(QualityPreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                Toggle("进入直播间自动播放", isOn: $settings.data.autoPlay)
                Toggle("后台继续播放声音", isOn: $settings.data.backgroundAudio)
                if PiPController.isSupported {
                    Toggle("切到后台自动画中画", isOn: $settings.data.autoPictureInPicture)
                }
                Toggle("显示分辨率角标", isOn: $settings.data.showResolutionBadge)
                LabeledContent("自动播放缓冲", value: "约 4 秒")
            } header: {
                Text("播放")
            } footer: {
                Text("内存缓冲和后台换流可减少中断，会增加少量直播延迟，不保存视频到磁盘。关闭后台播放且未进入画中画时，退到后台会停止拉流以节省流量和电量。")
            }

            // MARK: 弹幕
            Section("弹幕") {
                Toggle("默认显示弹幕", isOn: $settings.data.danmakuVisibleByDefault)

                sliderRow(
                    title: "字号",
                    value: $settings.data.danmakuFontSize,
                    range: 11...28,
                    step: 1,
                    display: "\(Int(settings.data.danmakuFontSize))"
                )
                sliderRow(
                    title: "不透明度",
                    value: $settings.data.danmakuOpacity,
                    range: 0.2...1.0,
                    step: 0.05,
                    display: "\(Int(settings.data.danmakuOpacity * 100))%"
                )
                sliderRow(
                    title: "显示区域",
                    value: $settings.data.danmakuAreaRatio,
                    range: 0.2...1.0,
                    step: 0.1,
                    display: "\(Int(settings.data.danmakuAreaRatio * 100))%"
                )
                sliderRow(
                    title: "滚动速度",
                    value: $settings.data.danmakuSpeed,
                    range: 60...260,
                    step: 10,
                    display: "\(Int(settings.data.danmakuSpeed))"
                )
                Toggle("文字描边", isOn: $settings.data.danmakuStroke)
            }

            // MARK: 屏蔽词
            Section {
                HStack {
                    TextField("添加屏蔽词", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addKeyword)
                    Button("添加", action: addKeyword)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.data.blockKeywords, id: \.self) { keyword in
                    Text(keyword)
                }
                .onDelete { settings.removeBlockKeywords(at: $0) }
            } header: {
                Text("弹幕屏蔽词")
            } footer: {
                Text("命中任一关键词的弹幕不会出现在飞幕和列表中，匹配不区分大小写。")
            }

            // MARK: 历史与关注
            Section {
                Toggle("记录观看历史", isOn: $settings.data.historyEnabled)
                Picker("历史保留条数", selection: $settings.data.historyLimit) {
                    ForEach([50, 100, 200, 500], id: \.self) { limit in
                        Text("\(limit) 条").tag(limit)
                    }
                }
                Button("清空观看历史（\(library.history.count)）", role: .destructive) {
                    library.clearHistory()
                }
                .disabled(library.history.isEmpty)
                Button("清空关注（\(library.follows.count)）", role: .destructive) {
                    library.clearFollows()
                }
                .disabled(library.follows.isEmpty)
            } header: {
                Text("数据")
            }

            Section {
                Button("恢复默认设置", role: .destructive) { showResetConfirm = true }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.data.historyLimit) { _, limit in
            // 调小上限立即生效，而不是等下一次写入才裁剪
            library.trimHistory(to: limit)
        }
        .confirmationDialog(
            "恢复全部设置为默认值？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) { settings.resetToDefaults() }
            Button("取消", role: .cancel) {}
        }
    }

    private func addKeyword() {
        settings.addBlockKeyword(newKeyword)
        newKeyword = ""
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            Slider(value: value, in: range, step: step)
        }
    }
}
