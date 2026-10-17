import AppKit
import SwiftUI

enum ExtensionInstaller {
    /// Copies the bundled Chrome extension to Application Support and reveals it in Finder.
    static func install() -> Result<URL, Error> {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension") else {
            return .failure(CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Ekstensi tidak ditemukan di dalam app"]))
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDownloader", isDirectory: true)
        let dest = base.appendingPathComponent("ChromeExtension", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: source, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }
}

struct BrowserPage: View {
    @ObservedObject private var server = LocalServer.shared
    @AppStorage(SettingsKey.monitorClipboard) private var monitorClipboard = true
    @State private var result: String?

    private let steps: [(String, String)] = [
        ("Siapkan ekstensi", "Klik tombol di bawah. Folder ekstensi akan terbuka di Finder."),
        ("Buka halaman ekstensi",
         "Ketik chrome://extensions di address bar (berlaku juga di Dia, Arc, Brave; Edge: edge://extensions), lalu nyalakan Developer mode."),
        ("Load unpacked", "Klik Load unpacked dan pilih folder ChromeExtension yang tadi terbuka."),
        ("Cek koneksi", "Dalam 30 detik, status di atas berubah jadi \"Ekstensi terhubung\". Kalau tidak, muat ulang ekstensinya."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Integrasi Browser")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 56)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    statusCard

                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "Pasang ekstensi", detail: "Chrome · Edge · Brave · Arc · Dia")
                        VStack(spacing: 0) {
                            ForEach(steps.indices, id: \.self) { i in
                                HStack(alignment: .top, spacing: 14) {
                                    Text("\(i + 1)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(Theme.canvas))
                                        .overlay(Circle().strokeBorder(Theme.border))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(steps[i].0)
                                            .font(.system(size: 13.5, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(steps[i].1)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(18)
                                if i < steps.count - 1 { Hairline().padding(.horizontal, 18) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))

                        HStack(spacing: 12) {
                            Button {
                                switch ExtensionInstaller.install() {
                                case .success(let url): result = url.path
                                case .failure(let error): result = "Gagal: \(error.localizedDescription)"
                                }
                            } label: { Label("Siapkan ekstensi", systemImage: "puzzlepiece.extension") }
                                .buttonStyle(PrimaryButtonStyle())
                            if let result {
                                Text(result)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .labelStyle(CompactLabelStyle())
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "Tanpa ekstensi", detail: "Safari, Firefox, atau app apa pun")
                        HStack(alignment: .top, spacing: 14) {
                            feature("doc.on.clipboard", "Salin link",
                                    "Klik kanan link download › Copy Link. MacDownloader langsung menawarkan untuk mengunduhnya.")
                            feature("link", "Link berbagi dikenali",
                                    "Google Drive, Google Docs, Dropbox, GitHub, SharePoint, MediaFire, dan Pixeldrain diubah ke file aslinya.")
                            feature("arrow.down.doc", "Tarik & lepas",
                                    "Tarik link ke jendela MacDownloader, atau tempel di tombol Tambah.")
                        }
                        Toggle("Tawarkan download saat link file disalin", isOn: $monitorClipboard)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 13))
                            .onChange(of: monitorClipboard) { ClipboardMonitor.shared.setEnabled($0) }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "Cara kerja ekstensi", detail: nil)
                        HStack(alignment: .top, spacing: 14) {
                            feature("arrow.down.circle", "Tangkap otomatis",
                                    "Download di browser langsung dialihkan ke MacDownloader.")
                            feature("cursorarrow.click.2", "Klik kanan",
                                    "Pilih \"Download dengan MacDownloader\" pada link, video, atau gambar.")
                            feature("lock", "Tetap login",
                                    "Cookie dan referrer ikut dikirim, jadi file Google Drive pribadi dan situs login tetap bisa.")
                            feature("arrow.uturn.backward", "Tidak pernah gagal diam-diam",
                                    "Kalau MacDownloader tidak bisa mengambil file-nya, download dikembalikan ke browser.")
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
            }
        }
    }

    private var statusCard: some View {
        let connected = server.extensionConnected
        let color = !server.isRunning ? Theme.red : (connected ? Theme.green : Theme.orange)
        let title = !server.isRunning ? "Server lokal tidak berjalan"
            : connected ? "Ekstensi terhubung" + (server.extensionBrowser.map { " · \($0)" } ?? "")
            : "Ekstensi belum terhubung"
        let detail = !server.isRunning
            ? "Port \(String(LocalServer.port)) mungkin dipakai aplikasi lain. Tutup aplikasi itu lalu buka ulang MacDownloader."
            : connected ? "Download di browser akan otomatis diambil alih MacDownloader."
            : "Pasang ekstensi di bawah. Sementara itu, salin link download dan MacDownloader akan menawarkannya."
        return HStack(spacing: 14) {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Circle().fill(color).frame(width: 10, height: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}
