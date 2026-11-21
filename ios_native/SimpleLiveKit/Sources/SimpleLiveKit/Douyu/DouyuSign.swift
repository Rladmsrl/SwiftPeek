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

    private static let pool = SignContextPool()

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

        // 参数均为纯数字/十六进制串，无注入风险；仍做一次白名单校验
        let safeRoom = roomID.filter { $0.isNumber }
        let safeDevice = deviceID.filter { $0.isHexDigit }
        guard !safeRoom.isEmpty, !safeDevice.isEmpty else {
            throw LiveCoreError("房间号或设备号非法")
        }

        let context = try pool.borrow(cryptoJS: cryptoJSSource)
        var healthy = false
        defer {
            context.exceptionHandler = nil
            if healthy { pool.release(context) }
        }

        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "未知 JS 异常"
        }

        // 每次签名在独立闭包内求值，避免不同房间脚本的顶层变量互相污染，同时复用已加载好的 CryptoJS 上下文。
        let wrapped = """
        (function() {
            window.ub98484234 = undefined;
            \(roomJS)
            return typeof ub98484234 === 'function'
                ? ub98484234
                : (typeof window.ub98484234 === 'function' ? window.ub98484234 : null);
        })()
        """
        let fn = context.evaluateScript(wrapped)
        if let jsError { throw LiveCoreError("加载斗鱼签名脚本失败：\(jsError)") }

        guard let fn, !fn.isUndefined, !fn.isNull, fn.isObject else {
            throw LiveCoreError("斗鱼签名脚本未定义 ub98484234，接口可能已变更")
        }

        let result = fn.call(withArguments: [safeRoom, safeDevice, String(timestamp)])
        if let jsError { throw LiveCoreError("执行斗鱼签名失败：\(jsError)") }

        guard let signArgs = result?.toString(), signArgs.contains("sign=") else {
            throw LiveCoreError("斗鱼签名结果异常：\(result?.toString() ?? "nil")")
        }
        healthy = true
        return signArgs
    }
}

/// 复用已预热 CryptoJS 的 JSContext，避免每次进房、切画质或 4 分钟换流都冷启 JSC VM 并重解析 47 KB 脚本。
private final class SignContextPool: @unchecked Sendable {
    private let lock = NSLock()
    private var idle: [JSContext] = []
    private let maxIdle = 2

    func borrow(cryptoJS: String) throws -> JSContext {
        lock.lock()
        let cached = idle.popLast()
        lock.unlock()
        if let cached { return cached }

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
        context.evaluateScript(cryptoJS)
        context.exceptionHandler = nil
        if let jsError { throw LiveCoreError("加载 CryptoJS 失败：\(jsError)") }
        return context
    }

    func release(_ context: JSContext) {
        lock.lock()
        if idle.count < maxIdle { idle.append(context) }
        lock.unlock()
    }
}
