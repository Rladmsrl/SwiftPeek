import Foundation

/// 外部输入（深链、网页链接、搜索框里粘贴的文字）里的斗鱼房间号。
///
/// 只认明确支持的形式，其余一律当作普通文字：不从查询参数或任意位置里抠数字，
/// 否则 `simplelive://open?rid=74751&from=2` 会被拼成 747512 打开错误的房间。
public enum RoomLink {
    private static let roomSchemes: Set<String> = ["simplelive", "douyu"]
    private static let webHosts: Set<String> = ["douyu.com", "www.douyu.com", "m.douyu.com"]

    public static func roomID(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isDigits(text) { return text }

        // douyu:74751 / simplelive:74751（旧版 iOS 支持的不透明形式）
        if let colon = text.firstIndex(of: ":"),
           roomSchemes.contains(text[..<colon].lowercased()) {
            let rest = text[text.index(after: colon)...]
            if !rest.hasPrefix("/") { return isDigits(rest) ? String(rest) : nil }
        }

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if roomSchemes.contains(scheme) {
            if host == "room", parts.count == 1 {
                candidate = parts.first
            } else if !host.isEmpty, isDigits(host), parts.isEmpty {
                // douyu://74751
                candidate = host
            } else {
                return nil
            }
        } else if ["https", "http"].contains(scheme), webHosts.contains(host), parts.count == 1 {
            candidate = parts.first
        } else {
            return nil
        }
        guard let candidate, !candidate.isEmpty,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return candidate
    }

    private static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
