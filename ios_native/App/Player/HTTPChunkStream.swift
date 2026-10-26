import Foundation
import SimpleLiveKit

/// 分块 HTTP 流式接收器。
///
/// 不用 `URLSession.bytes(for:)`：它的 `AsyncBytes` 逐字节产出，
/// 每个字节都要过一次 async 调度。直播流是 Mbps 量级，逐字节迭代会把消费端拖死。
///
/// 背压：delegate 队列在未确认的分块达到上限时停住。URLSession 因此不再从
/// socket 读数据，内存不会跟着「解复用卡住」无限涨。取消时会放开这个等待，
/// 否则退出房间要干等到下一个包或空闲超时。
final class HTTPChunkStream: NSObject, @unchecked Sendable {
    private let diagnosticID: String
    private let connectionID = UUID().uuidString
    private let configuration: URLSessionConfiguration?
    init(diagnosticID: String = UUID().uuidString, configuration: URLSessionConfiguration? = nil) {
        self.diagnosticID = diagnosticID
        self.configuration = configuration
        super.init()
    }
    private let lock = NSLock()
    /// 解复用一次最多领先网络这么多块。块大小通常是几十 KB，总量停在数 MB。
    private let slots = HTTPStreamBackpressure(capacity: 64)

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var isCancelled = false
    private var didFinish = false

    /// 开始拉流。返回的流会在连接结束、出错或 `cancel()` 时终止。
    func start(request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            if self.isCancelled {
                self.lock.unlock()
                continuation.finish(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            self.lock.unlock()

            let configuration = self.configuration ?? URLSessionConfiguration.ephemeral
            // 直播不需要缓存，且缓存会无意义地占用磁盘
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            // 首字节 / 包间隔超时。连上之后数据是持续的，不设总时长上限
            configuration.timeoutIntervalForRequest = 15

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)

            self.lock.lock()
            if self.isCancelled {
                self.continuation = nil
                self.didFinish = true
                self.lock.unlock()
                session.invalidateAndCancel()
                continuation.finish(throwing: CancellationError())
                return
            }
            self.session = session
            self.task = task
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
            task.resume()
        }
    }

    /// 消费端已处理完这个分块，归还背压名额。取消后的迟到确认无副作用。
    func acknowledge() {
        slots.release()
    }

    /// 立刻停掉拉流。可从任意线程重复调用。
    func cancel() {
        lock.lock()
        if isCancelled, task == nil, session == nil, continuation == nil {
            lock.unlock()
            return
        }
        isCancelled = true
        let task = self.task
        let session = self.session
        let continuation = self.continuation
        let shouldFinish = !didFinish
        didFinish = true
        self.task = nil
        self.session = nil
        self.continuation = nil
        lock.unlock()

        // 取消会丢弃尚未被消费的分块，不能指望它们再 acknowledge。
        // 广播唤醒等待中的接收回调，不再用一次 signal 掩盖未归还的名额。
        slots.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        if shouldFinish {
            continuation?.finish(throwing: CancellationError())
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

extension HTTPChunkStream: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        LiveDiagnostics.record("stream.http", fields: ["player": diagnosticID, "connection": connectionID, "status": String(http.statusCode), "host": http.url?.host ?? "unknown"])
        guard (200..<300).contains(http.statusCode) else {
            finish(LiveHTTPError(status: http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard slots.acquire() else { return }
        lock.lock()
        guard !isCancelled, !didFinish, let continuation else {
            lock.unlock()
            slots.release()
            return
        }
        lock.unlock()
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            LiveDiagnostics.record("stream.transportError", fields: ["player": diagnosticID, "connection": connectionID, "domain": ns.domain, "code": String(ns.code)])
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                finish(CancellationError())
            } else {
                // 保留 URLError 本身，让上层按错误码翻译，而不是系统那句
                // 「未能完成操作。（NSURLErrorDomain错误-1005。）」
                finish(error)
            }
        } else {
            finish(nil)
        }
    }
}
