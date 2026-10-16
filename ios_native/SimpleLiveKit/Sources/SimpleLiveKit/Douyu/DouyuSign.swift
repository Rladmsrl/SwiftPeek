import Foundation
import JavaScriptCore

/// 斗鱼取流签名。
///
/// 斗鱼把签名函数 `ub98484234` 以混淆 JS 的形式下发（`swf_api/homeH5Enc`），
/// 该函数依赖 CryptoJS。Dart 版靠 `dart_quickjs` 执行，需要额外编译 QuickJS；
/// iOS 直接用系统内置的 JavaScriptCore，无三方依赖。
public struct DouyuSign: Sendable {
    /// 与 Dart 版保持一致的固定设备号
    public static let defaultDeviceID = "10000000000000000000000000001501"

    private static let cryptoJSSource: String = {
        let bundle = Bundle.module
        let candidates = [
            bundle.url(forResource: "crypto-js", withExtension: "js", subdirectory: "Resources"),
            bundle.url(forResource: "crypto-js", withExtension: "js"),
        ]
        for case let url? in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
        return ""
    }()

    /// 执行签名。
    /// - Parameters:
    ///   - roomJS: `homeH5Enc` 下发的混淆脚本
    ///   - roomID: 房间号
    ///   - deviceID: 设备号
    ///   - timestamp: 秒级时间戳，测试时可注入固定值
    /// - Returns: 形如 `v=...&did=...&tt=...&sign=...` 的查询串
    public static func sign(
        roomJS: String,
        roomID: String,
        deviceID: String = defaultDeviceID,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) throws -> String {
        guard !cryptoJSSource.isEmpty else {
            throw LiveCoreError("CryptoJS 资源缺失，无法生成斗鱼签名")
        }
        guard let context = JSContext() else {
            throw LiveCoreError("无法创建 JavaScriptCore 上下文")
        }

        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "未知 JS 异常"
        }

        // CryptoJS 会探测 window / global / self，JavaScriptCore 默认没有这些全局对象
        context.evaluateScript(
            """
            var window = this;
            var global = this;
            var self = this;
            var navigator = { userAgent: "Mozilla/5.0" };
            var document = {};
            """
        )
        context.evaluateScript(cryptoJSSource)
        if let jsError { throw LiveCoreError("加载 CryptoJS 失败：\(jsError)") }

        context.evaluateScript(roomJS)
        if let jsError { throw LiveCoreError("加载斗鱼签名脚本失败：\(jsError)") }

        guard context.objectForKeyedSubscript("ub98484234")?.isObject == true else {
            throw LiveCoreError("斗鱼签名脚本未定义 ub98484234，接口可能已变更")
        }

        // 参数均为纯数字/十六进制串，无注入风险；仍做一次白名单校验
        let safeRoom = roomID.filter { $0.isNumber }
        let safeDevice = deviceID.filter { $0.isHexDigit }
        guard !safeRoom.isEmpty, !safeDevice.isEmpty else {
            throw LiveCoreError("房间号或设备号非法")
        }

        let call = "ub98484234('\(safeRoom)','\(safeDevice)','\(timestamp)')"
        let result = context.evaluateScript(call)
        if let jsError { throw LiveCoreError("执行斗鱼签名失败：\(jsError)") }

        guard let signArgs = result?.toString(), signArgs.contains("sign=") else {
            throw LiveCoreError("斗鱼签名结果异常：\(result?.toString() ?? "nil")")
        }
        return signArgs
    }
}
