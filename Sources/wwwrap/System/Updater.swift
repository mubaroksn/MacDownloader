import AppKit
import DownloadCore
import Foundation

/// One-click update: download the release DMG with our own engine, check it, swap the app
/// bundle and relaunch. Downloads that were running continue after the relaunch.
///
/// Why no Gatekeeper prompt: files the app downloads itself carry no quarantine flag
/// (the app doesn't opt in with LSFileQuarantineEnabled), and the helper clears it anyway.
///
/// Safety: the new bundle must have our bundle id, the expected version and a valid
/// signature; the swap keeps the old bundle until the new one is in place.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private init() {}

    /// Updates to `version` from the GitHub release.
    func install(version: String) {
        start(source: UpdateChecker.dmgURL(for: version), expectedVersion: version)
    }

    /// `source` may be a file URL (CI uses `-updateTestDMG <path>`).
    func start(source: URL, expectedVersion: String?) {
        guard !isBusy else { return }
        phase = .downloading(0)
        Task {
            do {
                try await run(source: source, expectedVersion: expectedVersion)
            } catch {
                phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    struct UpdateError: Error {
        let message: String
    }

    private func run(source: URL, expectedVersion: String?) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("wwwrap-update-\(UUID().uuidString)") // l10n-ignore
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download.
        let dmg = work.appendingPathComponent("update.dmg")
        if source.isFileURL {
            try fm.copyItem(at: source, to: dmg)
        } else {
            try await download(source, to: dmg)
        }

        // 2. Open and check the new app.
        phase = .installing
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                 "-mountpoint", mount.path, "-quiet"])
        var mounted = true
        defer { if mounted { _ = try? Shell.runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) } }

        guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: newApp) else {
            throw UpdateError(message: L("File update tidak berisi aplikasi."))
        }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(message: L("File update bukan untuk aplikasi ini."))
        }
        let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let expectedVersion, newVersion != expectedVersion {
            throw UpdateError(message: L("Versi di file update (%@) tidak sesuai.", newVersion))
        }
        do {
            try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError(message: L("Tanda tangan aplikasi baru tidak valid."))
        }

        // 3. Stage it next to the running app (same volume, so the swap is a rename).
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError(message: L("Tidak ada izin menulis ke %@. Pakai perintah Terminal di bawah.", parent.path))
        }
        let staged = parent.appendingPathComponent(".\(current.deletingPathExtension().lastPathComponent)-update.app")
        try? fm.removeItem(at: staged)
        try await Shell.run("/usr/bin/ditto", [newApp.path, staged.path])
        _ = try? Shell.runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        mounted = false

        // 4. Hand over to a helper that waits for us to quit, swaps the bundles and relaunches.
        let script = """
        pid="$1"; app="$2"; new="$3"; old="$2.old-$$"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$app" "$old" && mv "$new" "$app"; then
          rm -rf "$old"
        else
          [ -e "$app" ] || mv "$old" "$app"
          rm -rf "$new"
        fi
        xattr -dr com.apple.quarantine "$app" 2>/dev/null
        open "$app"
        """ // l10n-ignore
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "wwwrap-update", String(getpid()), current.path, staged.path] // l10n-ignore
        try helper.run()

        DownloadManager.shared.rememberActiveForRelaunch()
        NSApp.terminate(nil)
    }

    /// Multi-connection download with progress, like any other download.
    private func download(_ url: URL, to file: URL) async throws {
        let resolved = try await DownloadResolver.resolve(RemoteRequest(url: url))
        guard resolved.resource.totalBytes > 0 else {
            throw UpdateError(message: L("File update tidak ditemukan di GitHub."))
        }
        var config = RangeDownloader.Configuration()
        config.connections = 8
        let downloader = RangeDownloader(request: resolved.request, resource: resolved.resource,
                                         fileURL: file, configuration: config)
        let total = Double(resolved.resource.totalBytes)
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.phase = .downloading(min(1, Double(downloader.progress.downloadedBytes) / total))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poll.cancel() }
        try await downloader.run()
    }
}

/// Runs command-line tools without blocking the main thread.
enum Shell {
    struct Failure: Error, LocalizedError {
        let tool: String
        let status: Int32
        let output: String
        var errorDescription: String? { "\(tool) (\(status)): \(output)" } // l10n-ignore
    }

    static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try Shell.runSync(tool, arguments)
        }.value
    }

    @discardableResult
    static func runSync(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(tool: (tool as NSString).lastPathComponent, status: process.terminationStatus, output: output)
        }
        return output
    }
}
