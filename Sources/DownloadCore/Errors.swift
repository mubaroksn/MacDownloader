import Foundation

public enum DownloadEngineError: Error, Equatable, Sendable {
    /// Unexpected HTTP status (404, 403, …).
    case httpStatus(Int)
    /// 429 / 503: the server wants fewer connections or a pause.
    case throttled(Int)
    /// The remote file changed since the download started (If-Range mismatch, 416, size change).
    case remoteChanged
    /// The server stopped honoring Range requests mid-download.
    case rangeNotHonored
    case invalidResponse
    /// The connection closed before the segment was complete.
    case prematureEnd
    case insufficientSpace(needed: Int64, available: Int64)
    case io(operation: String, code: Int32)
    /// The link leads to a web page (login wall, preview page), not to a file.
    case notAFile

    /// Errors worth retrying on the same segment after a backoff.
    public var isTransient: Bool {
        switch self {
        case .throttled, .prematureEnd, .invalidResponse:
            return true
        case .httpStatus(let code):
            return code == 408 || code >= 500
        case .remoteChanged, .rangeNotHonored, .insufficientSpace, .io, .notAFile:
            return false
        }
    }
}

extension DownloadEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Server membalas HTTP \(code)"
        case .throttled(let code): return "Server sibuk (HTTP \(code))"
        case .remoteChanged: return "File di server berubah sejak download dimulai"
        case .rangeNotHonored: return "Server berhenti mendukung download bertahap"
        case .invalidResponse: return "Respons server tidak valid"
        case .prematureEnd: return "Koneksi terputus sebelum selesai"
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return available >= 0
                ? "Ruang disk tidak cukup (butuh \(f.string(fromByteCount: needed)), tersedia \(f.string(fromByteCount: available)))"
                : "Ruang disk tidak cukup"
        case .io(let op, let code): return "Gagal menulis file (\(op): \(String(cString: strerror(code))))"
        case .notAFile: return "Link ini membuka halaman web, bukan file. Mungkin perlu login: unduh lewat browser dengan ekstensi aktif"
        }
    }
}

extension Error {
    /// The connection could not be made or was dropped: often per-IP connection limits.
    var isConnectionFailure: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// URLSession network failures that usually go away on retry.
    var isTransientNetworkError: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired,
             .userCancelledAuthentication, .fileDoesNotExist, .noPermissionsToReadFile:
            return false
        default:
            return true
        }
    }
}
