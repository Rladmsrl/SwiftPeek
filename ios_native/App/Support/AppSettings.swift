import Foundation
import SimpleLiveKit
import Observation
import SwiftUI

// MARK: - 枚举选项

enum MultiWatchDanmakuMode: String, CaseIterable, Identifiable, Codable {
    case off, selected, all

    var id: Self { self }
    var label: String {
        switch self {
        case .off: "关闭"
        case .selected: "仅主画面"
        case .all: "所有画面"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum QualityPreference: String, CaseIterable, Identifiable, Codable {
    case highest, medium, lowest, remember

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highest: return "最高画质"
        case .medium: return "中等画质"
        case .lowest: return "最低（省流量）"
        case .remember: return "记住上次选择"
        }
    }

    /// 斗鱼返回的清晰度已按从好到差排序
    func index(in count: Int, lastQualityName: String?, names: [String]) -> Int {
        guard count > 0 else { return 0 }
        switch self {
        case .highest:
            return 0
        case .lowest:
            return count - 1
        case .medium:
            return count / 2
        case .remember:
            guard let lastQualityName,
                  let matched = names.firstIndex(of: lastQualityName)
            else { return 0 }
            return matched
        }
    }
}

// MARK: - 设置数据

/// 所有设置项的纯数据形态。
///
/// 自定义 `init(from:)` 全部走 `decodeIfPresent`：新增设置项时旧版本存档
/// 仍能正常解码并落到默认值，避免升级后设置被整体重置。
struct SettingsData: Codable, Equatable {
    // 外观
    var appearance: AppearanceMode = .system

    // 播放
    var qualityPreference: QualityPreference = .highest
    var lastQualityName: String?
    var autoPlay: Bool = true
    var backgroundAudio: Bool = true
    /// 切到桌面时自动进入画中画小窗
    var autoPictureInPicture: Bool = true
    var pictureInPictureDanmaku: Bool = false
    var floatingWindowOnTop: Bool = true
    var showResolutionBadge: Bool = true
    /// 播放器音量，退出直播间时记住
    var playerVolume: Double = 1.0
    /// 网络跟不上当前清晰度、反复卡顿时自动降一档（不改默认清晰度偏好）
    var autoLowerQuality: Bool = true

    // 列表
    var showHotBadge: Bool = true

    // 弹幕
    var danmakuVisibleByDefault: Bool = true
    var multiWatchDanmakuMode: MultiWatchDanmakuMode = .selected
    var danmakuFont: DanmakuFont = .system
    var danmakuFontSize: Double = 16
    var danmakuOpacity: Double = 1.0
    var danmakuAreaRatio: Double = 0.5
    var danmakuSpeed: Double = 130
    var danmakuStroke: Bool = true
    var blockKeywords: [String] = []

    // 历史
    var historyEnabled: Bool = true
    var historyLimit: Int = 100
    var diagnosticsEnabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        let base = SettingsData()
        appearance = v(.appearance, base.appearance)
        qualityPreference = v(.qualityPreference, base.qualityPreference)
        lastQualityName = try? c.decodeIfPresent(String.self, forKey: .lastQualityName)
        autoPlay = v(.autoPlay, base.autoPlay)
        backgroundAudio = v(.backgroundAudio, base.backgroundAudio)
        autoPictureInPicture = v(.autoPictureInPicture, base.autoPictureInPicture)
        pictureInPictureDanmaku = v(.pictureInPictureDanmaku, base.pictureInPictureDanmaku)
        floatingWindowOnTop = v(.floatingWindowOnTop, base.floatingWindowOnTop)
        showResolutionBadge = v(.showResolutionBadge, base.showResolutionBadge)
        playerVolume = v(.playerVolume, base.playerVolume)
        autoLowerQuality = v(.autoLowerQuality, base.autoLowerQuality)
        showHotBadge = v(.showHotBadge, base.showHotBadge)
        danmakuVisibleByDefault = v(.danmakuVisibleByDefault, base.danmakuVisibleByDefault)
        multiWatchDanmakuMode = v(.multiWatchDanmakuMode, base.multiWatchDanmakuMode)
        danmakuFont = v(.danmakuFont, base.danmakuFont)
        danmakuFontSize = v(.danmakuFontSize, base.danmakuFontSize)
        danmakuOpacity = v(.danmakuOpacity, base.danmakuOpacity)
        danmakuAreaRatio = v(.danmakuAreaRatio, base.danmakuAreaRatio)
        danmakuSpeed = v(.danmakuSpeed, base.danmakuSpeed)
        danmakuStroke = v(.danmakuStroke, base.danmakuStroke)
        blockKeywords = v(.blockKeywords, base.blockKeywords)
        historyEnabled = v(.historyEnabled, base.historyEnabled)
        historyLimit = v(.historyLimit, base.historyLimit)
        diagnosticsEnabled = v(.diagnosticsEnabled, base.diagnosticsEnabled)
    }
}

