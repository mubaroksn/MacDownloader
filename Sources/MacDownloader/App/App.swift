import AppKit
import SwiftUI

@main
struct MacDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DownloadManager.shared
    @StateObject private var ui = UIState.shared
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true
    /// Changing the language rebuilds every view (see `.id` below), so text switches without a restart.
    @AppStorage(Lang.key) private var appLanguage = ""

    init() {
        let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDownloader/downloads.json")
        let defaults = UserDefaults.standard
        let existing = FileManager.default.fileExists(atPath: state.path)
            || [SettingsKey.statsDay, SettingsKey.connections, SettingsKey.speedMode, "sortOrder"]
                .contains { defaults.object(forKey: $0) != nil }
        Lang.migrate(existingInstall: existing)
        Lang.installEngineHook()
    }

    var body: some Scene {
        WindowGroup("MacDownloader", id: MacDownloaderApp.mainWindowID) {
            ContentView()
                .environmentObject(manager)
                .environmentObject(ui)
                .id(appLanguage)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Tambah Download…")) { ui.showAddSheet = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            CommandMenu("Download") {
                Button(L("Lanjutkan Semua")) { manager.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L("Jeda Semua")) { manager.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Picker(L("Kecepatan"), selection: $manager.speedMode) {
                    ForEach(SpeedMode.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button(L("Bersihkan yang Selesai")) { manager.removeCompleted() }
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environmentObject(manager)
                .environmentObject(ui)
                .id(appLanguage)
        } label: {
            MenuBarIcon(active: manager.activeCount > 0)
        }
        .menuBarExtraStyle(.window)
    }

    static let mainWindowID = "main"
}

/// ⌘, opens the Settings page inside the main window (same look as the rest of the app).
private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Pengaturan…")) {
            UIState.shared.openSettings()
            MainWindow.show { openWindow(id: MacDownloaderApp.mainWindowID) }
        }
        .keyboardShortcut(",")
    }
}

@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var showAddSheet = false
    /// Which page the main window shows (rail selection).
    @Published var page: AppPage
    @Published var settingsSection: SettingsSection
    /// A download link the user just copied elsewhere (clipboard monitor).
    @Published var clipboardOffer: URL?
    /// Short status line shown at the top of the downloads page.
    @Published private(set) var notice: String?
    private var noticeToken = 0

    private init() {
        // -startPage browser|settings and -settingsSection <id> are used by CI screenshots.
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "startPage") {
        case "browser": page = .browser
        case "settings": page = .settings
        default: page = .downloads
        }
        settingsSection = SettingsSection(rawValue: defaults.string(forKey: "settingsSection") ?? "") ?? .general
    }

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        page = .settings
    }

    func flash(_ text: String?, autoHide: Bool = true) {
        noticeToken += 1
        notice = text
        guard autoHide, text != nil else { return }
        let token = noticeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self?.noticeToken == token { self?.notice = nil }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            LocalServer.shared.dispatcher = DownloadManager.shared
        }
        LocalServer.shared.start()
        MainActor.assumeIsolated {
            LinkOffer.registerCategories()
            ClipboardMonitor.shared.setEnabled(UserDefaults.standard.object(forKey: SettingsKey.monitorClipboard) as? Bool ?? true)
            ThemeMode.applyStored()
            if UserDefaults.standard.object(forKey: SettingsKey.autoCheckUpdates) as? Bool ?? true {
                UpdateChecker.shared.check()
            }
        }

        // Optional overrides, used by CI screenshots: -appearance dark|light
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        // -snapshotPath /path/shot.png [-snapshotDelay 8]: render the main window to a PNG.
        if let path = UserDefaults.standard.string(forKey: "snapshotPath") {
            let delay = UserDefaults.standard.double(forKey: "snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 6)) {
                Self.snapshot(to: URL(fileURLWithPath: path))
                if let panelPath = UserDefaults.standard.string(forKey: "snapshotMenuBarPath") {
                    MainActor.assumeIsolated { Self.snapshotMenuBarPanel(to: URL(fileURLWithPath: panelPath)) }
                }
            }
        }
    }

    /// Renders the menu bar panel offscreen (a MenuBarExtra window only exists after a click).
    @MainActor
    private static func snapshotMenuBarPanel(to url: URL) {
        let root = MenuBarPanel()
            .environmentObject(DownloadManager.shared)
            .environmentObject(UIState.shared)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DownloadManager.shared.prepareForQuit() }
    }

    /// Keep running after the window closes so the browser extension can still hand over downloads.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8)) // l10n-ignore
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
