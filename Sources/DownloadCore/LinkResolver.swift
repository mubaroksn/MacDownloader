import Foundation

/// Turns "share" and "preview" links into links that return the file itself.
///
/// Two layers:
/// 1. `directURL(for:)`: pure URL rewrites for well-known hosts (no network).
/// 2. `interstitialTarget(html:pageURL:)`: when a server answers with an HTML page instead
///    of the file (Google Drive's "can't scan for viruses" page, MediaFire's landing page,
///    meta-refresh redirects), find the real download link inside that page.
public enum LinkResolver {
    // MARK: - URL rewrites

    public static func directURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = url.path
        let parts = path.split(separator: "/").map(String.init)

        // Google Drive: /file/d/<id>/view, /open?id=<id>, /uc?id=<id>
        if host == "drive.google.com" || host == "docs.google.com" && path.hasPrefix("/uc") {
            if let id = driveFileID(parts: parts, components: components) {
                return driveDownloadURL(id: id, resourceKey: queryValue("resourcekey", in: components))
            }
        }

        // Google Docs / Sheets / Slides → Office export.
        if host == "docs.google.com", parts.count >= 3, parts[1] == "d" {
            let id = parts[2]
            let format: String?
            switch parts[0] {
            case "document": format = "docx"
            case "spreadsheets": format = "xlsx"
            case "presentation": format = "pptx"
            default: format = nil
            }
            if let format, !path.contains("/export") {
                return URL(string: "https://docs.google.com/\(parts[0])/d/\(id)/export?format=\(format)")
            }
        }

        // Dropbox: force the file instead of the preview page.
        if host == "www.dropbox.com" || host == "dropbox.com" {
            if parts.first.map({ ["s", "scl", "sh"].contains($0) }) == true {
                setQuery("dl", "1", in: &components)
                return components.url
            }
        }

        // GitHub file view → raw file.
        if host == "github.com", parts.count >= 5, parts[2] == "blob" {
            let rest = parts[3...].joined(separator: "/")
            return URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(rest)")
        }

        // OneDrive for Business / SharePoint share links ("/:u:/g/…", "/:b:/s/…").
        if host.hasSuffix(".sharepoint.com"), parts.first.map({ $0.hasPrefix(":") && $0.hasSuffix(":") }) == true {
            setQuery("download", "1", in: &components)
            return components.url
        }

        // Pixeldrain viewer → API download.
        if host == "pixeldrain.com", parts.count >= 2, parts[0] == "u" {
            return URL(string: "https://pixeldrain.com/api/file/\(parts[1])?download")
        }

