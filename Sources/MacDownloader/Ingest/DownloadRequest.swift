import Foundation

/// A download handed to the app from any entry point.
///
/// Every source (Add sheet, drag & drop, menu bar, the localhost bridge used by the Chromium
/// extension, and later a Native Messaging host or Safari Web Extension) builds one of these
/// and hands it to a `DownloadDispatching`. Validation and header hygiene live here, once.
struct DownloadRequest: Sendable, Equatable {
    enum Origin: String, Sendable, Codable {
        case manual, dragAndDrop, menuBar
        case browserExtension      // Chromium extension → localhost bridge (LocalServer)
        case nativeMessaging       // Chromium Native Messaging host (stdio JSON)
        case safariExtension       // Safari Web Extension handler
    }

    static let maxURLLength = 16 * 1024
    static let maxHeaderLength = 16 * 1024

    let url: URL
    var suggestedFilename: String?
    var referrer: String?
    var cookie: String?
    var userAgent: String?
    var origin: Origin
    var startImmediately = true

    /// Returns nil for anything that isn't a plausible http(s) download.
    init?(urlString: String, suggestedFilename: String? = nil, referrer: String? = nil,
          cookie: String? = nil, userAgent: String? = nil, origin: Origin, startImmediately: Bool = true) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxURLLength,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        self.url = url
        self.suggestedFilename = suggestedFilename
            .map { ($0 as NSString).lastPathComponent }   // never a path
            .flatMap { $0.isEmpty ? nil : $0 }
        self.referrer = Self.clean(referrer)
        self.cookie = Self.clean(cookie)
        self.userAgent = Self.clean(userAgent)
        self.origin = origin
        self.startImmediately = startImmediately
    }

    /// Request headers that reproduce the browser context (logged-in downloads, hotlink checks).
    var headers: [String: String] {
        var headers: [String: String] = [:]
        if let cookie { headers["Cookie"] = cookie }
        if let referrer { headers["Referer"] = referrer }
        if let userAgent { headers["User-Agent"] = userAgent }
        return headers
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = String(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty, stripped.count <= maxHeaderLength else { return nil }
        return stripped
    }
}

/// The single entry point into the download queue.
@MainActor
protocol DownloadDispatching: AnyObject {
    @discardableResult
    func enqueue(_ request: DownloadRequest) -> UUID?
}
