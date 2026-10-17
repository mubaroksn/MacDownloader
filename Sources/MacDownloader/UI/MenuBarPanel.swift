import AppKit
import SwiftUI

/// Menu bar icon. Deliberately static (no live speed text): redrawing the status item
/// every tick would wake the WindowServer twice a second for the whole download.
struct MenuBarIcon: View {
    let active: Bool
    var body: some View {
        Image(systemName: active ? "arrow.down.circle.fill" : "arrow.down.circle")
    }
}

/// Compact companion shown from the menu bar: what's running, how fast, and quick actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: UIState
    @Environment(\.openWindow) private var openWindow

    private var visible: [DownloadItem] {
        let active = manager.items.filter { [.downloading, .queued, .paused].contains($0.status) }
        let recent = manager.items.filter { $0.status == .completed || $0.status == .failed }
        return Array((active + recent).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacDownloader")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Spacer()
                if SystemActivity.shared.isPreventingSleep {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .help("Mac dicegah tidur selama download berjalan")
                }
            }
            .padding(14)

            Hairline()

            if visible.isEmpty {
                Text("Belum ada download")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { item in
                        MenuBarRow(item: item)
                    }
                }
                .padding(.vertical, 6)
            }

            Hairline()

            HStack(spacing: 8) {
                if manager.items.contains(where: { [.downloading, .queued].contains($0.status) }) {
                    Button { manager.pauseAll() } label: { Label("Jeda semua", systemImage: "pause.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                } else if manager.items.contains(where: { [.paused, .failed].contains($0.status) }) {
                    Button { manager.resumeAll() } label: { Label("Lanjutkan", systemImage: "play.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button {
                    showMainWindow()
                    ui.showAddSheet = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle())
                    .help("Tambah download")
                Button("Buka") { showMainWindow() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .labelStyle(CompactLabelStyle())
            .padding(12)
        }
        .frame(width: 340)
        .background(Theme.chrome)
    }

    private var summary: String {
        let active = manager.activeCount
        if active == 0 { return "Tidak ada download aktif" }
        let speed = Format.speed(manager.totalSpeed)
        return speed.isEmpty ? "\(active) sedang mengunduh" : "\(active) sedang mengunduh · \(speed)"
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MacDownloaderApp.mainWindowID) == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MacDownloaderApp.mainWindowID)
        }
    }
}

private struct MenuBarRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .completed || item.status == .failed {
                    Text(item.status == .failed ? (item.errorMessage ?? "Gagal") : "Selesai · \(Format.bytes(item.totalBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(item.status == .failed ? Theme.red : Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    ProgressBar(value: item.progress, color: item.status.color)
                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Group {
                switch item.status {
                case .downloading, .queued:
                    Button { manager.pause([item.id]) } label: { Image(systemName: "pause.fill") }
                case .paused, .failed:
                    Button { manager.resume([item.id]) } label: { Image(systemName: "play.fill") }
                case .completed:
                    Button { Finder.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                }
            }
            .buttonStyle(IconButtonStyle(iconSize: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear).padding(.horizontal, 4))
        .onHover { hovering = $0 }
    }

    private var detail: String {
        switch item.status {
        case .downloading:
            var parts = ["\(Int(item.progress * 100))%"]
            if item.speed > 0 { parts.append(Format.speed(item.speed)) }
            if let eta = item.eta { parts.append(Format.duration(eta)) }
            return parts.joined(separator: " · ")
        case .queued: return "Antri"
        case .paused: return "Dijeda · \(Int(item.progress * 100))%"
        default: return ""
        }
    }
}
