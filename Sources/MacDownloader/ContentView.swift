import AppKit
import SwiftUI

enum SidebarFilter: Hashable {
    case all, active, completed, failed
    case category(FileCategory)
}

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: UIState
    @State private var filter: SidebarFilter? = .all
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false

    private var filtered: [DownloadItem] {
        manager.items.filter { item in
            switch filter ?? .all {
            case .all: return true
            case .active: return [.downloading, .queued, .paused].contains(item.status)
            case .completed: return item.status == .completed
            case .failed: return item.status == .failed
            case .category(let c): return item.category == c
            }
        }
    }

    private var selectedItems: [DownloadItem] { manager.items.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                table
                Divider()
                statusBar
            }
            .toolbar { toolbar }
        }
        .sheet(isPresented: $ui.showAddSheet) {
            AddDownloadView().environmentObject(manager)
        }
        .confirmationDialog("Hapus \(selection.count) download?", isPresented: $confirmDelete) {
            Button("Hapus dari daftar") { manager.remove(selection, deleteFiles: false); selection.removeAll() }
            Button("Hapus beserta file", role: .destructive) {
                manager.remove(selection, deleteFiles: true); selection.removeAll()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let web = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            web.forEach { manager.add(urlString: $0.absoluteString) }
            return !web.isEmpty
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Download") {
                row("Semua", "tray.full", .all, count: manager.items.count)
                row("Berjalan", "arrow.down.circle", .active,
                    count: manager.items.filter { [.downloading, .queued, .paused].contains($0.status) }.count)
                row("Selesai", "checkmark.circle", .completed,
                    count: manager.items.filter { $0.status == .completed }.count)
                row("Gagal", "exclamationmark.triangle", .failed,
                    count: manager.items.filter { $0.status == .failed }.count)
            }
            Section("Kategori") {
                ForEach(FileCategory.allCases) { c in
                    row(c.label, c.symbol, .category(c), count: manager.items.filter { $0.category == c }.count)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    private func row(_ title: String, _ symbol: String, _ tag: SidebarFilter, count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(tag)
    }

    // MARK: Table

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Nama") { item in
                HStack(spacing: 8) {
                    Image(systemName: item.category.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName).lineLimit(1).truncationMode(.middle)
                        if let error = item.errorMessage, item.status == .failed {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                }
                .help(item.url.absoluteString)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Ukuran") { item in
                Text(Format.bytes(item.totalBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)

            TableColumn("Progres") { item in
                HStack(spacing: 6) {
                    ProgressView(value: item.status == .completed ? 1 : item.progress)
                        .progressViewStyle(.linear)
                        .tint(tint(for: item.status))
                    Text(item.status == .completed ? "100%" : (item.totalBytes > 0
                        ? "\(Int(item.progress * 100))%" : Format.bytes(item.downloadedBytes)))
                        .font(.caption).monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn("Kecepatan") { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.status == .downloading ? Format.speed(item.speed) : "").monospacedDigit()
                    if item.status == .downloading && item.activeConnections > 0 {
                        Text("\(item.activeConnections) koneksi").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Sisa") { item in
                Text(Format.duration(item.eta)).monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Status") { item in
                Text(item.status.label).foregroundStyle(item.status == .failed ? .red : .primary)
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            for id in ids { if let item = manager.item(id) { open(item) } }
        }
        .overlay {
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Belum ada download").font(.headline)
                    Text("Klik + atau tekan ⌘N, tarik link ke jendela ini,\natau unduh dari browser lewat ekstensi.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let items = manager.items.filter { ids.contains($0.id) }
        if items.contains(where: { [.paused, .failed].contains($0.status) }) {
            Button("Lanjutkan") { manager.resume(ids) }
        }
        if items.contains(where: { [.downloading, .queued].contains($0.status) }) {
            Button("Jeda") { manager.pause(ids) }
        }
        if items.count == 1, let item = items.first, item.status == .completed {
            Button("Buka") { open(item) }
            Button("Tampilkan di Finder") { reveal(item) }
        }
        if items.contains(where: { [.paused, .failed].contains($0.status) }) {
            Button("Ulang dari awal") { manager.restart(ids) }
        }
        Divider()
        Button("Salin Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Hapus…", role: .destructive) { selection = ids; confirmDelete = true }
    }

    // MARK: Toolbar & status

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { ui.showAddSheet = true } label: { Label("Tambah", systemImage: "plus") }
                .help("Tambah download (⌘N)")
            Button { manager.resume(selection) } label: { Label("Lanjutkan", systemImage: "play.fill") }
                .disabled(!selectedItems.contains { [.paused, .failed].contains($0.status) })
                .help("Lanjutkan")
            Button { manager.pause(selection) } label: { Label("Jeda", systemImage: "pause.fill") }
                .disabled(!selectedItems.contains { [.downloading, .queued].contains($0.status) })
                .help("Jeda")
            Button { confirmDelete = true } label: { Label("Hapus", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .help("Hapus")
            Button {
                if let item = selectedItems.first, item.status == .completed { reveal(item) }
                else { NSWorkspace.shared.open(manager.downloadFolder) }
            } label: { Label("Folder", systemImage: "folder") }
                .help("Tampilkan di Finder")
        }
    }

    private var statusBar: some View {
        let active = manager.items.filter { $0.status == .downloading }
        let total = active.reduce(0) { $0 + $1.speed }
        return HStack {
            Text(active.isEmpty ? "Tidak ada download aktif" : "\(active.count) sedang mengunduh")
            Spacer()
            if total > 0 { Text("Total \(Format.speed(total))").monospacedDigit() }
            Circle()
                .fill(LocalServer.shared.isRunning ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(LocalServer.shared.isRunning ? "Browser terhubung" : "Integrasi browser mati")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func tint(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .paused, .queued: return .orange
        case .downloading: return .accentColor
        }
    }

    private func open(_ item: DownloadItem) {
        guard item.status == .completed, let path = item.destinationPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func reveal(_ item: DownloadItem) {
        guard let path = item.destinationPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
