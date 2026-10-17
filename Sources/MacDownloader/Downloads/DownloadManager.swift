import AppKit
import DownloadCore
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum SettingsKey {
    static let connections = "connectionsPerDownload"
    static let maxConcurrent = "maxConcurrentDownloads"
    static let folder = "downloadFolder"
    static let useCategoryFolders = "useCategoryFolders"
    static let notify = "notifyOnComplete"
    static let preventSleep = "preventSleepWhileDownloading"
    static let showMenuBar = "showMenuBarExtra"
    static let monitorClipboard = "monitorClipboard"
    static let autoScale = "autoScaleConnections"
    static let speedMode = "speedMode"
    static let saverLimitKB = "speedLimitSaverKB"
    static let quietLimitKB = "speedLimitQuietKB"
    static let launchAtLogin = "launchAtLogin"
    static let themeMode = "themeMode"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let statsDay = "statsDay"
    static let statsTodayBytes = "statsTodayBytes"
}

/// Speed presets shown on the downloads page and in the menu bar.
enum SpeedMode: String, CaseIterable, Identifiable {
    case full, saver, quiet
    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Penuh"
        case .saver: return "Hemat"
        case .quiet: return "Senyap"
        }
    }

    var symbol: String {
        switch self {
        case .full: return "hare"
        case .saver: return "tortoise"
        case .quiet: return "moon"
        }
    }

    /// Default caps in KB/s (Starlink ~25 MB/s: Hemat leaves room for calls and streaming).
    static let defaultSaverKB = 5 * 1024
    static let defaultQuietKB = 1024
}

/// Owns the queue and its persistence; the UI's single source of truth.
///
/// Transfers themselves run in `DownloadCore.RangeDownloader` off the main actor. This class
/// only starts/cancels them, samples their progress on a timer that exists solely while
/// something is transferring, and persists segment snapshots for resume.
@MainActor
final class DownloadManager: ObservableObject, DownloadDispatching {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Total speed, one sample per progress tick (~0.5 s), newest last. Feeds the sparkline.
    @Published private(set) var speedHistory: [Double] = Array(repeating: 0, count: DownloadManager.historyLength)
    /// Bytes transferred since local midnight (all downloads, including partial ones).
    @Published private(set) var todayBytes: Int64 = 0
    @Published var speedMode: SpeedMode = .full {
        didSet {
            defaults.set(speedMode.rawValue, forKey: SettingsKey.speedMode)
            applySpeedLimit()
        }
    }

    /// One cap for every connection of every download.
    let limiter = BandwidthLimiter()
    static let historyLength = 120

    private struct ActiveTransfer {
        let task: Task<Void, Never>
        var downloader: RangeDownloader?
    }

    private var transfers: [UUID: ActiveTransfer] = [:]
    private var lastSample: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var tickCount = 0
    private var saveWork: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    static let tempExtension = "mdownload"

    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var stateFile: URL { supportDir.appendingPathComponent("downloads.json") }

    // MARK: Settings

