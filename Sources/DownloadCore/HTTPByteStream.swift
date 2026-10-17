import Foundation

/// One HTTP request exposed as an `AsyncThrowingStream` of response + data chunks.
///
/// Why not `URLSession.bytes(for:)`? Its `AsyncBytes` sequence yields one `UInt8` per
/// iteration; at 100+ MB/s that is hundreds of millions of async iterations and a busy
/// core. The delegate API hands over `Data` chunks (usually 16-512 KB), which we
/// forward as-is: one write per chunk.
///
/// Backpressure: URLSession has none of its own in delegate mode. If the consumer
/// (disk) falls behind by `highWaterMark` bytes, the task is suspended, which lets the
/// TCP receive window fill and the server slow down, then resumed once drained.
final class HTTPByteStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: @unchecked Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>

    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let lock = NSLock()
    private var buffered = 0
    private var suspended = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(request: URLRequest, timeout: TimeInterval, highWaterMark: Int = 4 << 20) {
        var captured: AsyncThrowingStream<Event, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        self.highWaterMark = max(256 * 1024, highWaterMark)
        lowWaterMark = self.highWaterMark / 4
        super.init()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: .transferConfiguration(timeout: timeout),
                                 delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        task.resume()
    }

    /// Tells the stream the consumer has finished with `count` bytes (resumes a suspended task).
    func consumed(_ count: Int) {
        lock.lock()
        buffered -= count
        let shouldResume = suspended && buffered <= lowWaterMark
        if shouldResume { suspended = false }
        let task = self.task
        lock.unlock()
        if shouldResume { task?.resume() }
    }

    /// Stops the transfer and tears down the private session. Idempotent.
    func cancel() {
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel() // also breaks URLSession's strong reference to us
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: DownloadEngineError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffered += data.count
        let shouldSuspend = !suspended && buffered > highWaterMark
        if shouldSuspend { suspended = true }
        lock.unlock()
        if shouldSuspend { dataTask.suspend() }
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
