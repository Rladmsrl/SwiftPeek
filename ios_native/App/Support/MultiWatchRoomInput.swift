import Foundation

enum MultiWatchRoomInput {
    static func roomID(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func digits(_ text: String) -> String? {
            guard !text.isEmpty, text.count <= 20, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let normalized = String(text.drop(while: { $0 == "0" }))
            return normalized.isEmpty ? nil : normalized
        }
        if let id = digits(input) { return id }
        guard let url = URL(string: input) else { return nil }
        if ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           ["douyu.com", "www.douyu.com", "m.douyu.com"].contains(url.host?.lowercased() ?? "") {
            let path = url.pathComponents.filter { $0 != "/" }
            if path.count == 1 { return digits(path[0]) }
            if path.count == 2 && path[0] == "room" { return digits(path[1]) }
        }
        return nil
    }
}
