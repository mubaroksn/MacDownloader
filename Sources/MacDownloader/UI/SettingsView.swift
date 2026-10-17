import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var server = LocalServer.shared
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage(SettingsKey.connections) private var connections = 8
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(SettingsKey.folder) private var folder = ""
    @AppStorage(SettingsKey.useCategoryFolders) private var useCategoryFolders = true
    @AppStorage(SettingsKey.notify) private var notify = true
    @AppStorage(SettingsKey.preventSleep) private var preventSleep = true
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKey.monitorClipboard) private var monitorClipboard = true
    @State private var installedPath: String?

    var body: some View {
        TabView {
            general
                .tabItem { Label("Umum", systemImage: "gearshape") }
            browser
                .tabItem { Label("Browser", systemImage: "globe") }
        }
        .frame(width: 520, height: 380)
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
            Toggle("Cegah Mac tidur saat mengunduh (layar tetap boleh mati)", isOn: $preventSleep)
                .onChange(of: preventSleep) { _ in manager.refreshSystemActivity() }
            Toggle("Tampilkan ikon di menu bar", isOn: $showMenuBar)
            Toggle("Tawarkan download saat link file disalin (semua browser)", isOn: $monitorClipboard)
                .onChange(of: monitorClipboard) { ClipboardMonitor.shared.setEnabled($0) }
            Text("Perubahan jumlah koneksi berlaku untuk download berikutnya.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(server.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(server.isRunning
                     ? "Menunggu browser di 127.0.0.1:\(String(LocalServer.port))"
                     : "Server lokal tidak berjalan (port \(String(LocalServer.port)) dipakai app lain?)")
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
        switch ExtensionInstaller.install() {
        case .success(let url): installedPath = url.path
        case .failure(let error): installedPath = "Gagal menyalin: \(error.localizedDescription)"
        }
    }
}
