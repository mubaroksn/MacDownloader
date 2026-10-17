import Foundation

let defaultUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

struct ProbeResult {
    var finalURL: URL
    var totalBytes: Int64
    var supportsRanges: Bool
    var suggestedName: String?
}

enum DownloadError: LocalizedError {
    case http(Int)
    case badResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Server membalas HTTP \(code)"
        case .badResponse: return "Respons server tidak valid"
        case .message(let text): return text
        }
    }
}

func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
    for (key, value) in headers where !value.isEmpty {
        request.setValue(value, forHTTPHeaderField: key)
    }
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
    }
}

/// Probes with retries, since busy servers sometimes answer 429/503 or drop the first request.
func probe(url: URL, headers: [String: String]) async throws -> ProbeResult {
    var attempt = 0
    while true {
        do {
            return try await probeOnce(url: url, headers: headers)
        } catch DownloadError.http(let code) where (code == 429 || code == 503) && attempt < 4 {
            attempt += 1
        } catch let error as URLError where attempt < 3 {
            if error.code == .cancelled { throw error }
            attempt += 1
        }
        try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
    }
}

/// Asks the server for byte 0 only, to learn the size, whether ranges work and the file name.
private func probeOnce(url: URL, headers: [String: String]) async throws -> ProbeResult {
    var request = URLRequest(url: url, timeoutInterval: 30)
    applyHeaders(headers, to: &request)
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    bytes.task.cancel()
    guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
    guard (200..<300).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }

    var total: Int64 = http.expectedContentLength
    var ranges = false
    if http.statusCode == 206,
       let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
       let slash = contentRange.lastIndex(of: "/"),
       let size = Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
        total = size
        ranges = true
    }
    var name = http.suggestedFilename
    if name == "Unknown" || name?.isEmpty == true { name = nil }
    return ProbeResult(finalURL: http.url ?? url, totalBytes: total, supportsRanges: ranges, suggestedName: name)
}

/// Splits a file into segments, downloads them over parallel connections into part files,
/// and keeps idle connections busy by splitting the largest remaining segment (like IDM).
final class SegmentedDownloader: NSObject, URLSessionDataDelegate {
    enum Outcome {
        case finished([SegmentState])
        case paused([SegmentState])
        case failed(String, [SegmentState])
    }

    static let minSplitBytes: Int64 = 1_048_576

    let url: URL
    let headers: [String: String]
    let partsDir: URL
    let supportsRanges: Bool
    let maxConnections: Int
    var onFinish: ((Outcome) -> Void)?

    private let lock = NSLock()
    private var segments: [SegmentState]
    private let queue: OperationQueue
    private var session: URLSession!
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var taskSegment: [Int: Int64] = [:]   // task id -> segment start
    private var handles: [Int: FileHandle] = [:]
    private var retries: [Int64: Int] = [:]
    private var stopping = false
    private var failure: String?
    private var lastStatus: Int?
    /// Lowered when the server pushes back (HTTP 429/503) so we use fewer parallel connections.
    private var connectionLimit: Int
    private var throttled = Set<Int>()        // task ids rejected with 429/503
    private var retrying = Set<Int64>()       // segment starts waiting for a retry
    private var ended = false

