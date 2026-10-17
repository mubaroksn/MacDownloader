import AppKit
import SwiftUI

enum ExtensionInstaller {
    /// Copies the bundled Chrome extension to Application Support and reveals it in Finder.
    static func install() -> Result<URL, Error> {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension") else {
            return .failure(DownloadError.message("Ekstensi tidak ditemukan di dalam app"))
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
    @State private var result: String?

    private let steps: [(String, String)] = [
        ("Siapkan ekstensi", "Klik tombol di bawah. Folder ekstensi akan terbuka di Finder."),
        ("Buka halaman ekstensi", "Ketik chrome://extensions di browser (Edge: edge://extensions), lalu nyalakan Developer mode."),
        ("Load unpacked", "Klik Load unpacked dan pilih folder ChromeExtension yang tadi terbuka."),
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
                        SectionTitle(title: "Pasang ekstensi", detail: "Chrome · Edge · Brave · Arc")
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
                        SectionTitle(title: "Cara kerja", detail: nil)
                        HStack(alignment: .top, spacing: 14) {
                            feature("arrow.down.circle", "Tangkap otomatis",
                                    "Download di browser langsung dialihkan ke MacDownloader.")
                            feature("cursorarrow.click.2", "Klik kanan",
                                    "Pilih \"Download dengan MacDownloader\" pada link, video, atau gambar.")
                            feature("lock", "Tetap login",
                                    "Cookie dan referrer ikut dikirim untuk situs yang butuh login.")
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
            }
        }
    }

    private var statusCard: some View {
        let running = server.isRunning
        return HStack(spacing: 14) {
            Circle()
                .fill((running ? Theme.green : Theme.red).opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Circle().fill(running ? Theme.green : Theme.red).frame(width: 10, height: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(running ? "Siap menerima download dari browser" : "Server lokal tidak berjalan")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(running
                     ? "Mendengarkan di 127.0.0.1:\(LocalServer.port), hanya dari Mac ini."
                     : "Port \(LocalServer.port) mungkin dipakai aplikasi lain. Tutup aplikasi itu lalu buka ulang MacDownloader.")
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
