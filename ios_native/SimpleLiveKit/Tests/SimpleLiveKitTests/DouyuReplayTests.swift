import Foundation
import Testing

@testable import SimpleLiveKit

@Suite("斗鱼录像")
struct DouyuReplayTests {

    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    // MARK: 链接

    @Test("识别录像链接与起播时间")
    func parseLink() {
        let link = DouyuReplayService.parseLink("https://v.douyu.com/show/2V0JMV10xa57RY5k?ap=1&t=2199&or=2")
        #expect(link?.hashID == "2V0JMV10xa57RY5k")
        #expect(link?.start == 2199)
        #expect(DouyuReplayService.parseLink(" https://vmobile.douyu.com/show/Bjq4MeKJJGQv5Ea8 ")?.start == nil)
        #expect(DouyuReplayService.parseLink("https://v.douyu.com/show/abc?t=0")?.hashID == nil)
        #expect(DouyuReplayService.parseLink("https://www.douyu.com/110") == nil)
        #expect(DouyuReplayService.parseLink("https://v.douyu.com/show/2V0J-MV10xa57") == nil)
        #expect(DouyuReplayService.parseLink("https://evil.com/show/2V0JMV10xa57RY5k") == nil)
    }

    @Test("时长文本转秒")
    func parseClock() {
        #expect(DouyuReplayService.parseClock("120:02") == 7202)
        #expect(DouyuReplayService.parseClock("02:00:02") == 7202)
        #expect(DouyuReplayService.parseClock("") == 0)
        #expect(DouyuReplayService.parseClock("1:xx") == 0)
    }

    // MARK: 页面

    private let page = """
    <html><head><script>document.body && (document.body.style.overflow="hidden");</script>
    <script>var vdwdae325w_64we = "220320261017";function ub98484234(a,b,c){return "v=1&did="+b+"&tt="+c+"&sign=x"+a}</script>
    <script>window.$DATA={AI_SUMMARY: 1,ROOM: {"vid":"2V0JMV10xa57RY5k","point_id":45589046,"author_name":"\\u4e3b\\u64ad","name":"\\u5f55\\u50cf {\\"\\u6807\\u9898\\"}","pic":"https:\\/\\/example.com\\/c.jpg","duration":7204.039,"up_id":"Y8bLA6W17May"},DATA:{content: {"room_id":110,"view_num":219,"danmu_num":5832,"start_time":1792146531,"cate2_name":"\\u5927\\u5bcc\\u7fc1","show_id":437440599,"authorIcon":"\\/\\/apic.example.com\\/a.jpg"},videoTag: {"tag1":{}}}}</script>
    </head></html>
    """

    @Test("从录像页解析信息")
    func parseDetail() throws {
        let detail = try DouyuReplayService.parseDetail(html: page)
        #expect(detail.hashID == "2V0JMV10xa57RY5k")
        #expect(detail.pointID == "45589046")
        #expect(detail.title == "录像 {\"标题\"}")
        #expect(detail.authorName == "主播")
        #expect(detail.duration == 7204.039)
        #expect(detail.upID == "Y8bLA6W17May")
        #expect(detail.roomID == "110")
        #expect(detail.danmakuCount == 5832)
        #expect(detail.categoryName == "大富翁")
        #expect(detail.authorAvatar == "https://apic.example.com/a.jpg")
        #expect(detail.recordedAt == Date(timeIntervalSince1970: 1792146531))
    }