    var connectionsPerDownload: Int { max(1, min(32, defaults.object(forKey: SettingsKey.connections) as? Int ?? 8)) }
    var maxConcurrent: Int { max(1, min(10, defaults.object(forKey: SettingsKey.maxConcurrent) as? Int ?? 3)) }
    var useCategoryFolders: Bool { defaults.object(forKey: SettingsKey.useCategoryFolders) as? Bool ?? true }
    var notifyOnComplete: Bool { defaults.object(forKey: SettingsKey.notify) as? Bool ?? true }
    var preventSleep: Bool { defaults.object(forKey: SettingsKey.preventSleep) as? Bool ?? true }
    var downloadFolder: URL {
        if let path = defaults.string(forKey: SettingsKey.folder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    var saverLimitKB: Int { max(64, defaults.object(forKey: SettingsKey.saverLimitKB) as? Int ?? SpeedMode.defaultSaverKB) }
    var quietLimitKB: Int { max(64, defaults.object(forKey: SettingsKey.quietLimitKB) as? Int ?? SpeedMode.defaultQuietKB) }

    /// Cap for a mode in bytes per second (0 = none).
    func limit(for mode: SpeedMode) -> Int64 {
        switch mode {
        case .full: return 0
        case .saver: return Int64(saverLimitKB) * 1024
        case .quiet: return Int64(quietLimitKB) * 1024
        }
    }

    /// Re-applies the current mode (also after the user edits a preset in Settings).
    func applySpeedLimit() { limiter.setLimit(limit(for: speedMode)) }

    var activeCount: Int { items.filter { $0.status == .downloading }.count }
    var totalSpeed: Double { items.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speed } }

    private init() {
        load()
        speedMode = SpeedMode(rawValue: defaults.string(forKey: SettingsKey.speedMode) ?? "") ?? .full
        applySpeedLimit()
        rollStatsDayIfNeeded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: DownloadDispatching

    @discardableResult
    func enqueue(_ request: DownloadRequest) -> UUID? {
        if let folderID = DriveFolder.folderID(from: request.url) {
            expandDriveFolder(folderID, request: request)
            return nil
        }
        let urlName = request.url.lastPathComponent
        let name = sanitize(request.suggestedFilename ?? (urlName == "/" ? "" : urlName))
        var item = DownloadItem(url: request.url, fileName: name.isEmpty ? "download" : name,
                                category: FileCategory.from(fileName: name))
        item.headers = request.headers
        item.sourceURL = request.url
        item.subdirectory = request.subdirectory
        item.nameLocked = request.suggestedFilename != nil
        item.status = request.startImmediately ? .queued : .paused
        items.insert(item, at: 0)
        save()
        schedule()
        return item.id
    }

    /// Convenience for UI call sites.
    func add(urlString: String, fileName: String? = nil, origin: DownloadRequest.Origin = .manual,
             startNow: Bool = true) {
        guard let request = DownloadRequest(urlString: urlString, suggestedFilename: fileName,
                                            origin: origin, startImmediately: startNow) else { return }
        enqueue(request)
    }

    // MARK: Google Drive folders

    /// Lists a public Drive folder and queues every file, keeping the folder structure under
    /// Downloads/<folder name>/. Failures show up as one failed row with the reason.
    private func expandDriveFolder(_ folderID: String, request: DownloadRequest) {
        UIState.shared.flash("Membaca isi folder Google Drive…", autoHide: false)
        Task {
            do {
                let contents = try await DriveFolder.contents(of: folderID, headers: request.headers)
                let root = sanitize(contents.title).isEmpty ? "Google Drive" : sanitize(contents.title)
                guard !contents.files.isEmpty else {
                    UIState.shared.flash("Folder \"\(root)\" kosong atau hanya berisi file Google yang tidak bisa diunduh")
                    return
                }
                for file in contents.files {
                    guard var fileRequest = DownloadRequest(urlString: file.url.absoluteString,
                                                            suggestedFilename: file.name,
                                                            referrer: request.referrer,
                                                            cookie: request.cookie,
                                                            userAgent: request.userAgent,
                                                            origin: request.origin,
                                                            startImmediately: request.startImmediately) else { continue }
                    fileRequest.subdirectory = file.relativeDirectory.isEmpty ? root : root + "/" + file.relativeDirectory
                    if let id = enqueue(fileRequest), let i = index(id), let size = file.size, size > 0 {
                        items[i].totalBytes = size
                    }
                }
                var message = "\(contents.files.count) file dari folder \"\(root)\" ditambahkan"
                if contents.truncated { message += ". Google hanya menampilkan sebagian isi folder besar; sisanya unduh per subfolder" }
                UIState.shared.flash(message)
            } catch {
                UIState.shared.flash(nil)
                var item = DownloadItem(url: request.url, fileName: "Folder Google Drive", category: .other)
                item.sourceURL = request.url
                item.headers = request.headers
                item.status = .failed
                item.errorMessage = error.localizedDescription
                items.insert(item, at: 0)
                save()
            }
        }
    }

    // MARK: Queue actions

    func resume(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id), [.paused, .failed].contains(items[i].status) else { continue }
            // A Drive folder that failed to list: try listing it again instead of downloading the page.
            if let source = items[i].sourceURL, let folderID = DriveFolder.folderID(from: source) {
                let item = items.remove(at: i)
                var request = DownloadRequest(urlString: source.absoluteString, origin: .manual)
                request?.cookie = item.headers["Cookie"]
                if let request { expandDriveFolder(folderID, request: request) }
                continue
            }
            items[i].status = .queued
            items[i].errorMessage = nil
        }
        save()
        schedule()
    }