// MARK: - 设置中心

@MainActor
@Observable
final class AppSettings {
    private static let storageKey = "app.settings.v1"

    // 细粒度存储属性：每个视图只订阅自己读到的设置项，修改音量或清晰度不会触发无关列表 / 卡片重绘。
    var appearance: AppearanceMode { didSet { didMutate(changed: appearance != oldValue) } }
    var qualityPreference: QualityPreference { didSet { didMutate(changed: qualityPreference != oldValue) } }
    var lastQualityName: String? { didSet { didMutate(changed: lastQualityName != oldValue) } }
    var autoPlay: Bool { didSet { didMutate(changed: autoPlay != oldValue) } }
    var backgroundAudio: Bool { didSet { didMutate(changed: backgroundAudio != oldValue) } }
    var autoPictureInPicture: Bool { didSet { didMutate(changed: autoPictureInPicture != oldValue) } }
    var pictureInPictureDanmaku: Bool { didSet { didMutate(changed: pictureInPictureDanmaku != oldValue) } }
    var floatingWindowOnTop: Bool { didSet { didMutate(changed: floatingWindowOnTop != oldValue) } }
    var showResolutionBadge: Bool { didSet { didMutate(changed: showResolutionBadge != oldValue) } }
    var playerVolume: Double { didSet { didMutate(changed: playerVolume != oldValue) } }
    var autoLowerQuality: Bool { didSet { didMutate(changed: autoLowerQuality != oldValue) } }
    var showHotBadge: Bool { didSet { didMutate(changed: showHotBadge != oldValue) } }
    var danmakuVisibleByDefault: Bool { didSet { didMutate(changed: danmakuVisibleByDefault != oldValue) } }
    var multiWatchDanmakuMode: MultiWatchDanmakuMode { didSet { didMutate(changed: multiWatchDanmakuMode != oldValue) } }
    var danmakuFont: DanmakuFont { didSet { didMutate(changed: danmakuFont != oldValue) } }
    var danmakuFontSize: Double { didSet { didMutate(changed: danmakuFontSize != oldValue) } }
    var danmakuOpacity: Double { didSet { didMutate(changed: danmakuOpacity != oldValue) } }
    var danmakuAreaRatio: Double { didSet { didMutate(changed: danmakuAreaRatio != oldValue) } }
    var danmakuSpeed: Double { didSet { didMutate(changed: danmakuSpeed != oldValue) } }
    var danmakuStroke: Bool { didSet { didMutate(changed: danmakuStroke != oldValue) } }
    var blockKeywords: [String] {
        didSet {
            guard blockKeywords != oldValue else { return }
            rebuildNormalizedKeywords()
            didMutate(changed: true)
        }
    }
    var historyEnabled: Bool { didSet { didMutate(changed: historyEnabled != oldValue) } }
    var historyLimit: Int { didSet { didMutate(changed: historyLimit != oldValue) } }
    var diagnosticsEnabled: Bool {
        didSet {
            guard diagnosticsEnabled != oldValue else { return }
            LiveDiagnostics.setEnabled(diagnosticsEnabled)
            didMutate(changed: true)
        }
    }

