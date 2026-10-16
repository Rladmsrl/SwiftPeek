import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("本地诊断日志")
struct DiagnosticsTests {
    @Test("错误日志隐藏播放地址和鉴权参数")
    func redaction() {
        let text = LiveDiagnostics.redact("failed https://cdn.example/live.flv?wsAuth=secret&token=hidden sign=signature cookie=cookievalue tt=123 did=identifier")
        for secret in ["secret", "hidden", "signature", "cookievalue", "123", "identifier", "cdn.example"] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains("[URL]"))
        #expect(text.contains("sign=[redacted]"))
        #expect(LiveDiagnostics.redact(String(repeating: "x", count: 2000)).count == 1024)
    }

    @Test("轮转有上限且保持每行合法 JSON")
    func rotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DiagnosticWriter(directory: directory, maxBytes: 100, backups: 3)
        for i in 0..<50 { writer.append(["event": "heartbeat", "sequence": String(i)]) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 4)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.count <= 100)
            for line in data.split(separator: 0x0A) {
                let entry = try JSONSerialization.jsonObject(with: Data(line)) as? [String: String]
                #expect(entry?["event"] == "heartbeat")
            }
        }
        let current = try String(contentsOf: directory.appendingPathComponent("playback.log"), encoding: .utf8)
        #expect(current.contains("49"))
    }
}
