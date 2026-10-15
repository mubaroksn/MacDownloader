import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage(SettingsKey.connections) private var connections = 8
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(SettingsKey.folder) private var folder = ""
    @AppStorage(SettingsKey.useCategoryFolders) private var useCategoryFolders = true
    @AppStorage(SettingsKey.notify) private var notify = true
    @State private var installedPath: String?

    var body: some View {
        TabView {
            general
                .tabItem { Label("Umum", systemImage: "gearshape") }
            browser
                .tabItem { Label("Browser", systemImage: "globe") }
        }
        .frame(width: 500, height: 330)
    }

    private var general: some View {
        Form {
            Stepper("Koneksi per download: \(connections)", value: $connections, in: 1...32)
            Stepper("Download bersamaan: \(maxConcurrent)", value: $maxConcurrent, in: 1...10)
            LabeledContent("Simpan ke") {
                HStack {
                    Text(manager.downloadFolder.path)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Pilih…", action: chooseFolder)
                }
            }
            Toggle("Pisahkan per kategori (Video, Musik, Dokumen…)", isOn: $useCategoryFolders)
            Toggle("Notifikasi saat download selesai", isOn: $notify)
            Text("Perubahan jumlah koneksi berlaku untuk download berikutnya.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(LocalServer.shared.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(LocalServer.shared.isRunning
                     ? "Menunggu browser di 127.0.0.1:\(LocalServer.port)"
                     : "Server lokal tidak berjalan (port \(LocalServer.port) dipakai app lain?)")
            }
            Text("Pasang ekstensi untuk Chrome, Edge, Brave, atau Arc:").bold()
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Klik **Siapkan ekstensi** di bawah. Folder ekstensi akan terbuka di Finder.")
                Text("2. Di browser, buka **chrome://extensions** lalu aktifkan **Developer mode**.")
                Text("3. Klik **Load unpacked**, lalu pilih folder **ChromeExtension** tadi.")
            }
            .font(.callout)
            HStack {
                Button("Siapkan ekstensi", action: installExtension)
                if let installedPath {
                    Text(installedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = manager.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func installExtension() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension") else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDownloader", isDirectory: true)
        let dest = base.appendingPathComponent("ChromeExtension", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            installedPath = dest.path
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            installedPath = "Gagal menyalin: \(error.localizedDescription)"
        }
    }
}