    @ObservationIgnored private var isApplyingBatch = false
    @ObservationIgnored private var normalizedBlockKeywords: [String] = []

    /// 兼容整体读写与表单绑定（`$settings.data.xxx`）。写入时仅更新实际变化的字段，
    /// 不惊动未改动字段的观察者，并合并为一次持久化。
    var data: SettingsData {
        get { snapshotData() }
        set {
            guard newValue != snapshotData() else { return }
            isApplyingBatch = true
            if appearance != newValue.appearance { appearance = newValue.appearance }
            if qualityPreference != newValue.qualityPreference { qualityPreference = newValue.qualityPreference }
            if lastQualityName != newValue.lastQualityName { lastQualityName = newValue.lastQualityName }
            if autoPlay != newValue.autoPlay { autoPlay = newValue.autoPlay }
            if backgroundAudio != newValue.backgroundAudio { backgroundAudio = newValue.backgroundAudio }
            if autoPictureInPicture != newValue.autoPictureInPicture { autoPictureInPicture = newValue.autoPictureInPicture }
            if pictureInPictureDanmaku != newValue.pictureInPictureDanmaku { pictureInPictureDanmaku = newValue.pictureInPictureDanmaku }
            if floatingWindowOnTop != newValue.floatingWindowOnTop { floatingWindowOnTop = newValue.floatingWindowOnTop }
            if showResolutionBadge != newValue.showResolutionBadge { showResolutionBadge = newValue.showResolutionBadge }
            if playerVolume != newValue.playerVolume { playerVolume = newValue.playerVolume }
            if autoLowerQuality != newValue.autoLowerQuality { autoLowerQuality = newValue.autoLowerQuality }
            if showHotBadge != newValue.showHotBadge { showHotBadge = newValue.showHotBadge }
            if danmakuVisibleByDefault != newValue.danmakuVisibleByDefault { danmakuVisibleByDefault = newValue.danmakuVisibleByDefault }
            if multiWatchDanmakuMode != newValue.multiWatchDanmakuMode { multiWatchDanmakuMode = newValue.multiWatchDanmakuMode }
            if danmakuFont != newValue.danmakuFont { danmakuFont = newValue.danmakuFont }
            if danmakuFontSize != newValue.danmakuFontSize { danmakuFontSize = newValue.danmakuFontSize }
            if danmakuOpacity != newValue.danmakuOpacity { danmakuOpacity = newValue.danmakuOpacity }
            if danmakuAreaRatio != newValue.danmakuAreaRatio { danmakuAreaRatio = newValue.danmakuAreaRatio }
            if danmakuSpeed != newValue.danmakuSpeed { danmakuSpeed = newValue.danmakuSpeed }
            if danmakuStroke != newValue.danmakuStroke { danmakuStroke = newValue.danmakuStroke }
            if blockKeywords != newValue.blockKeywords { blockKeywords = newValue.blockKeywords }
            if historyEnabled != newValue.historyEnabled { historyEnabled = newValue.historyEnabled }
            if historyLimit != newValue.historyLimit { historyLimit = newValue.historyLimit }
            if diagnosticsEnabled != newValue.diagnosticsEnabled { diagnosticsEnabled = newValue.diagnosticsEnabled }
            isApplyingBatch = false
            LiveDiagnostics.setEnabled(diagnosticsEnabled)
            persist()
        }
    }

