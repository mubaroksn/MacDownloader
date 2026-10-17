import DownloadCore
import Foundation

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, completed, failed

    var label: String {
        switch self {
        case .queued: return "Antri"
        case .downloading: return "Mengunduh"
        case .paused: return "Dijeda"
        case .completed: return "Selesai"
        case .failed: return "Gagal"
        }
    }
}

enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case video, music, document, program, archive, image, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return "Video"
        case .music: return "Musik"
        case .document: return "Dokumen"
        case .program: return "Program"
        case .archive: return "Arsip"
        case .image: return "Gambar"
        case .other: return "Lainnya"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .music: return "music.note"
        case .document: return "doc.text"
        case .program: return "app.badge"
        case .archive: return "archivebox"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    static func from(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv", "3gp", "ts":
            return .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma":
            return .music
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf",
             "epub", "csv", "pages", "numbers", "key", "odt":
            return .document
        case "dmg", "pkg", "app", "exe", "msi", "apk", "ipa", "deb", "rpm":
            return .program
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "iso":
            return .archive
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff", "raw":
            return .image
        default:
            return .other
        }
    }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var fileName: String
    var category: FileCategory
    var status: DownloadStatus = .queued
    var totalBytes: Int64 = -1
    var downloadedBytes: Int64 = 0
    var supportsRanges = false
    var segments: [SegmentState] = []
    var destinationPath: String?
    var errorMessage: String?
    var addedAt = Date()
    var completedAt: Date?
    /// Extra request headers (Cookie, Referer, User-Agent) sent by the browser extension.
    var headers: [String: String] = [:]
    /// True when the user or browser chose the name, so the server's name isn't applied.
    var nameLocked = false
    /// In-progress file next to the final destination ("name.ext.mdownload").
    var tempPath: String?
    /// ETag / Last-Modified captured by the probe; guards resume against a changed remote file.
    var validator: String?

    // Runtime-only values, not persisted.
    var speed: Double = 0
    var activeConnections = 0

    enum CodingKeys: String, CodingKey {
        case id, url, fileName, category, status, totalBytes, downloadedBytes,
             supportsRanges, segments, destinationPath, errorMessage, addedAt,
             completedAt, headers, nameLocked, tempPath, validator
    }

    init(url: URL, fileName: String, category: FileCategory) {
        self.url = url
        self.fileName = fileName
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        fileName = try c.decode(String.self, forKey: .fileName)
        category = try c.decode(FileCategory.self, forKey: .category)
        status = try c.decode(DownloadStatus.self, forKey: .status)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        downloadedBytes = try c.decode(Int64.self, forKey: .downloadedBytes)
        supportsRanges = try c.decode(Bool.self, forKey: .supportsRanges)
        segments = try c.decode([SegmentState].self, forKey: .segments)
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        nameLocked = try c.decodeIfPresent(Bool.self, forKey: .nameLocked) ?? false
        tempPath = try c.decodeIfPresent(String.self, forKey: .tempPath)
        validator = try c.decodeIfPresent(String.self, forKey: .validator)
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var eta: TimeInterval? {
        guard status == .downloading, speed > 1, totalBytes > 0 else { return nil }
        return Double(totalBytes - downloadedBytes) / speed
    }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
