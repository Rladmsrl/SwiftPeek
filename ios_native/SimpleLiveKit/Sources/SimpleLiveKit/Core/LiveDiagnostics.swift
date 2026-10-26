import Foundation

/// Local JSON-lines diagnostics. No stream URLs, signatures, cookies or chat content.
/// One serial writer, at most 4 x 2 MiB, independent of the playback thread.
public enum LiveDiagnostics {
    public static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SimpleLive", isDirectory: true)
    private static let queue = DispatchQueue(label: "com.simplelive.diagnostics", qos: .utility)
    private static let run = UUID().uuidString
    private static let writer = DiagnosticWriter(directory: directory)
    // Accessed only on queue. Opt in for each installation; never log before settings load.
    private static var enabled = false

    public static func setEnabled(_ value: Bool) {
        queue.sync {
            enabled = value && ProcessInfo.processInfo.environment["SIMPLELIVE_DISABLE_DIAGNOSTICS"] != "1"
        }
    }

    public static func clear() throws {
        try queue.sync { try writer.clear() }
    }

    public static func record(_ event: String, roomID: String? = nil, fields: [String: String] = [:]) {
        let timestamp = Date()
        queue.async {
            guard enabled else { return }
            var entry = fields.mapValues { redact($0) }
            entry["event"] = redact(event)
            entry["time"] = timestamp.ISO8601Format()
            entry["run"] = run
            entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            if let roomID { entry["room"] = redact(roomID) }
            writer.append(entry)
        }
    }

    public static func flush() { queue.sync {} }

    static func redact(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"(?i)https?://[^\s\"<>]+"#, with: "[URL]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(sign|wsAuth|token|cookie|authorization|did|tt)\s*[=:]\s*[^\s&,;]+"#, with: "$1=[redacted]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"/(?:Users|home)/[^\s\"<>]+"#, with: "[LOCAL_PATH]", options: .regularExpression)
        return String(text.prefix(1024))
    }
}

final class DiagnosticWriter {
    private let directory: URL
    private let maxBytes: Int
    private let backups: Int
    private var bytes = 0
    private var initialized = false

    init(directory: URL, maxBytes: Int = 2 * 1024 * 1024, backups: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.backups = max(1, backups)
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "playback.log" : "playback.\(index).log")
    }

    func clear() throws {
        let manager = FileManager.default
        for index in 0...backups where manager.fileExists(atPath: file(index).path) {
            try manager.removeItem(at: file(index))
        }
        bytes = 0
        initialized = false
    }

    func append(_ entry: [String: String]) {
        do {
            let manager = FileManager.default
            if !initialized {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                bytes = (try? manager.attributesOfItem(atPath: file(0).path)[.size] as? Int) ?? 0
                initialized = true
            }
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            if bytes + data.count > maxBytes {
                for index in stride(from: backups, through: 1, by: -1) {
                    if manager.fileExists(atPath: file(index).path) { try manager.removeItem(at: file(index)) }
                    if manager.fileExists(atPath: file(index - 1).path) {
                        try manager.moveItem(at: file(index - 1), to: file(index))
                    }
                }
                bytes = 0
            }
            if !manager.fileExists(atPath: file(0).path) {
                manager.createFile(atPath: file(0).path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file(0))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            bytes += data.count
        } catch {
            // Diagnostics must never interrupt playback (e.g. disk full).
        }
    }
}
