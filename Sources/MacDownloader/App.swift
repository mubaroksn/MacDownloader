import AppKit
import SwiftUI

@main
struct MacDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DownloadManager.shared
    @StateObject private var ui = UIState.shared

    var body: some Scene {
        WindowGroup("MacDownloader") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(ui)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Tambah Download…") { ui.showAddSheet = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Download") {
                Button("Lanjutkan Semua") { manager.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Jeda Semua") { manager.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Bersihkan yang Selesai") { manager.removeCompleted() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var showAddSheet = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LocalServer.shared.start()

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
            }
        }
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
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
