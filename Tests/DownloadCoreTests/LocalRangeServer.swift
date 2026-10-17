import Foundation
import Network

/// Minimal HTTP/1.1 file server on 127.0.0.1 for engine tests.
///
/// Serves deterministic content with optional Range support, per-connection rate limiting,
/// a cap on concurrent transfers (excess requests get 429), and a mutable ETag for
/// If-Range tests. One request per connection (`Connection: close`) so every range
/// request is its own TCP connection, which lets tests count real concurrency.
final class LocalRangeServer: @unchecked Sendable {
    struct Options {
        var supportsRanges = true
        var maxConcurrent: Int? = nil
        var bytesPerSecond: Int? = nil
        var etag: String? = "\"v1\""
        var contentDisposition: String? = nil
        /// Answer any request carrying a Range header with 403 (some WAFs do this).
        var rejectRanges = false
        /// path → HTML page served as text/html (interstitials, login walls).
        var pages: [String: String] = [:]
    }

    struct Stats {
        var requests = 0
        var bodyBytesSent = 0
        var throttled = 0
        var active = 0
        var peakActive = 0
    }

    let content: Data
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.range-server", attributes: .concurrent)
    private let lock = NSLock()
    private var options: Options
    private var stats = Stats()

    var url: URL { URL(string: "http://127.0.0.1:\(port)/files/sample.bin")! }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func setPage(_ path: String, _ html: String) { lock.sync { options.pages[path] = html } }

    init(size: Int, options: Options = Options()) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (i >> 9)) }
        content = Data(bytes)
        self.options = options

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func snapshot() -> Stats { lock.sync { stats } }
    func setETag(_ etag: String?) { lock.sync { options.etag = etag } }
    func setMaxConcurrent(_ value: Int?) { lock.sync { options.maxConcurrent = value } }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
                self.respond(connection, head: head)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let (opts, admitted) = lock.sync { () -> (Options, Bool) in
            stats.requests += 1
            if let cap = options.maxConcurrent, stats.active >= cap {
                stats.throttled += 1
                return (options, false)
            }
            stats.active += 1
            stats.peakActive = max(stats.peakActive, stats.active)
            return (options, true)
        }

        guard admitted else {
            sendHead(connection, status: "429 Too Many Requests", headers: ["Content-Length": "0", "Retry-After": "1"]) {
                connection.cancel()
            }
            return
        }

        let pagePath = path.components(separatedBy: "?").first ?? path
        if let html = opts.pages[pagePath] {
            let body = Data(html.utf8)
            sendHead(connection, status: "200 OK",
                     headers: ["Content-Type": "text/html; charset=utf-8", "Content-Length": "\(body.count)"]) { [weak self] in
                connection.send(content: body, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in
                    self?.lock.sync { self?.stats.active -= 1 }
                    connection.cancel()
                })
            }
            return
        }
        if opts.rejectRanges, headers["range"] != nil {
            sendHead(connection, status: "403 Forbidden", headers: ["Content-Length": "0"]) { [weak self] in
                self?.lock.sync { self?.stats.active -= 1 }
                connection.cancel()
            }
            return
        }

        let total = content.count
        var status = "200 OK"
        var range = 0..<total
        var responseHeaders: [String: String] = ["Content-Type": "application/octet-stream"]
        if let etag = opts.etag { responseHeaders["ETag"] = etag }
        if let disposition = opts.contentDisposition { responseHeaders["Content-Disposition"] = disposition }

        let ifRangeOK = headers["if-range"].map { $0 == opts.etag } ?? true
        if opts.supportsRanges {
            responseHeaders["Accept-Ranges"] = "bytes"
            if let spec = headers["range"], ifRangeOK, let parsed = Self.parse(range: spec, total: total) {
                guard let parsedRange = parsed else {
                    finish(connection, status: "416 Range Not Satisfiable",
                           headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0"], body: 0..<0, rate: nil)
                    return
                }
                status = "206 Partial Content"
                range = parsedRange
                responseHeaders["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
            }
        }
        responseHeaders["Content-Length"] = "\(range.count)"
        finish(connection, status: status, headers: responseHeaders, body: range, rate: opts.bytesPerSecond)
    }

    /// nil: no/unsupported range header. .some(nil): unsatisfiable. .some(range): bytes to send.
    static func parse(range spec: String, total: Int) -> Range<Int>?? {
        guard spec.hasPrefix("bytes="), !spec.contains(",") else { return nil }
        let parts = spec.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? (total - 1), total - 1)
        guard start < total, start <= end else { return .some(nil) }
        return .some(start..<(end + 1))
    }

    private func finish(_ connection: NWConnection, status: String, headers: [String: String],
                        body: Range<Int>, rate: Int?) {
        var released = false
        let release: () -> Void = { [weak self] in
            guard !released else { return }
            released = true
            self?.lock.sync { self?.stats.active -= 1 }
            connection.cancel()
        }
        sendHead(connection, status: status, headers: headers) { [weak self] in
            self?.sendBody(connection, remaining: body, rate: rate, done: release)
        }
    }

    private func sendHead(_ connection: NWConnection, status: String, headers: [String: String],
                          then next: @escaping () -> Void) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in next() })
    }

    private func sendBody(_ connection: NWConnection, remaining: Range<Int>, rate: Int?, done: @escaping () -> Void) {
        guard !remaining.isEmpty else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in done() })
            return
        }
        let chunkSize = 32 * 1024
        let chunk = remaining.lowerBound..<min(remaining.upperBound, remaining.lowerBound + chunkSize)
        connection.send(content: content.subdata(in: chunk), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { done(); return }
            self.lock.sync { self.stats.bodyBytesSent += chunk.count }
            let rest = chunk.upperBound..<remaining.upperBound
            if let rate, rate > 0 {
                let delay = Double(chunk.count) / Double(rate)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.sendBody(connection, remaining: rest, rate: rate, done: done)
                }
            } else {
                self.sendBody(connection, remaining: rest, rate: rate, done: done)
            }
        })
    }
}

extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