    @Test("页面缺少数据时给出明确错误")
    func parseDetailFailure() {
        #expect(throws: LiveCoreError.self) { try DouyuReplayService.parseDetail(html: "<html></html>") }
        #expect(throws: LiveCoreError.self) {
            try DouyuReplayService.parseDetail(html: "<script>window.$DATA={ROOM: {\"vid\":\"bad\"}}</script>")
        }
    }

    @Test("截取对象时忽略字符串里的括号")
    func extractObject() {
        let text: Substring = #"x = {a: 1, ROOM: {"k":"}{\"","n":{"m":1}}, tail: {}}"#[...]
        #expect(DouyuReplayService.extractObject(in: text, after: "ROOM:") == #"{"k":"}{\"","n":{"m":1}}"#)
        #expect(DouyuReplayService.extractObject(in: "ROOM: {\"open\":1", after: "ROOM:") == nil)
    }

    @Test("找到内联签名脚本")
    func extractSignScript() {
        let script = DouyuReplayService.extractSignScript(html: page)
        #expect(script?.hasPrefix("var vdwdae325w_64we") == true)
        #expect(DouyuReplayService.extractSignScript(html: "<script>var a=1</script>") == nil)
    }

    @Test("用真实签名脚本对录像编号签名")
    func signWithPointID() throws {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "douyu_room_enc", withExtension: "js", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "douyu_room_enc", withExtension: "js")
        let script = try String(contentsOf: try #require(url), encoding: .utf8)
        let html = "<script src=\"a.js\"></script><script>\(script)</script>"
        let extracted = try #require(DouyuReplayService.extractSignScript(html: html))
        let args = try DouyuSign.sign(roomJS: extracted, roomID: "45589046", timestamp: 1_700_000_000)
        #expect(args.contains("tt=1700000000"))
        #expect(args.contains("sign="))
    }

    // MARK: 接口解析

    @Test("清晰度按码率从高到低，名称可读")
    func parseQualities() throws {
        let data = try json("""
        {"thumb_video":{"normal":{"bit_rate":2146167,"url":"http://a/normal.m3u8"},
        "1440p60a":{"bit_rate":9948104,"url":"http://a/1440.m3u8"},
        "high":{"bit_rate":3104744,"url":"http://a/high.m3u8"},
        "broken":{"bit_rate":1,"url":""}}}
        """)
        let qualities = DouyuReplayService.parseQualities(data)
        #expect(qualities.map(\.key) == ["1440p60a", "high", "normal"])
        #expect(qualities.map(\.name) == ["1440P60", "超清", "高清"])
        #expect(DouyuReplayService.qualityName("1080p60") == "1080P60")
    }

    @Test("弹幕窗口：排序、颜色与续取位置")
    func parseDanmaku() throws {
        let data = try json("""
        {"count":3,"start_time":3000,"end_time":9000,"list":[
          {"mid":"b","tl":9000,"ctt":"第二条","nn":"乙","col":2},
          {"mid":"a","tl":3000,"ctt":"第一条","nn":"甲","col":0},
          {"mid":"c","tl":5000,"ctt":"  ","nn":"丙","col":0}]}
        """)
        let batch = DouyuReplayService.parseDanmaku(data, requestedStart: 0)
        #expect(batch.items.map(\.id) == ["a", "b"])
        #expect(batch.items[0].offset == 3)
        #expect(batch.items[1].color == LiveMessageColor(30, 135, 240))
        #expect(batch.nextStart == 9000)
    }

    @Test("弹幕末尾窗口不再续取")
    func parseDanmakuEnd() throws {
        let end = try json(#"{"count":1,"end_time":-1,"list":[{"mid":"z","tl":7190000,"ctt":"完","nn":"丁"}]}"#)
        #expect(DouyuReplayService.parseDanmaku(end, requestedStart: 7_100_000).nextStart == nil)
        // 服务端返回的终点没有前进时也要停止，避免死循环
        let stuck = try json(#"{"end_time":5000,"list":[{"mid":"y","tl":5000,"ctt":"卡","nn":"戊"}]}"#)
        #expect(DouyuReplayService.parseDanmaku(stuck, requestedStart: 5000).nextStart == nil)
        #expect(DouyuReplayService.parseDanmaku(try json(#"{"list":[]}"#), requestedStart: 0).nextStart == nil)
    }

    @Test("章节只保留与当前分段有交集的部分")
    func parseChapters() throws {
        let data = try json("""
        [{"mainTag":"综艺","list":[
           {"firstId":1,"firstTitle":"上一段开始","startVidHash":"prevPrevHash1","startSecond":4644,"endVidHash":"currentHash1","endSecond":1076},
           {"firstId":2,"firstTitle":"本段中间","describe":"摘要","startVidHash":"currentHash1","startSecond":1076,"endVidHash":"currentHash1","endSecond":2199}]},
         {"mainTag":"游戏","list":[
           {"firstId":3,"firstTitle":"跨到下一段","startVidHash":"currentHash1","startSecond":6013,"endVidHash":"nextNextHash1","endSecond":1325},
           {"firstId":4,"firstTitle":"无关","startVidHash":"otherOtherHash","startSecond":1,"endVidHash":"otherOtherHash","endSecond":9}]}]
        """)
        let chapters = DouyuReplayService.parseChapters(data, hashID: "currentHash1")
        #expect(chapters.map(\.id) == ["1", "2", "3"])
        #expect(chapters[0].start == 0)
        #expect(chapters[0].isContinued)
        #expect(chapters[1].summary == "摘要")
        #expect(chapters[2].tag == "游戏")
    }

    @Test("录像列表按场次解析并计算是否有更多")
    func parseReplayPage() throws {
        let data = try json("""
        {"count":12,"list":[{"show_id":1,"title":"标题","time":"2026-10-16 12点场","date_format":"昨天",
          "time_format":"12:28","replay_duration":"10:00:13","re_num":5,
          "video_list":[{"hash_id":"Bjq4MeKJJGQv5Ea8","point_id":45588035,"title":"第一段","video_pic":"https://example.com/p.jpg",
            "start_time":1792124925,"view_num":"329","video_str_duration":"120:02","video_duration":0}]},
          {"show_id":2,"video_list":[]}]}
        """)
        let page = DouyuReplayService.parseReplayPage(data, page: 1, pageSize: 10)
        #expect(page.hasMore)
        #expect(page.shows.count == 1)
        let show = try #require(page.shows.first)
        #expect(show.partCount == 5)
        #expect(show.videos.first?.duration == 7202)
        #expect(show.videos.first?.viewCount == 329)
        #expect(DouyuReplayService.parseReplayPage(data, page: 2, pageSize: 10).hasMore == false)
    }

    @Test("从房间信息取录像作者")
    func parseAuthor() throws {
        let room = try json(#"{"room_id":110,"up_id":"Y8bLA6W17May","owner_name":"主播","owner_avatar":"https://example.com/a.jpg"}"#)
        let author = try DouyuReplayService.parseAuthor(room, roomID: "xie")
        #expect(author.upID == "Y8bLA6W17May")
        #expect(author.roomID == "110")
        #expect(author.name == "主播")
        #expect(throws: LiveCoreError.self) { try DouyuReplayService.parseAuthor(try json(#"{"up_id":""}"#), roomID: "1") }
    }

    @Test("同场分段按序号排列")
    func parseSegments() throws {
        let data = try json("""
        {"list":[{"rank":2,"hash_id":"6Aw87Og66rd7YGkg","vid":2,"show_remark":"14点场","video_duration":"02:00:00"},
                 {"rank":1,"hash_id":"Bjq4MeKJJGQv5Ea8","vid":1,"show_remark":"12点场","video_duration":"02:00:02"},
                 {"rank":3,"hash_id":"bad"}]}
        """)
        let segments = DouyuReplayService.parseSegments(data)
        #expect(segments.map(\.title) == ["12点场", "14点场"])
        #expect(segments[0].duration == 7202)
        #expect(segments[1].pointID == "2")
    }
}
