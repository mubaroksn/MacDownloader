import AppKit
import Foundation
import Network

/// Tiny HTTP server on 127.0.0.1 that the browser extension uses to hand over downloads.
///
/// Only requests carrying the `X-MacDL-Client` header are accepted. A normal web page can't
/// send a custom header to another origin without a CORS preflight, which this server never
/// approves, so random websites can't push downloads into the app.
final class LocalServer {
    static let shared = LocalServer()
    static let port: UInt16 = 9614

    private(set) var isRunning = false
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
                case .ready: self?.isRunning = true
                case .failed, .cancelled: self?.isRunning = false
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
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
            send(conn, status: "200 OK", json: ["ok": true, "app": "MacDownloader", "version": 1])
        case ("POST", "/add"):
            guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let url = obj["url"] as? String else {
                send(conn, status: "400 Bad Request", json: ["ok": false, "error": "url wajib diisi"])
                return
            }
            var headers: [String: String] = [:]
            if let cookie = obj["cookie"] as? String, !cookie.isEmpty { headers["Cookie"] = cookie }
            if let referrer = obj["referrer"] as? String, !referrer.isEmpty { headers["Referer"] = referrer }
            if let ua = obj["userAgent"] as? String, !ua.isEmpty { headers["User-Agent"] = ua }
            let name = (obj["filename"] as? String).map { ($0 as NSString).lastPathComponent }
            Task { @MainActor in
                DownloadManager.shared.add(urlString: url, fileName: name, headers: headers)
                NSApp.activate(ignoringOtherApps: true)
            }
            send(conn, status: "200 OK", json: ["ok": true])
        default:
            send(conn, status: "404 Not Found", json: ["ok": false])
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