    init() {
        let initial: SettingsData
        if let raw = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            initial = decoded
        } else {
            initial = SettingsData()
        }
        appearance = initial.appearance
        qualityPreference = initial.qualityPreference
        lastQualityName = initial.lastQualityName
        autoPlay = initial.autoPlay
        backgroundAudio = initial.backgroundAudio
        autoPictureInPicture = initial.autoPictureInPicture
        pictureInPictureDanmaku = initial.pictureInPictureDanmaku
        floatingWindowOnTop = initial.floatingWindowOnTop
        showResolutionBadge = initial.showResolutionBadge
        playerVolume = initial.playerVolume
        autoLowerQuality = initial.autoLowerQuality
        showHotBadge = initial.showHotBadge
        danmakuVisibleByDefault = initial.danmakuVisibleByDefault
        multiWatchDanmakuMode = initial.multiWatchDanmakuMode
        danmakuFont = initial.danmakuFont
        danmakuFontSize = initial.danmakuFontSize
        danmakuOpacity = initial.danmakuOpacity
        danmakuAreaRatio = initial.danmakuAreaRatio
        danmakuSpeed = initial.danmakuSpeed
        danmakuStroke = initial.danmakuStroke
        blockKeywords = initial.blockKeywords
        historyEnabled = initial.historyEnabled
        historyLimit = initial.historyLimit
        diagnosticsEnabled = initial.diagnosticsEnabled
        rebuildNormalizedKeywords()
        LiveDiagnostics.setEnabled(diagnosticsEnabled)
    }

    private func snapshotData() -> SettingsData {
        var value = SettingsData()
        value.appearance = appearance
        value.qualityPreference = qualityPreference
        value.lastQualityName = lastQualityName
        value.autoPlay = autoPlay
        value.backgroundAudio = backgroundAudio
        value.autoPictureInPicture = autoPictureInPicture
        value.pictureInPictureDanmaku = pictureInPictureDanmaku
        value.floatingWindowOnTop = floatingWindowOnTop
        value.showResolutionBadge = showResolutionBadge
        value.playerVolume = playerVolume
        value.autoLowerQuality = autoLowerQuality
        value.showHotBadge = showHotBadge
        value.danmakuVisibleByDefault = danmakuVisibleByDefault
        value.multiWatchDanmakuMode = multiWatchDanmakuMode
        value.danmakuFont = danmakuFont
        value.danmakuFontSize = danmakuFontSize
        value.danmakuOpacity = danmakuOpacity
        value.danmakuAreaRatio = danmakuAreaRatio
        value.danmakuSpeed = danmakuSpeed
        value.danmakuStroke = danmakuStroke
        value.blockKeywords = blockKeywords
        value.historyEnabled = historyEnabled
        value.historyLimit = historyLimit
        value.diagnosticsEnabled = diagnosticsEnabled
        return value
    }

    private func didMutate(changed: Bool) {
        guard changed, !isApplyingBatch else { return }
        persist()
    }

    private func rebuildNormalizedKeywords() {
        normalizedBlockKeywords = blockKeywords
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func persist() {
        guard let raw = try? JSONEncoder().encode(snapshotData()) else { return }
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }

    func resetToDefaults() {
        data = SettingsData()
    }

    // MARK: 派生值

    /// 供弹幕渲染层使用的配置
    var danmakuSettings: DanmakuSettings {
        DanmakuSettings(
            font: danmakuFont,
            fontSize: danmakuFontSize,
            opacity: danmakuOpacity,
            areaRatio: danmakuAreaRatio,
            speed: danmakuSpeed,
            gap: 26,
            strokeWidth: danmakuStroke ? 1.6 : 0
        )
    }

    /// 屏蔽词判定。空词条在更新时已预处理，热路径零临时数组分配。
    func isBlocked(_ text: String) -> Bool {
        guard !normalizedBlockKeywords.isEmpty else { return false }
        let lowered = text.lowercased()
        return normalizedBlockKeywords.contains { lowered.contains($0) }
    }

    func addBlockKeyword(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              !blockKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else { return }
        blockKeywords.append(keyword)
    }

    func removeBlockKeywords(at offsets: IndexSet) {
        blockKeywords.remove(atOffsets: offsets)
    }
}
