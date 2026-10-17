import Foundation

/// Discovers size, range support, file name and a change validator with a single
/// `Range: bytes=0-0` GET. HEAD is avoided on purpose: many CDNs and signed-URL
/// endpoints answer HEAD differently from GET (or reject it).
public enum ResourceProber {
    public static func probe(_ request: RemoteRequest,
                             timeout: TimeInterval = 30,
                             maxAttempts: Int = 6) async throws -> RemoteResource {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await probeOnce(request, timeout: timeout)
            } catch {
                try Task.checkCancellation()
                let retryable = (error as? DownloadEngineError)?.isTransient ?? error.isTransientNetworkError
                guard retryable, attempt < maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(20, 2 << (attempt - 1))) * 1_000_000_000)
            }
        }
    }

    static func probeOnce(_ request: RemoteRequest, timeout: TimeInterval) async throws -> RemoteResource {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: timeout)
        HTTPHeaders.apply(request.headers, to: &urlRequest)
        urlRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let session = URLSession(configuration: .transferConfiguration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        bytes.task.cancel() // we only need the headers

        guard let http = response as? HTTPURLResponse else { throw DownloadEngineError.invalidResponse }
        return try resource(from: http, requestedURL: request.url)
    }

    static func resource(from http: HTTPURLResponse, requestedURL: URL) throws -> RemoteResource {
        var total: Int64 = -1
        var acceptsRanges = false
        switch http.statusCode {
        case 206:
            // "Content-Range: bytes 0-0/12345" ("/*" means unknown length).
            if let header = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = header.lastIndex(of: "/"),
               let size = Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                total = size
                acceptsRanges = size > 0
            }
        case 200:
            // Server ignored the Range header: single stream only.
            total = http.expectedContentLength
        case 429, 503:
            throw DownloadEngineError.throttled(http.statusCode)
        default:
            throw DownloadEngineError.httpStatus(http.statusCode)
        }

        var name = http.suggestedFilename
        if name == "Unknown" || name?.isEmpty == true { name = nil }
        // Only server-provided names (Content-Disposition) count; URL-derived ones are the caller's job.
        if http.value(forHTTPHeaderField: "Content-Disposition") == nil { name = nil }

        return RemoteResource(finalURL: http.url ?? requestedURL,
                              totalBytes: total,
                              acceptsRanges: acceptsRanges,
                              suggestedFilename: name,
                              validator: validator(from: http))
    }

    /// If-Range only accepts strong ETags or an HTTP date.
    static func validator(from http: HTTPURLResponse) -> String? {
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/"), !etag.isEmpty {
            return etag
        }
        return http.value(forHTTPHeaderField: "Last-Modified")
    }
}

extension URLSessionConfiguration {
    /// One isolated connection pool per session.
    ///
    /// This is what makes multi-connection acceleration real: a shared session would
    /// coalesce every range request for an HTTP/2 host onto *one* TCP connection, so
    /// "8 connections" would share a single congestion window.
    static func transferConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false      // cookies arrive explicitly from the browser
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        return config
    }
}
