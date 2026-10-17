import AppKit
import Combine
import DownloadCore
import Foundation
import Network

/// Tiny HTTP server on 127.0.0.1 that the browser extension uses to hand over downloads.
///
/// Only requests carrying the `X-MacDL-Client` header are accepted. A normal web page can't
/// send a custom header to another origin without a CORS preflight, which this server never
/// approves, so random websites can't push downloads into the app.
final class LocalServer: ObservableObject {
    static let shared = LocalServer()
    static let port: UInt16 = 9614

    /// Where accepted requests go. Set once at launch; the server never touches the queue directly.
    @MainActor weak var dispatcher: DownloadDispatching?

    @Published private(set) var isRunning = false
    /// True only while the browser extension keeps sending its heartbeat (every 30 s).
    @Published private(set) var extensionConnected = false
    @Published private(set) var extensionBrowser: String?
    private var staleWork: DispatchWorkItem?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "macdl.server")

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: DispatchQueue.main.async { self?.isRunning = true }
                case .failed, .cancelled: DispatchQueue.main.async { self?.isRunning = false }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 1_000_000 { conn.cancel(); return }

            if let request = HTTPRequest(buffer) {
                if request.body.count >= request.contentLength {
                    self.respond(conn, to: request)
                    return
                }
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buffer)
        }
    }

    private func respond(_ conn: NWConnection, to request: HTTPRequest) {
        let origin = request.headers["origin"] ?? ""
        let fromExtension = origin.isEmpty || origin.hasPrefix("chrome-extension://")
            || origin.hasPrefix("moz-extension://") || origin.hasPrefix("safari-web-extension://")
        guard request.headers["x-macdl-client"] != nil, fromExtension else {
            send(conn, status: "403 Forbidden", json: ["ok": false])
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/ping"):
            send(conn, status: "200 OK", json: ["ok": true, "app": "MacDownloader", "version": 2])
        case ("POST", "/hello"):
            let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            markExtensionSeen(browser: obj?["browser"] as? String)
            send(conn, status: "200 OK", json: ["ok": true, "app": "MacDownloader", "version": 2])
        case ("POST", "/add"):
            guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let url = obj["url"] as? String else {
                send(conn, status: "400 Bad Request", json: ["ok": false, "error": "url wajib diisi"])
                return
            }
            let filename = (obj["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let download = DownloadRequest(urlString: url,
                                                 suggestedFilename: filename,
                                                 referrer: obj["referrer"] as? String,
                                                 cookie: obj["cookie"] as? String,
                                                 userAgent: obj["userAgent"] as? String,
                                                 origin: .browserExtension) else {
                send(conn, status: "400 Bad Request", json: ["ok": false, "error": "url tidak valid"])
                return
            }
            guard obj["handoff"] as? Bool == true else {
                // Legacy extension: accept without checking.
                Task { @MainActor [weak self] in self?.dispatcher?.enqueue(download) }
                send(conn, status: "200 OK", json: ["ok": true])
                return
            }
            if DriveFolder.folderID(from: download.url) != nil {
                Task { @MainActor [weak self] in _ = self?.dispatcher?.enqueue(download) }
                send(conn, status: "200 OK", json: ["ok": true, "accepted": true])
                return
            }
            // Hand-off: the browser has paused its own download and waits for our answer.
            // Accept only if we can actually fetch a file; otherwise the browser resumes it.
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await DownloadResolver.resolve(RemoteRequest(url: download.url, headers: download.headers),
                                                           timeout: 12, maxAttempts: 2)
                    await MainActor.run { _ = self.dispatcher?.enqueue(download) }
                    self.send(conn, status: "200 OK", json: ["ok": true, "accepted": true])
                } catch {
                    self.send(conn, status: "200 OK",
                              json: ["ok": true, "accepted": false, "reason": error.localizedDescription])
                }
            }
        default:
            send(conn, status: "404 Not Found", json: ["ok": false])
        }
    }

    private func markExtensionSeen(browser: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let browser, !browser.isEmpty { self.extensionBrowser = browser }
            if !self.extensionConnected { self.extensionConnected = true }
            self.staleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.extensionConnected = false }
            self.staleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
        }
    }

    private func send(_ conn: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var contentLength: Int

    init?(_ data: Data) {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1]).components(separatedBy: "?").first ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = Data(data[range.upperBound...])
        contentLength = Int(headers["content-length"] ?? "0") ?? 0
    }
}
