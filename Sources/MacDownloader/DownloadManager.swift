import AppKit
import Foundation
import UserNotifications

enum SettingsKey {
    static let connections = "connectionsPerDownload"
    static let maxConcurrent = "maxConcurrentDownloads"
    static let folder = "downloadFolder"
    static let useCategoryFolders = "useCategoryFolders"
    static let notify = "notifyOnComplete"
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []

    private var engines: [UUID: SegmentedDownloader] = [:]
    private var lastBytes: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var tickCount = 0
    private let defaults = UserDefaults.standard

    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var stateFile: URL { supportDir.appendingPathComponent("downloads.json") }
    private func partsDir(for id: UUID) -> URL {
        supportDir.appendingPathComponent("parts/\(id.uuidString)", isDirectory: true)
    }

    // MARK: Settings

    var connectionsPerDownload: Int { max(1, min(32, defaults.object(forKey: SettingsKey.connections) as? Int ?? 8)) }
    var maxConcurrent: Int { max(1, min(10, defaults.object(forKey: SettingsKey.maxConcurrent) as? Int ?? 3)) }
    var useCategoryFolders: Bool { defaults.object(forKey: SettingsKey.useCategoryFolders) as? Bool ?? true }
    var notifyOnComplete: Bool { defaults.object(forKey: SettingsKey.notify) as? Bool ?? true }
    var downloadFolder: URL {
        if let path = defaults.string(forKey: SettingsKey.folder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in DownloadManager.shared.tick() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Public actions

    func add(urlString: String, fileName: String? = nil, headers: [String: String] = [:], startNow: Bool = true) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let name = sanitize(fileName?.isEmpty == false ? fileName! : url.lastPathComponent)
        var item = DownloadItem(url: url, fileName: name.isEmpty ? "download" : name,
                                category: FileCategory.from(fileName: name))
        item.headers = headers
        item.nameLocked = fileName?.isEmpty == false
        item.status = startNow ? .queued : .paused
        items.insert(item, at: 0)
        save()
        schedule()
    }

    func resume(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id), [.paused, .failed].contains(items[i].status) else { continue }
            items[i].status = .queued
            items[i].errorMessage = nil
        }
        save()
        schedule()
    }

    func pause(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id) else { continue }
            if items[i].status == .queued { items[i].status = .paused }
            engines[id]?.pause()
        }
        save()
    }

    func restart(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id), engines[id] == nil else { continue }
            try? FileManager.default.removeItem(at: partsDir(for: id))
            items[i].segments = []
            items[i].downloadedBytes = 0
            items[i].totalBytes = -1
            items[i].errorMessage = nil
            items[i].status = .queued
        }
        save()
        schedule()
    }

    func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            if let engine = engines[id] {
                engine.onFinish = nil
                engine.pause()
                engines[id] = nil
            }
            if let i = index(id) {
                if deleteFiles, let path = items[i].destinationPath {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
                items.remove(at: i)
            }
            let parts = partsDir(for: id)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                try? FileManager.default.removeItem(at: parts)
            }
        }
        save()
        schedule()
    }

    func removeCompleted() {
        remove(Set(items.filter { $0.status == .completed }.map(\.id)), deleteFiles: false)
    }

    func resumeAll() { resume(Set(items.filter { [.paused, .failed].contains($0.status) }.map(\.id))) }
    func pauseAll() { pause(Set(items.filter { [.downloading, .queued].contains($0.status) }.map(\.id))) }

    func item(_ id: UUID) -> DownloadItem? { index(id).map { items[$0] } }

    // MARK: Queue

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func schedule() {
        let running = items.filter { $0.status == .downloading }.count
        var slots = maxConcurrent - running
        guard slots > 0 else { return }
        // Oldest queued first.
        for item in items.reversed() where item.status == .queued && slots > 0 {
            slots -= 1
            begin(item.id)
        }
    }

    private func begin(_ id: UUID) {
        guard let i = index(id) else { return }
        items[i].status = .downloading
        items[i].errorMessage = nil
        let item = items[i]

        if !item.segments.isEmpty {
            startEngine(for: item)
            return
        }
        Task {
            do {
                let info = try await probe(url: item.url, headers: item.headers)
                guard let i = index(id), items[i].status == .downloading else { return }
                items[i].url = info.finalURL
                items[i].totalBytes = info.totalBytes
                items[i].supportsRanges = info.supportsRanges
                if let name = info.suggestedName, !item.nameLocked {
                    items[i].fileName = sanitize(name)
                    items[i].category = FileCategory.from(fileName: items[i].fileName)
                }
                items[i].segments = SegmentedDownloader.plan(total: info.totalBytes,
                                                             supportsRanges: info.supportsRanges,
                                                             connections: connectionsPerDownload)
                save()
                startEngine(for: items[i])
            } catch {
                markFailed(id, error.localizedDescription)
            }
        }
    }

    private func startEngine(for item: DownloadItem) {
        let engine = SegmentedDownloader(url: item.url, headers: item.headers, partsDir: partsDir(for: item.id),
                                         supportsRanges: item.supportsRanges, segments: item.segments,
                                         maxConnections: item.supportsRanges ? connectionsPerDownload : 1)
        engine.onFinish = { [weak self] outcome in
            Task { @MainActor in self?.engineFinished(item.id, outcome) }
        }
        engines[item.id] = engine
        lastBytes[item.id] = nil
        engine.start()
    }

    private func engineFinished(_ id: UUID, _ outcome: SegmentedDownloader.Outcome) {
        engines[id] = nil
        guard let i = index(id) else { return }
        items[i].speed = 0
        items[i].activeConnections = 0
        switch outcome {
        case .paused(let segs):
            items[i].segments = segs
            items[i].downloadedBytes = segs.reduce(0) { $0 + $1.downloaded }
            if items[i].status == .downloading { items[i].status = .paused }
        case .failed(let message, let segs):
            items[i].segments = segs
            items[i].downloadedBytes = segs.reduce(0) { $0 + $1.downloaded }
            markFailed(id, message)
        case .finished(let segs):
            items[i].segments = segs
            let total = segs.reduce(0) { $0 + $1.downloaded }
            items[i].downloadedBytes = total
            items[i].totalBytes = total
            finalize(id, segs)
        }
        save()
        schedule()
    }

    private func finalize(_ id: UUID, _ segs: [SegmentState]) {
        guard let i = index(id) else { return }
        let item = items[i]
        var folder = downloadFolder
        if useCategoryFolders { folder.appendPathComponent(item.category.label, isDirectory: true) }
        let dest = uniqueURL(in: folder, name: item.fileName)
        let parts = partsDir(for: id)
        let targetFolder = folder
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                try SegmentedDownloader.merge(segments: segs, partsDir: parts, into: dest)
                await MainActor.run { self.markCompleted(id, dest) }
            } catch {
                await MainActor.run { self.markFailed(id, "Gagal menyimpan file: \(error.localizedDescription)") }
            }
        }
    }

    private func markCompleted(_ id: UUID, _ dest: URL) {
        guard let i = index(id) else { return }
        items[i].status = .completed
        items[i].destinationPath = dest.path
        items[i].fileName = dest.lastPathComponent
        items[i].completedAt = Date()
        items[i].segments = []
        save()
        if notifyOnComplete {
            let content = UNMutableNotificationContent()
            content.title = "Download selesai"
            content.body = dest.lastPathComponent
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
        }
    }

    private func markFailed(_ id: UUID, _ message: String) {
        guard let i = index(id) else { return }
        items[i].status = .failed
        items[i].errorMessage = message
        items[i].speed = 0
        save()
        schedule()
    }

    // MARK: Progress polling

    private func tick() {
        let now = Date()
        for (id, engine) in engines {
            guard let i = index(id) else { continue }
            let snap = engine.snapshot
            items[i].downloadedBytes = snap.downloaded
            items[i].activeConnections = snap.connections
            if let last = lastBytes[id] {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0 {
                    let instant = Double(snap.downloaded - last.bytes) / dt
                    items[i].speed = items[i].speed == 0 ? instant : items[i].speed * 0.7 + instant * 0.3
                }
            }
            lastBytes[id] = (snap.downloaded, now)
        }
        // Checkpoint segment layout every few seconds so a crash doesn't lose split segments.
        tickCount += 1
        if tickCount % 10 == 0, !engines.isEmpty {
            for (id, engine) in engines { if let i = index(id) { items[i].segments = engine.currentSegments } }
            save()
        }
        let active = items.filter { $0.status == .downloading }.count
        NSApp?.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }

    // MARK: Files

    private func sanitize(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        return decoded.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateFile),
              var saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        for i in saved.indices where saved[i].status == .downloading || saved[i].status == .queued {
            saved[i].status = .paused
        }
        items = saved
    }

    func save() {
        saveWork?.cancel()
        let snapshot = items
        let file = stateFile
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Called on quit: pause everything so progress is kept on disk.
    func prepareForQuit() {
        for (id, engine) in engines {
            engine.onFinish = nil
            engine.pause()
            if let i = index(id) {
                items[i].downloadedBytes = engine.snapshot.downloaded
                items[i].segments = engine.currentSegments
                items[i].status = .paused
            }
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: stateFile, options: .atomic) }
    }
}
