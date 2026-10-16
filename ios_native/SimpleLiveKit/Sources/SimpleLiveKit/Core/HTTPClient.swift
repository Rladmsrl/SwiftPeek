import Foundation

/// 轻量 JSON 访问器。
///
/// Dart 版站点适配器大量依赖 `result["data"]["rl"]` 这类动态下标，
/// 直接改写成 Codable 会把 4 个站点几十种响应结构全部固化。
/// 这里保留动态取值的手感，但把「取不到」收敛成安全默认值，避免崩溃。
///
/// `@unchecked Sendable` 的依据：内部只承载 `JSONSerialization` 产出的
/// NSString / NSNumber / NSArray / NSDictionary / NSNull，解析完即只读，
/// 不对外暴露任何可变入口。
@dynamicMemberLookup
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) {
        self.raw = raw
    }

    public init(data: Data) throws {
        self.raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static let null = JSON(nil)

    // MARK: 下标

    public subscript(key: String) -> JSON {
        guard let dict = raw as? [String: Any] else { return .null }
        return JSON(dict[key])
    }

    public subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return .null }
        return JSON(array[index])
    }

    public subscript(dynamicMember member: String) -> JSON {
        self[member]
    }

    // MARK: 取值

    public var exists: Bool { raw != nil && !(raw is NSNull) }

    public var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// 取不到时返回空串，对应 Dart 的 `x.toString()` 习惯
    public var stringValue: String { string ?? "" }

    public var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String {
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
        }
        return nil
    }

    public var intValue: Int { int ?? 0 }

    public var bool: Bool? {
        if let b = raw as? Bool { return b }
        if let i = int { return i != 0 }
        return nil
    }

    public var array: [JSON] {
        guard let array = raw as? [Any] else { return [] }
        return array.map { JSON($0) }
    }

    public var dictionary: [String: JSON] {
        guard let dict = raw as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { $0[$1.key] = JSON($1.value) }
    }
}

// MARK: - 错误

public struct LiveCoreError: LocalizedError, Sendable {
    public let message: String
    public let statusCode: Int?

    public init(_ message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    public var errorDescription: String? {
        if let statusCode { return "\(message)（HTTP \(statusCode)）" }
        return message
    }
}

// MARK: - HTTP

public actor HTTPClient {
    public static let shared = HTTPClient()

    /// 斗鱼多个接口会校验 UA，桌面 Chrome UA 是 Dart 版实测可用的取值
    public static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43"

    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9"]
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(
        url: String,
        query: [String: String],
        headers: [String: String],
        method: String
    ) throws -> URLRequest {
        guard var components = URLComponents(string: url) else {
            throw LiveCoreError("非法请求地址：\(url)")
        }
        if !query.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
            components.queryItems = items
        }
        guard let finalURL = components.url else {
            throw LiveCoreError("无法拼接请求地址：\(url)")
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func perform(_ request: URLRequest, label: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LiveCoreError("\(label)请求失败", statusCode: http.statusCode)
            }
            return data
        } catch let error as LiveCoreError {
            throw error
        } catch {
            throw LiveCoreError("\(label)请求失败：\(error.localizedDescription)")
        }
    }

    public func getText(
        _ url: String,
        query: [String: String] = [:],
        headers: [String: String] = [:]
    ) async throws -> String {
        let request = try makeRequest(url: url, query: query, headers: headers, method: "GET")
        let data = try await perform(request, label: "GET")
        guard let text = String(data: data, encoding: .utf8) else {
            throw LiveCoreError("响应不是合法 UTF-8 文本")
        }
        return text
    }

    public func getJSON(
        _ url: String,
        query: [String: String] = [:],
        headers: [String: String] = [:]
    ) async throws -> JSON {
        let request = try makeRequest(url: url, query: query, headers: headers, method: "GET")
        let data = try await perform(request, label: "GET")
        do {
            return try JSON(data: data)
        } catch {
            throw LiveCoreError("响应不是合法 JSON：\(url)")
        }
    }

    /// 表单 POST。斗鱼 getH5Play 要求 application/x-www-form-urlencoded，
    /// 且 body 是签名函数直接产出的查询串，不能二次编码。
    public func postForm(
        _ url: String,
        body: String,
        headers: [String: String] = [:]
    ) async throws -> JSON {
        var request = try makeRequest(url: url, query: [:], headers: headers, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        let data = try await perform(request, label: "POST")
        do {
            return try JSON(data: data)
        } catch {
            throw LiveCoreError("响应不是合法 JSON：\(url)")
        }
    }
}