    init(url: URL, headers: [String: String], partsDir: URL, supportsRanges: Bool,
         segments: [SegmentState], maxConnections: Int) {
        self.url = url
        self.headers = headers
        self.partsDir = partsDir
        self.supportsRanges = supportsRanges
        self.segments = segments
        self.maxConnections = max(1, maxConnections)
        connectionLimit = max(1, maxConnections)
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        super.init()
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    static func partURL(in dir: URL, start: Int64) -> URL {
        dir.appendingPathComponent("seg-\(start).part")
    }

    /// Plans the initial segments for a fresh download.
    static func plan(total: Int64, supportsRanges: Bool, connections: Int) -> [SegmentState] {
        guard supportsRanges, total > minSplitBytes else {
            return [SegmentState(start: 0, end: total > 0 ? total - 1 : -1, downloaded: 0)]
        }
        let count = Int64(max(1, min(Int64(connections), total / (512 * 1024))))
        let size = total / count
        return (0..<count).map { i in
            let start = i * size
            let end = i == count - 1 ? total - 1 : start + size - 1
            return SegmentState(start: start, end: end, downloaded: 0)
        }
    }

    var snapshot: (downloaded: Int64, connections: Int) {
        lock.lock(); defer { lock.unlock() }
        return (segments.reduce(0) { $0 + $1.downloaded }, tasks.count)
    }

    var currentSegments: [SegmentState] {
        lock.lock(); defer { lock.unlock() }
        return segments.sorted { $0.start < $1.start }
    }

    func start() {
        queue.addOperation { [self] in
            try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
            reconcileWithDisk()
            if segments.allSatisfy(\.isDone) { finish(); return }
            launchPending()
            if supportsRanges { fillIdleConnections() }
        }
    }

    func pause() {
        queue.addOperation { [self] in
            guard !ended else { return }
            stopping = true
            if tasks.isEmpty { finish() } else { tasks.values.forEach { $0.cancel() } }
        }
    }

    // MARK: - Internals (run on `queue`)

    private func index(of start: Int64) -> Int? { segments.firstIndex { $0.start == start } }

    private func reconcileWithDisk() {
        lock.lock(); defer { lock.unlock() }
        for i in segments.indices {
            let path = Self.partURL(in: partsDir, start: segments[i].start).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if !supportsRanges {
                // Server can't resume: start over.
                try? FileManager.default.removeItem(atPath: path)
                segments[i].downloaded = 0
            } else {
                segments[i].downloaded = segments[i].length >= 0 ? min(size, segments[i].length) : size
            }
        }
    }

    private func launch(start: Int64) {
        guard !stopping, let i = index(of: start) else { return }
        let seg = segments[i]
        let part = Self.partURL(in: partsDir, start: seg.start)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: part) else {
            fail("Tidak bisa menulis file sementara")
            return
        }
        if supportsRanges {
            try? handle.truncate(atOffset: UInt64(seg.downloaded))
            _ = try? handle.seekToEnd()
        } else {
            try? handle.truncate(atOffset: 0)
            lock.lock()
            segments[i].downloaded = 0
            lock.unlock()
        }

        var request = URLRequest(url: url)
        applyHeaders(headers, to: &request)
        if supportsRanges {
            let from = seg.start + seg.downloaded
            request.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        lock.lock()
        tasks[task.taskIdentifier] = task
        lock.unlock()
        taskSegment[task.taskIdentifier] = seg.start
        handles[task.taskIdentifier] = handle
        task.resume()
    }

    /// Starts segments that are unfinished and have no connection yet.
    private func launchPending() {
        let active = Set(taskSegment.values)
        for seg in segments where !seg.isDone && !active.contains(seg.start) && !retrying.contains(seg.start)
            && tasks.count < connectionLimit {
            launch(start: seg.start)
        }
    }

    /// Splits the segment with the most bytes left so every connection stays busy.
    private func fillIdleConnections() {
        while !stopping && tasks.count < connectionLimit {
            let active = Set(taskSegment.values)
            guard let i = segments.indices
                .filter({ active.contains(segments[$0].start) })
                .max(by: { remaining(segments[$0]) < remaining(segments[$1]) }) else { return }
            let left = remaining(segments[i])
            guard left > Self.minSplitBytes * 2 else { return }
            let from = segments[i].start + segments[i].downloaded
            let mid = from + left / 2
            let newSeg = SegmentState(start: mid, end: segments[i].end, downloaded: 0)
            lock.lock()
            segments[i].end = mid - 1
            segments.append(newSeg)
            lock.unlock()
            try? FileManager.default.removeItem(at: Self.partURL(in: partsDir, start: mid))
            launch(start: mid)
        }
    }

    private func remaining(_ seg: SegmentState) -> Int64 { seg.length < 0 ? 0 : seg.length - seg.downloaded }

    private func fail(_ message: String) {
        failure = message
        stopping = true
        if tasks.isEmpty { finish() } else { tasks.values.forEach { $0.cancel() } }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        session.finishTasksAndInvalidate()
        lock.lock()
        let segs = segments.sorted { $0.start < $1.start }
        lock.unlock()
        let outcome: Outcome
        if let failure {
            outcome = .failed(failure, segs)
        } else if segs.allSatisfy(\.isDone) {
            outcome = .finished(segs)
        } else {
            outcome = .paused(segs)
        }
        let callback = onFinish
        DispatchQueue.main.async { callback?(outcome) }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let expected = supportsRanges ? 206 : 200
        if http.statusCode == expected || (!supportsRanges && (200..<300).contains(http.statusCode)) {
            completionHandler(.allow)
        } else {
            lastStatus = http.statusCode
            if http.statusCode == 429 || http.statusCode == 503 { throttled.insert(dataTask.taskIdentifier) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard let start = taskSegment[id], let i = index(of: start), let handle = handles[id] else { return }
        var chunk = data
        let seg = segments[i]
        if seg.length >= 0 {
            let left = seg.length - seg.downloaded
            if left <= 0 { dataTask.cancel(); return }
            if Int64(chunk.count) > left { chunk = chunk.prefix(Int(left)) }
        }
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            fail("Gagal menulis ke disk: \(error.localizedDescription)")
            return
        }
        retries[start] = 0
        lock.lock()
        segments[i].downloaded += Int64(chunk.count)
        let done = segments[i].isDone
        lock.unlock()
        if done { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        try? handles[id]?.close()
        handles[id] = nil
        let start = taskSegment.removeValue(forKey: id)
        lock.lock()
        tasks[id] = nil
        lock.unlock()

        if stopping {
            if tasks.isEmpty { finish() }
            return
        }
        guard let start, let i = index(of: start) else { return }

        // Unknown-size download ended cleanly: its length is whatever we received.
        if error == nil && segments[i].end < 0 {
            lock.lock()
            segments[i].end = segments[i].start + segments[i].downloaded - 1
            lock.unlock()
        }

        if segments[i].isDone {
            if segments.allSatisfy(\.isDone) && tasks.isEmpty {
                finish()
            } else {
                launchPending()
                if supportsRanges { fillIdleConnections() }
            }
            return
        }

        // Server says "too many connections": drop this connection and keep going with the others.
        // The segment is picked up again when another connection frees up.
        if throttled.remove(id) != nil && !tasks.isEmpty {
            connectionLimit = max(1, tasks.count)
            return
        }

        // Incomplete: retry with backoff.
        let attempt = retries[start, default: 0] + 1
        retries[start] = attempt
        if attempt > 6 {
            let reason = lastStatus.map { "Server membalas HTTP \($0)" }
                ?? (error as NSError?)?.localizedDescription ?? "Koneksi terputus"
            fail(reason)
            return
        }
        let throttledNow = lastStatus == 429 || lastStatus == 503
        let delay = min(throttledNow ? 20.0 : 10.0, Double(attempt) * (throttledNow ? 3 : 1.5))
        retrying.insert(start)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.queue.addOperation {
                guard let self else { return }
                self.retrying.remove(start)
                guard !self.stopping, !self.taskSegment.values.contains(start) else { return }
                self.launch(start: start)
            }
        }
    }

    // MARK: - Merge

    /// Joins the part files in order into the final destination, then removes the parts.
    static func merge(segments: [SegmentState], partsDir: URL, into destination: URL) throws {
        let fm = FileManager.default
        let sorted = segments.sorted { $0.start < $1.start }
        if sorted.count == 1 {
            let part = partURL(in: partsDir, start: sorted[0].start)
            try fm.moveItem(at: part, to: destination)
        } else {
            fm.createFile(atPath: destination.path, contents: nil)
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            for seg in sorted {
                let input = try FileHandle(forReadingFrom: partURL(in: partsDir, start: seg.start))
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 8 * 1_048_576), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
            }
        }
        try? fm.removeItem(at: partsDir)
    }
}