    func pause(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id) else { continue }
            if items[i].status == .queued || items[i].status == .downloading { items[i].status = .paused }
            transfers[id]?.task.cancel() // runTransfer persists the snapshot when it unwinds
        }
        save()
        updateSystemState()
    }

    func restart(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = index(id), transfers[id] == nil else { continue }
            removeTempFile(of: items[i])
            resetProgress(at: i)
            items[i].errorMessage = nil
            items[i].status = .queued
        }
        save()
        schedule()
    }

    func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            transfers[id]?.task.cancel()
            transfers[id] = nil
            guard let i = index(id) else { continue }
            let item = items[i]
            if item.status != .completed { removeTempFile(of: item) }
            if deleteFiles, item.status == .completed, let path = item.destinationPath {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            items.remove(at: i)
        }
        save()
        schedule()
        updateSystemState()
    }

    func removeCompleted() {
        remove(Set(items.filter { $0.status == .completed }.map(\.id)), deleteFiles: false)
    }

    func resumeAll() { resume(Set(items.filter { [.paused, .failed].contains($0.status) }.map(\.id))) }
    func pauseAll() { pause(Set(items.filter { [.downloading, .queued].contains($0.status) }.map(\.id))) }

    func item(_ id: UUID) -> DownloadItem? { index(id).map { items[$0] } }

    // MARK: Scheduling

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func schedule() {
        var slots = maxConcurrent - transfers.count
        for item in items.reversed() where item.status == .queued && slots > 0 { // oldest first
            slots -= 1
            start(item.id)
        }
        updateSystemState()
    }

    private func start(_ id: UUID) {
        guard let i = index(id), transfers[id] == nil else { return }
        items[i].status = .downloading
        items[i].errorMessage = nil
        let task = Task { await DownloadManager.shared.runTransfer(id) }
        transfers[id] = ActiveTransfer(task: task)
    }

    /// Probe → plan destination → transfer → move into place. Runs on the main actor but
    /// awaits the engine, which does all network and disk work on the cooperative pool.
    private func runTransfer(_ id: UUID) async {
        do {
            guard let snapshot = item(id) else { return }
            let resolved = try await DownloadResolver.resolve(
                RemoteRequest(url: snapshot.sourceURL ?? snapshot.url, headers: snapshot.headers))
            let resource = resolved.resource
            try Task.checkCancellation()
            guard let i = index(id) else { return }

            let resumeSegments = resumableSegments(for: items[i], resource: resource)
            if resumeSegments == nil {
                removeTempFile(of: items[i])
                resetProgress(at: i)
                try planDestination(at: i, resource: resource)
            }
            items[i].url = resource.finalURL
            items[i].totalBytes = resource.totalBytes
            items[i].supportsRanges = resource.acceptsRanges
            items[i].validator = resource.validator
            save()

            var config = RangeDownloader.Configuration()
            config.connections = connectionsPerDownload
            config.autoScale = defaults.object(forKey: SettingsKey.autoScale) as? Bool ?? true
            config.maxConnections = 32
            config.limiter = limiter
            let downloader = RangeDownloader(
                request: RemoteRequest(url: resource.finalURL, headers: resolved.request.headers),
                resource: resource,
                fileURL: URL(fileURLWithPath: items[i].tempPath!),
                resumeFrom: resumeSegments,
                configuration: config)
            transfers[id]?.downloader = downloader
            lastSample[id] = (downloader.progress.downloadedBytes, Date())
            startTimerIfNeeded()

            try await downloader.run()

            countFinalBytes(downloader, id)
            capture(downloader, into: id)
            try moveIntoPlace(id)
            transfers[id] = nil
        } catch {
            if let downloader = transfers[id]?.downloader {
                countFinalBytes(downloader, id)
                capture(downloader, into: id)
            }
            transfers[id] = nil
            handleFailure(id, error)
        }
        lastSample[id] = nil
        save()
        schedule()
    }

    /// Segments from a previous session are reused only if the remote file is provably the same.
    private func resumableSegments(for item: DownloadItem, resource: RemoteResource) -> [SegmentState]? {
        guard !item.segments.isEmpty, resource.acceptsRanges, item.supportsRanges,
              item.totalBytes == resource.totalBytes,
              item.validator == nil || resource.validator == nil || item.validator == resource.validator,
              let temp = item.tempPath, FileManager.default.fileExists(atPath: temp),
              SegmentPlanner.isValidTiling(item.segments, totalBytes: resource.totalBytes) else { return nil }
        return item.segments
    }

    /// Picks the final name and folder now, so data is written in place ("X.mp4.mdownload")
    /// and completion is an atomic rename on the same volume rather than a copy.
    private func planDestination(at i: Int, resource: RemoteResource) throws {
        if !items[i].nameLocked {
            items[i].fileName = bestName(current: items[i].fileName, resource: resource)
            items[i].category = FileCategory.from(fileName: items[i].fileName)
        }
        var folder = downloadFolder
        if let sub = items[i].subdirectory, !sub.isEmpty {
            for component in sub.split(separator: "/") where component != ".." && component != "." {
                folder.appendPathComponent(String(component), isDirectory: true)
            }
        } else if useCategoryFolders {
            folder.appendPathComponent(items[i].category.label, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, name: items[i].fileName)
        items[i].fileName = destination.lastPathComponent
        items[i].destinationPath = destination.path
        items[i].tempPath = destination.path + "." + Self.tempExtension
    }

    /// Server name (Content-Disposition) > final URL name > current name, plus an extension
    /// from the MIME type when none is known ("download" → "download.zip").
    private func bestName(current: String, resource: RemoteResource) -> String {
        if let name = resource.suggestedFilename.map(sanitize), !name.isEmpty { return name }
        var name = current
        let finalName = sanitize(resource.finalURL.lastPathComponent)
        if (name as NSString).pathExtension.isEmpty, !(finalName as NSString).pathExtension.isEmpty {
            name = finalName
        }
        if (name as NSString).pathExtension.isEmpty,
           let mime = resource.contentType, mime != "application/octet-stream",
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += "." + ext
        }
        return name.isEmpty ? "download" : name
    }

    private func moveIntoPlace(_ id: UUID) throws {
        guard let i = index(id), let temp = items[i].tempPath, let planned = items[i].destinationPath else { return }
        var destination = URL(fileURLWithPath: planned)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = uniqueURL(in: destination.deletingLastPathComponent(), name: destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: URL(fileURLWithPath: temp), to: destination)

        items[i].status = .completed
        items[i].destinationPath = destination.path
        items[i].fileName = destination.lastPathComponent
        items[i].tempPath = nil
        items[i].segments = []
        items[i].completedAt = Date()
        items[i].speed = 0
        items[i].activeConnections = 0
        if items[i].totalBytes < 0 { items[i].totalBytes = items[i].downloadedBytes }
        notifyCompletion(destination)
    }

    private func handleFailure(_ id: UUID, _ error: Error) {
        guard let i = index(id) else { return }
        items[i].speed = 0
        items[i].activeConnections = 0
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            if items[i].status == .downloading { items[i].status = .paused }
            return
        }
        if case .remoteChanged = error as? DownloadEngineError {
            // Never splice two versions of a file: start over automatically.
            removeTempFile(of: items[i])
            resetProgress(at: i)
            items[i].status = .queued
            return
        }
        items[i].status = .failed
        items[i].errorMessage = error.localizedDescription
    }

    private func capture(_ downloader: RangeDownloader, into id: UUID) {
        guard let i = index(id) else { return }
        let segments = downloader.snapshot()
        items[i].segments = segments
        items[i].downloadedBytes = segments.reduce(0) { $0 + $1.downloaded }
    }

    private func resetProgress(at i: Int) {
        items[i].segments = []
        items[i].downloadedBytes = 0
        items[i].totalBytes = -1
        items[i].validator = nil
        items[i].tempPath = nil
        items[i].destinationPath = nil
    }

    private func removeTempFile(of item: DownloadItem) {
        guard let temp = item.tempPath else { return }
        try? FileManager.default.removeItem(atPath: temp)
    }

    private func notifyCompletion(_ destination: URL) {
        guard notifyOnComplete else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download selesai"
        content.body = destination.lastPathComponent
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Progress sampling (only while transferring)

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in DownloadManager.shared.tick() }
        }
        timer.tolerance = 0.2 // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard transfers.values.allSatisfy({ $0.downloader == nil }) else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        rollStatsDayIfNeeded()
        var transferred: Int64 = 0
        for (id, transfer) in transfers {
            guard let downloader = transfer.downloader, let i = index(id) else { continue }
            let progress = downloader.progress
            items[i].downloadedBytes = progress.downloadedBytes
            items[i].activeConnections = progress.activeConnections
            if let last = lastSample[id] {
                let dt = now.timeIntervalSince(last.time)
                transferred += max(0, progress.downloadedBytes - last.bytes)
                if dt > 0 {
                    let instant = max(0, Double(progress.downloadedBytes - last.bytes) / dt)
                    items[i].speed = items[i].speed == 0 ? instant : items[i].speed * 0.7 + instant * 0.3
                }
            }
            lastSample[id] = (progress.downloadedBytes, now)
        }
        addTransferred(transferred)
        pushSpeedSample(totalSpeed)
        // Checkpoint segment layout every ~5 s so a crash loses at most a few seconds.
        tickCount += 1
        if tickCount % 10 == 0 {
            for (id, transfer) in transfers { if let d = transfer.downloader { capture(d, into: id) } }
            save()
        }
        stopTimerIfIdle()
    }

    /// Re-evaluates sleep/App Nap state (e.g. after the user flips the setting).
    func refreshSystemActivity() { updateSystemState() }

    private func updateSystemState() {
        let transferring = !transfers.isEmpty
        SystemActivity.shared.update(transferring: transferring, preventSleep: preventSleep)
        let active = items.filter { $0.status == .downloading }.count
        NSApp?.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        if !transferring {
            timer?.invalidate()
            timer = nil
            if (speedHistory.last ?? 0) > 0 { pushSpeedSample(0) }
        }
    }

    // MARK: Statistics

    private func pushSpeedSample(_ value: Double) {
        var history = speedHistory
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        speedHistory = history
    }

    /// Counts what arrived between the last tick and the end of a transfer.
    private func countFinalBytes(_ downloader: RangeDownloader, _ id: UUID) {
        guard let last = lastSample[id] else { return }
        addTransferred(max(0, downloader.progress.downloadedBytes - last.bytes))
        lastSample[id] = (downloader.progress.downloadedBytes, Date())
    }

    private func addTransferred(_ bytes: Int64) {
        guard bytes > 0 else { return }
        rollStatsDayIfNeeded()
        todayBytes += bytes
        defaults.set(todayBytes, forKey: SettingsKey.statsTodayBytes)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Starts a fresh "today" counter after midnight (checked on every tick and on launch).
    func rollStatsDayIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        if defaults.string(forKey: SettingsKey.statsDay) != today {
            defaults.set(today, forKey: SettingsKey.statsDay)
            defaults.set(Int64(0), forKey: SettingsKey.statsTodayBytes)
            if todayBytes != 0 { todayBytes = 0 }
        } else if todayBytes == 0 {
            let stored = (defaults.object(forKey: SettingsKey.statsTodayBytes) as? NSNumber)?.int64Value ?? 0
            if stored != 0 { todayBytes = stored }
        }
    }

    /// Downloads finished since local midnight.
    var completedTodayCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return items.filter { $0.status == .completed && ($0.completedAt ?? .distantPast) >= start }.count
    }

    var queuedCount: Int { items.filter { $0.status == .queued }.count }
    var pausedCount: Int { items.filter { $0.status == .paused }.count }

    // MARK: Files

    private func sanitize(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        return decoded.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A name that collides neither with a finished file nor with another in-progress one.
    private func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let reserved = Set(items.compactMap(\.destinationPath))
        func taken(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.path + "." + Self.tempExtension)
                || reserved.contains(url.path)
        }
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while taken(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateFile),
              var saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        for i in saved.indices {
            if saved[i].status == .downloading || saved[i].status == .queued { saved[i].status = .paused }
            // v1.1 kept part files under Application Support; that layout can't be resumed in place.
            if saved[i].status != .completed && saved[i].tempPath == nil && !saved[i].segments.isEmpty {
                saved[i].segments = []
                saved[i].downloadedBytes = 0
            }
        }
        items = saved
        try? FileManager.default.removeItem(at: supportDir.appendingPathComponent("parts", isDirectory: true))
    }

    func save() {
        saveWork?.cancel()
        let snapshot = items
        let file = stateFile
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Called on quit: snapshot every transfer synchronously so nothing written is lost.
    func prepareForQuit() {
        for (id, transfer) in transfers {
            if let downloader = transfer.downloader { capture(downloader, into: id) }
            transfer.task.cancel()
            if let i = index(id) { items[i].status = .paused }
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: stateFile, options: .atomic) }
        SystemActivity.shared.update(transferring: false, preventSleep: false)
    }
}
