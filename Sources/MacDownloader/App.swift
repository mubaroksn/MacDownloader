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
                .frame(minWidth: 860, minHeight: 460)
        }
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DownloadManager.shared.prepareForQuit() }
    }

    /// Keep running after the window closes so the browser extension can still hand over downloads.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
