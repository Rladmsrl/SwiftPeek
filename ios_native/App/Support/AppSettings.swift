import Foundation
import Observation
import SwiftUI

// MARK: - 枚举选项

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

    // 列表
    var showHotBadge: Bool = true

    // 弹幕
    var danmakuVisibleByDefault: Bool = true
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
        showHotBadge = v(.showHotBadge, base.showHotBadge)
        danmakuVisibleByDefault = v(.danmakuVisibleByDefault, base.danmakuVisibleByDefault)
        danmakuFont = v(.danmakuFont, base.danmakuFont)
        danmakuFontSize = v(.danmakuFontSize, base.danmakuFontSize)
        danmakuOpacity = v(.danmakuOpacity, base.danmakuOpacity)
        danmakuAreaRatio = v(.danmakuAreaRatio, base.danmakuAreaRatio)
        danmakuSpeed = v(.danmakuSpeed, base.danmakuSpeed)
        danmakuStroke = v(.danmakuStroke, base.danmakuStroke)
        blockKeywords = v(.blockKeywords, base.blockKeywords)
        historyEnabled = v(.historyEnabled, base.historyEnabled)
        historyLimit = v(.historyLimit, base.historyLimit)
    }
}

// MARK: - 设置中心

@MainActor
@Observable
final class AppSettings {
    private static let storageKey = "app.settings.v1"

    var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            persist()
        }
    }

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    private func persist() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }

    func resetToDefaults() {
        data = SettingsData()
    }

    // MARK: 派生值

    /// 供弹幕渲染层使用的配置
    var danmakuSettings: DanmakuSettings {
        DanmakuSettings(
            font: data.danmakuFont,
            fontSize: data.danmakuFontSize,
            opacity: data.danmakuOpacity,
            areaRatio: data.danmakuAreaRatio,
            speed: data.danmakuSpeed,
            gap: 26,
            strokeWidth: data.danmakuStroke ? 1.6 : 0
        )
    }

    /// 屏蔽词判定。空词条会被忽略，避免误屏蔽全部弹幕。
    func isBlocked(_ text: String) -> Bool {
        let keywords = data.blockKeywords.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !keywords.isEmpty else { return false }
        let lowered = text.lowercased()
        return keywords.contains { lowered.contains($0.lowercased()) }
    }

    func addBlockKeyword(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !data.blockKeywords.contains(keyword) else { return }
        data.blockKeywords.append(keyword)
    }

    func removeBlockKeywords(at offsets: IndexSet) {
        data.blockKeywords.remove(atOffsets: offsets)
    }
}
