import Foundation

enum MultiWatchRoomInput {
    static func roomID(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        func digits(_ text: String) -> String? {
            guard !text.isEmpty, text.count <= 20, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let normalized = String(text.drop(while: { $0 == "0" }))
            return normalized.isEmpty ? nil : normalized
        }
        func pathID(_ text: String) -> String? {
            if let numeric = digits(text) { return numeric }
            guard !text.isEmpty, text.count <= 32,
                  text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  text.contains(where: { $0.isLetter }) else { return nil }
            return text
        }
        if let id = digits(input) { return id }
        let lower = input.lowercased()
        for prefix in ["douyu:", "simplelive:"] where lower.hasPrefix(prefix) && !lower.hasPrefix("\(prefix)//") {
            return pathID(String(input.dropFirst(prefix.count)))
        }
        guard let url = URL(string: input) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        if scheme == "douyu" || scheme == "simplelive" {
            if host == "room", path.count == 1 { return pathID(path[0]) }
            if path.isEmpty, !host.isEmpty { return pathID(host) }
            if host.isEmpty, path.count == 1 { return pathID(path[0]) }
            return nil
        }
        if ["https", "http"].contains(scheme),
           ["douyu.com", "www.douyu.com", "m.douyu.com"].contains(host) {
            if path.count == 1 { return pathID(path[0]) }
            if path.count == 2 && path[0] == "room" { return pathID(path[1]) }
        }
        return nil
    }
}
