import Foundation

/// A contiguous byte range of the remote file and how much of it is safely on disk.
///
/// `downloaded` only counts bytes that were successfully written with `pwrite`, so a
/// persisted snapshot can always be resumed from `start + downloaded` without corruption.
public struct SegmentState: Codable, Equatable, Hashable, Sendable {
    public var start: Int64
    /// Inclusive end offset, or `-1` when the total length is unknown (streamed responses).
    public var end: Int64
    public var downloaded: Int64

    public init(start: Int64, end: Int64, downloaded: Int64 = 0) {
        self.start = start
        self.end = end
        self.downloaded = downloaded
    }

    public var hasKnownLength: Bool { end >= 0 }
    public var length: Int64 { hasKnownLength ? end - start + 1 : -1 }
    public var remaining: Int64 { hasKnownLength ? max(0, length - downloaded) : .max }
    public var isDone: Bool { hasKnownLength && downloaded >= length }
    public var nextOffset: Int64 { start + downloaded }
}

/// What the caller wants to fetch: the URL plus browser context (cookies, referrer, user agent).
public struct RemoteRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// What the probe learned about the remote file.
public struct RemoteResource: Codable, Equatable, Sendable {
    /// URL after redirects; segment requests go here directly.
    public var finalURL: URL
    /// Total size in bytes, or `-1` when the server didn't say.
    public var totalBytes: Int64
    /// True when the server answered a range probe with `206 Partial Content`.
    public var acceptsRanges: Bool
    /// File name from `Content-Disposition`, when present.
    public var suggestedFilename: String?
    /// Strong ETag (preferred) or Last-Modified, sent as `If-Range` so a changed file is never spliced.
    public var validator: String?
    /// MIME type without parameters ("application/zip"), when the server sent one.
    public var contentType: String?

    public init(finalURL: URL, totalBytes: Int64, acceptsRanges: Bool,
                suggestedFilename: String? = nil, validator: String? = nil, contentType: String? = nil) {
        self.finalURL = finalURL
        self.totalBytes = totalBytes
        self.acceptsRanges = acceptsRanges
        self.suggestedFilename = suggestedFilename
        self.validator = validator
        self.contentType = contentType
    }

    public var hasKnownLength: Bool { totalBytes >= 0 }

    /// The server answered with a web page rather than a file.
    public var isHTML: Bool {
        contentType == "text/html" || contentType == "application/xhtml+xml"
    }
}

/// Point-in-time transfer statistics, cheap enough to sample from a UI timer.
public struct TransferProgress: Sendable, Equatable {
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var activeConnections: Int

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0
    }
}
