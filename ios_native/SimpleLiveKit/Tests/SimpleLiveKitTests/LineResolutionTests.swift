import Foundation
import Testing
@testable import SimpleLiveKit

@Suite("线路解析与弱网")
struct LineResolutionTests {
    @Test("首条线路返回后不再等待卡住的线路")
    func graceSkipsStalledLine() async {
        let clock = ContinuousClock()
        let started = clock.now
        let results = await DouyuSite.collectLines(count: 3, grace: .milliseconds(100)) { index in
            switch index {
            case 0: try await Task.sleep(for: .seconds(30)); return "slow"
            case 1: return "https://b/live.flv"
            default: try await Task.sleep(for: .milliseconds(20)); return "https://c/live.flv"
            }
        }
        #expect(clock.now - started < .seconds(5))
        #expect(results.map(\.index) == [1, 2])
    }

    @Test("全部失败时等到每条线路都有结果")
    func allFailuresAreCollected() async {
        struct Failure: Error {}
        let results = await DouyuSite.collectLines(count: 2, grace: .milliseconds(10)) { _ in throw Failure() }
        #expect(results.count == 2)
        #expect(results.allSatisfy { if case .failure = $0.outcome { true } else { false } })
    }

    @Test("部分线路的新地址按线路身份合并")
    func mergePartialLines() {
        let current = LivePlayURL(urls: ["https://a/old", "https://b/old", "https://c/old"], lineIDs: ["a", "b", "c"],
                                  headers: ["Referer": "old"])
        let fresh = LivePlayURL(urls: ["https://b/new", "https://d/new"], lineIDs: ["b", "d"], headers: ["Referer": "new"])
        let merged = current.merging(fresh)
        #expect(merged.lineIDs == ["a", "b", "c", "d"])
        #expect(merged.urls == ["https://a/old", "https://b/new", "https://c/old", "https://d/new"])
        #expect(merged.headers?["Referer"] == "new")
        let anonymous = LivePlayURL(urls: ["https://x/new"])
        #expect(current.merging(anonymous).urls == ["https://x/new"])
    }

    @Test("签名脚本缓存按时效淘汰")
    func signScriptCacheExpires() async {
        let cache = DouyuSignScriptCache()
        let now = Date()
        await cache.store("script", for: "1", now: now)
        #expect(await cache.script(for: "1", now: now.addingTimeInterval(60)) == "script")
        #expect(await cache.script(for: "1", now: now.addingTimeInterval(DouyuSignScriptCache.lifetime + 1)) == nil)
        #expect(await cache.script(for: "2", now: now) == nil)
    }
}