        return nil
    }

    static func driveFileID(parts: [String], components: URLComponents) -> String? {
        if let index = parts.firstIndex(of: "d"), parts.indices.contains(index + 1), parts.contains("file") {
            return parts[index + 1]
        }
        if let id = queryValue("id", in: components), !id.isEmpty { return id }
        return nil
    }

    static func driveDownloadURL(id: String, resourceKey: String?) -> URL? {
        var components = URLComponents(string: "https://drive.usercontent.google.com/download")!
        var items = [URLQueryItem(name: "id", value: id),
                     URLQueryItem(name: "export", value: "download"),
                     URLQueryItem(name: "confirm", value: "t")]
        if let resourceKey { items.append(URLQueryItem(name: "resourcekey", value: resourceKey)) }
        components.queryItems = items
        return components.url
    }

    // MARK: - Interstitial pages

    /// Finds the real file link inside an HTML page that stands between the user and the file.
    public static func interstitialTarget(html: String, pageURL: URL) -> URL? {
        // Google Drive virus-scan warning: <form id="download-form" action="…/download"> + hidden inputs.
        if let form = firstMatch(#"<form[^>]*id="download-form"[^>]*>([\s\S]*?)</form>"#, in: html, group: 0) {
            let action = firstMatch(#"action="([^"]+)""#, in: form, group: 1).map(decodeEntities)
                ?? "https://drive.usercontent.google.com/download"
            if let actionURL = URL(string: action, relativeTo: pageURL)?.absoluteURL,
               var components = URLComponents(url: actionURL, resolvingAgainstBaseURL: true) {
                var items: [URLQueryItem] = []
                for input in allMatches(#"<input[^>]*>"#, in: form) {
                    guard let name = firstMatch(#"name="([^"]+)""#, in: input, group: 1) else { continue }
                    let value = firstMatch(#"value="([^"]*)""#, in: input, group: 1).map(decodeEntities) ?? ""
                    items.append(URLQueryItem(name: name, value: value))
                }
                if !items.isEmpty { components.queryItems = items }
                if let url = components.url { return url }
            }
        }

        // Older Drive pages: a direct "confirm" link.
        if let href = firstMatch(#"href="(/uc\?export=download[^"]*confirm=[^"]+)""#, in: html, group: 1) {
            return URL(string: decodeEntities(href), relativeTo: pageURL)?.absoluteURL
        }

        // MediaFire landing page.
        if let href = firstMatch(#"href="(https?://download[0-9]*\.mediafire\.com/[^"]+)""#, in: html, group: 1) {
            return URL(string: decodeEntities(href))
        }

        // <meta http-equiv="refresh" content="0; url=…">
        if let target = firstMatch(#"<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["'][^"']*url=([^"'>]+)"#,
                                   in: html, group: 1) {
            return URL(string: decodeEntities(target.trimmingCharacters(in: .whitespaces)), relativeTo: pageURL)?.absoluteURL
        }
        return nil
    }

    // MARK: - Helpers

    static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    static func setQuery(_ name: String, _ value: String, in components: inout URLComponents) {
        var items = (components.queryItems ?? []).filter { $0.name != name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x3D;", with: "=")
            .replacingOccurrences(of: "&#61;", with: "=")
    }
}

/// Full resolution pipeline used before every transfer:
/// rewrite known share links → probe → if the server returned a web page, look for the real
/// link inside it (up to `maxHops`) → otherwise refuse instead of saving a web page as the file.
public enum DownloadResolver {
    public struct Resolved: Sendable {
        public var request: RemoteRequest
        public var resource: RemoteResource
    }

    public static func resolve(_ request: RemoteRequest, timeout: TimeInterval = 30,
                               maxAttempts: Int = 6, maxHops: Int = 3) async throws -> Resolved {
        var current = request
        if let direct = LinkResolver.directURL(for: current.url) { current.url = direct }

        for _ in 0...maxHops {
            let resource = try await ResourceProber.probe(current, timeout: timeout, maxAttempts: maxAttempts)
            guard resource.isHTML, !wantsHTML(current.url) else {
                return Resolved(request: current, resource: resource)
            }
            let html = try await fetchPage(RemoteRequest(url: resource.finalURL, headers: current.headers),
                                           timeout: timeout)
            guard let next = LinkResolver.interstitialTarget(html: html, pageURL: resource.finalURL)
                    ?? LinkResolver.directURL(for: resource.finalURL),
                  next != current.url else {
                throw DownloadEngineError.notAFile
            }
            current.url = next
        }
        throw DownloadEngineError.notAFile
    }

    /// The user explicitly asked for a web page file.
    static func wantsHTML(_ url: URL) -> Bool {
        ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// Reads up to 2 MB of an HTML page.
    static func fetchPage(_ request: RemoteRequest, timeout: TimeInterval) async throws -> String {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        HTTPHeaders.apply(request.headers, to: &urlRequest)
        let session = URLSession(configuration: .transferConfiguration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }
        let (bytes, _) = try await session.bytes(for: urlRequest)
        var data = Data()
        data.reserveCapacity(256 * 1024)
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes { // pages are small; byte iteration is fine here
            buffer.append(byte)
            if buffer.count == 64 * 1024 { data.append(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            if data.count > 2 << 20 { break }
        }
        data.append(contentsOf: buffer)
        bytes.task.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
