import Foundation

/// Lists a *public* Google Drive folder ("anyone with the link") without an API key.
///
/// Drive's folder page embeds its first page of entries as a JS-escaped JSON string:
///
///     window['_DRIVE_ivd'] = '\x5b\x5b\x5b\x22<id>\x22,\x5b\x22<parent>\x22\x5d,\x22<name>\x22,\x22<mime>\x22,…'
///
/// Row layout (verified against live pages, Oct 2026): [0] id, [1] parents, [2] name,
/// [3] MIME type, [13] size in bytes. Sub-folders are listed recursively; Google Docs,
/// Sheets and Slides are exported as Office files. The legacy `embeddedfolderview` endpoint
/// now only returns a storage-access interstitial, so it isn't used.
public enum DriveFolder {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let name: String
        public let mimeType: String
        public let size: Int64?

        public var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    }

    public struct Listing: Sendable, Equatable {
        public let title: String?
        public let entries: [Entry]
        /// Drive only embeds the first page; a non-null page token means there is more.
        public let truncated: Bool
    }

    public struct File: Sendable, Equatable {
        public let url: URL
        public let name: String
        /// Path inside the shared folder, e.g. "Laporan/2026" ("" for the top level).
        public let relativeDirectory: String
        public let size: Int64?
    }

    public struct Contents: Sendable {
        public let title: String
        public let files: [File]
        public let truncated: Bool
    }

    // MARK: - Links

    /// "https://drive.google.com/drive/folders/<id>", "/drive/u/0/folders/<id>?usp=sharing", …
    public static func folderID(from url: URL) -> String? {
        guard url.host?.lowercased() == "drive.google.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "folders"), parts.indices.contains(index + 1) else { return nil }
        let id = parts[index + 1]
        return id.isEmpty ? nil : id
    }

    public static func folderPageURL(_ id: String) -> URL {
        URL(string: "https://drive.google.com/drive/folders/\(id)")!
    }

    /// Where to fetch an entry from, and the name to save it under. Nil for things that
    /// can't be downloaded as files (Forms, Sites, shortcuts, …).
    static func download(for entry: Entry) -> (url: URL, name: String)? {
        let exports: [String: (String, String)] = [
            "application/vnd.google-apps.document": ("document", "docx"),
            "application/vnd.google-apps.spreadsheet": ("spreadsheets", "xlsx"),
            "application/vnd.google-apps.presentation": ("presentation", "pptx"),
        ]
        if let (kind, ext) = exports[entry.mimeType] {
            let name = entry.name.lowercased().hasSuffix(".\(ext)") ? entry.name : "\(entry.name).\(ext)"
            return URL(string: "https://docs.google.com/\(kind)/d/\(entry.id)/export?format=\(ext)").map { ($0, name) }
        }
        guard !entry.mimeType.hasPrefix("application/vnd.google-apps.") else { return nil }
        return LinkResolver.driveDownloadURL(id: entry.id, resourceKey: nil).map { ($0, entry.name) }
    }

    // MARK: - Parsing

    public static func parseListing(html: String) throws -> Listing {
        guard let raw = LinkResolver.firstMatch(#"window\['_DRIVE_ivd'\]\s*=\s*'((?:[^'\\]|\\.)*)'"#, in: html, group: 1) else {
            throw DownloadEngineError.folderNotAccessible
        }
        let json = unescapeJavaScript(raw)
        guard let top = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            throw DownloadEngineError.invalidResponse
        }
        let rows = (top.first as? [Any]) ?? []
        let entries: [Entry] = rows.compactMap { row in
            guard let fields = row as? [Any], fields.count > 3,
                  let id = fields[0] as? String, let name = fields[2] as? String,
                  let mime = fields[3] as? String else { return nil }
            let size = fields.count > 13 ? (fields[13] as? NSNumber)?.int64Value : nil
            return Entry(id: id, name: name, mimeType: mime, size: size)
        }
        let token = top.count > 1 ? top[1] : nil
        let truncated = token is String

        var title = LinkResolver.firstMatch(#"<title>([^<]*)</title>"#, in: html, group: 1).map(LinkResolver.decodeEntities)
        if let t = title, let range = t.range(of: " - Google Drive", options: .backwards) {
            title = String(t[..<range.lowerBound])
        }
        return Listing(title: title?.trimmingCharacters(in: .whitespaces), entries: entries, truncated: truncated)
    }

    /// Decodes a single-quoted JavaScript string body (\xHH, \uHHHH incl. surrogate pairs, \/ …).
    static func unescapeJavaScript(_ input: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(input.utf16.count)
        var iterator = Array(input.unicodeScalars)[...]
        func hex(_ count: Int) -> UInt16? {
            guard iterator.count >= count else { return nil }
            let digits = String(String.UnicodeScalarView(iterator.prefix(count)))
            guard let value = UInt16(digits, radix: 16) else { return nil }
            iterator = iterator.dropFirst(count)
            return value
        }
        while let scalar = iterator.first {
            iterator = iterator.dropFirst()
            guard scalar == "\\", let next = iterator.first else {
                units.append(contentsOf: String(scalar).utf16)
                continue
            }
            iterator = iterator.dropFirst()
            switch next {
            case "x": if let v = hex(2) { units.append(v) }
            case "u": if let v = hex(4) { units.append(v) }
            case "n": units.append(0x0A)
            case "r": units.append(0x0D)
            case "t": units.append(0x09)
            case "b": units.append(0x08)
            case "f": units.append(0x0C)
            case "v": units.append(0x0B)
            case "0": units.append(0x00)
            default: units.append(contentsOf: String(next).utf16) // \' \" \\ \/
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Recursive listing

    /// Lists every downloadable file in a public folder tree.
    /// - Parameter pageURL: injectable for tests.
    public static func contents(of folderID: String,
                                headers: [String: String] = [:],
                                maxDepth: Int = 5,
                                maxFiles: Int = 2000,
                                timeout: TimeInterval = 30,
                                pageURL: @escaping @Sendable (String) -> URL = folderPageURL) async throws -> Contents {
        var files: [File] = []
        var truncated = false
        var visited = Set<String>()
        var title = folderID

        func walk(_ id: String, path: String, depth: Int) async throws {
            guard depth <= maxDepth, files.count < maxFiles, visited.insert(id).inserted else { return }
            let html = try await fetch(RemoteRequest(url: pageURL(id), headers: headers), timeout: timeout)
            let listing = try parseListing(html: html)
            if depth == 0, let t = listing.title, !t.isEmpty { title = t }
            truncated = truncated || listing.truncated

            for entry in listing.entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                try Task.checkCancellation()
                if entry.isFolder {
                    let sub = path.isEmpty ? safeComponent(entry.name) : path + "/" + safeComponent(entry.name)
                    try await walk(entry.id, path: sub, depth: depth + 1)
                } else if let target = download(for: entry), files.count < maxFiles {
                    files.append(File(url: target.url, name: target.name, relativeDirectory: path, size: entry.size))
                }
            }
        }

        try await walk(folderID, path: "", depth: 0)
        return Contents(title: title, files: files, truncated: truncated || files.count >= maxFiles)
    }

    static func fetch(_ request: RemoteRequest, timeout: TimeInterval) async throws -> String {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        HTTPHeaders.apply(request.headers, to: &urlRequest)
        urlRequest.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let session = URLSession(configuration: .transferConfiguration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404 || http.statusCode == 403
                ? DownloadEngineError.folderNotAccessible
                : DownloadEngineError.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Folder names become directories: no separators, no "..", no leading dots.
    static func safeComponent(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Folder" : cleaned
    }
}
