import AppKit
import Foundation

/// MacDownloader was renamed wwwrap in 1.7.0, which also changed the bundle id and the
/// Application Support folder. On first launch this brings the old settings and download
/// list over, then quits and trashes the old app (both would fight over port 9614).
///
/// The old folder is copied, not moved: a browser extension loaded with "Load unpacked"
/// from ~/Library/Application Support/MacDownloader/ChromeExtension keeps working.
enum LegacyMigration {
    static let oldBundleID = "com.mubaroksn.macdownloader" // l10n-ignore
    static let oldSupportFolder = "MacDownloader" // l10n-ignore
    private static let doneKey = "migratedFromMacDownloader"
    private static let announceKey = "announceRenameFromMacDownloader"

    /// Must run before anything reads settings (first thing in the App initializer).
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        var imported = false

        if let own = Bundle.main.bundleIdentifier, own != oldBundleID,
           let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty {
            var mine = defaults.persistentDomain(forName: own) ?? [:]
            for (key, value) in old where mine[key] == nil { mine[key] = value }
            defaults.setPersistentDomain(mine, forName: own)
            imported = true
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldState = base.appendingPathComponent(oldSupportFolder).appendingPathComponent("downloads.json")
        let newFolder = base.appendingPathComponent("wwwrap", isDirectory: true)
        let newState = newFolder.appendingPathComponent("downloads.json")
        if fm.fileExists(atPath: oldState.path), !fm.fileExists(atPath: newState.path) {
            try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: oldState, to: newState)) != nil { imported = true }
        }

        defaults.set(true, forKey: doneKey)
        if imported { defaults.set(true, forKey: announceKey) }
    }

    /// After launch: retire the old app and say what happened (once).
    @MainActor
    static func finishAfterLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: announceKey) else { return }
        defaults.removeObject(forKey: announceKey)

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID) {
            app.terminate()
        }
        UIState.shared.flash(L("MacDownloader sekarang bernama wwwrap. Pengaturan dan riwayat download sudah dipindah."),
                             autoHide: false)

        guard let old = NSWorkspace.shared.urlForApplication(withBundleIdentifier: oldBundleID),
              old != Bundle.main.bundleURL,
              !old.path.contains("/.Trash/"), !old.path.hasPrefix("/Volumes/") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
        }
    }
}
