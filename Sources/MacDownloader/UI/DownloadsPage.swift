import AppKit
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "Terbaru", name = "Nama", size = "Ukuran"
    var id: String { rawValue }
}

struct DownloadsPage: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: UIState
    @Binding var filter: SidebarFilter
    @Binding var tab: SidebarTab
    @Binding var search: String
    @Binding var selection: Set<UUID>
    @Binding var sidebarVisible: Bool
    let onDelete: (Set<UUID>) -> Void
    @AppStorage("sortOrder") private var sort: SortOrder = .newest

    private var visibleItems: [DownloadItem] {
        var list = manager.items.filter { filter.matches($0) }
        if !search.isEmpty {
            list = list.filter { $0.fileName.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .newest: list.sort { $0.addedAt > $1.addedAt }
        case .name: list.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .size: list.sort { $0.totalBytes > $1.totalBytes }
        }
        return list
    }

    private struct FolderGroup: Identifiable {
        let category: FileCategory
        let items: [DownloadItem]
        var id: FileCategory { category }
    }

    /// Category folders shown above the file list (only for the status views).
    private var folders: [FolderGroup] {
        guard !filter.isCategory else { return [] }
        let scoped = manager.items.filter { filter.matches($0) }
        return FileCategory.allCases.compactMap { c in
            let items = scoped.filter { $0.category == c }
            return items.isEmpty ? nil : FolderGroup(category: c, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let offer = ui.clipboardOffer {
                        ClipboardOfferBanner(url: offer)
                    }
                    if let notice = ui.notice {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
                            Text(notice).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 8)
                            Button { ui.flash(nil) } label: { Image(systemName: "xmark") }
                                .buttonStyle(IconButtonStyle(iconSize: 11))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                    }
                    if !folders.isEmpty && search.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(title: "Kategori", detail: nil)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                ForEach(folders) { folder in
                                    FolderCard(category: folder.category, items: folder.items, isSelected: false) {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            filter = .category(folder.category)
                                            tab = .category
                                        }
                                    }
                                    .frame(width: 214)
                                }
                                }
                                .padding(.horizontal, 28)
                            }
                            .padding(.horizontal, -28)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "File", detail: visibleItems.isEmpty ? nil : "\(visibleItems.count)")
                        FileTable(items: visibleItems, selection: $selection, onDelete: onDelete)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if !sidebarVisible {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
                } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle())
                    .help("Tampilkan panel")
            }

            Menu {
                ForEach(SidebarFilter.allFilters, id: \.self) { f in
                    Button {
                        filter = f
                        tab = f.isCategory ? .category : .status
                    } label: { Label(f.title, systemImage: f.symbol) }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(filter.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Menu {
                Picker("Urutkan", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                    Text(sort.rawValue)
                }
            }
            .menuStyle(.button)
            .buttonStyle(SecondaryButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()

            let canResume = manager.items.contains { [.paused, .failed].contains($0.status) }
            let canPause = manager.items.contains { [.downloading, .queued].contains($0.status) }
            if canPause {
                Button { manager.pauseAll() } label: { Label("Jeda semua", systemImage: "pause.fill") }
                    .buttonStyle(SecondaryButtonStyle())
            } else if canResume {
                Button { manager.resumeAll() } label: { Label("Lanjutkan semua", systemImage: "play.fill") }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Button { ui.showAddSheet = true } label: { Label("Tambah", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .labelStyle(CompactLabelStyle())
        .padding(.horizontal, 28)
        .frame(height: 56)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

struct SectionTitle: View {
    let title: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - File table

private enum Col {
    static let size: CGFloat = 84
    static let progress: CGFloat = 200
    static let status: CGFloat = 108
    static let actions: CGFloat = 64
    static let spacing: CGFloat = 16
}

struct FileTable: View {
    let items: [DownloadItem]
    @Binding var selection: Set<UUID>
    let onDelete: (Set<UUID>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Col.spacing) {
                Text("Nama").frame(maxWidth: .infinity, alignment: .leading)
                Text("Ukuran").frame(width: Col.size, alignment: .leading)
                Text("Progres").frame(width: Col.progress, alignment: .leading)
                Text("Status").frame(width: Col.status, alignment: .leading)
                Color.clear.frame(width: Col.actions, height: 1)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: 46)

            Hairline()

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Belum ada download")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Klik Tambah atau tekan ⌘N, tarik link ke jendela ini,\natau unduh dari browser lewat ekstensi.")
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        FileRow(item: item,
                                isSelected: selection.contains(item.id),
                                targets: selection.contains(item.id) ? selection : [item.id],
                                onSelect: { select(item.id) },
                                onDelete: onDelete)
                        if item.id != items.last?.id { Hairline().padding(.horizontal, 18) }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift), let anchor = selection.first,
                  let a = items.firstIndex(where: { $0.id == anchor }),
                  let b = items.firstIndex(where: { $0.id == id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
        }
    }
}

struct FileRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem
    let isSelected: Bool
    let targets: Set<UUID>
    let onSelect: () -> Void
    let onDelete: (Set<UUID>) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Col.spacing) {
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.bytes(item.totalBytes))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Col.size, alignment: .leading)
            progressCell.frame(width: Col.progress, alignment: .leading)
            StatusPill(status: item.status).frame(width: Col.status, alignment: .leading)
            actionsCell.frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        .background(isSelected ? Theme.selected : (hovering ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { Finder.open(item) })
        .onHover { hovering = $0 }
        .contextMenu { RowMenuItems(ids: targets, onDelete: onDelete) }
        .help(item.url.absoluteString)
    }

    private var nameCell: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.canvas)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                .overlay(
                    Image(systemName: item.category.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if item.status == .failed, let error = item.errorMessage {
                        Text(error).foregroundStyle(Theme.red)
                    } else if item.status == .downloading && item.activeConnections > 0 {
                        Text("\(item.url.host ?? "") · \(item.activeConnections) koneksi")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(item.url.host ?? "").foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
        }
    }

    private var progressCell: some View {
        let value = item.status == .completed ? 1 : item.progress
        return VStack(alignment: .leading, spacing: 6) {
            ProgressBar(value: value, color: item.status.color)
            HStack(spacing: 4) {
                if item.status == .downloading && item.segments.isEmpty {
                    Text("Menghubungkan…")
                } else if item.status == .downloading {
                    Text(Format.bytes(item.downloadedBytes)).foregroundStyle(Theme.textPrimary)
                    if item.speed >= 1 { Text("· \(Format.speed(item.speed))") }
                    if let eta = item.eta { Text("· \(Format.duration(eta))") }
                } else if item.totalBytes > 0 {
                    Text("\(Int(value * 100))%").foregroundStyle(Theme.textPrimary)
                    if item.status == .completed, let date = item.completedAt {
                        Text("· \(date.formatted(date: .numeric, time: .shortened))")
                    } else if item.downloadedBytes > 0 {
                        Text("· \(Format.bytes(item.downloadedBytes))")
                    }
                } else {
                    Text(Format.bytes(item.downloadedBytes)).foregroundStyle(Theme.textPrimary)
                }
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
    }

    private var actionsCell: some View {
        HStack(spacing: 2) {
            switch item.status {
            case .downloading, .queued:
                Button { manager.pause([item.id]) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(IconButtonStyle(iconSize: 12)).help("Jeda")
            case .paused, .failed:
                Button { manager.resume([item.id]) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(IconButtonStyle(iconSize: 12)).help("Lanjutkan")
            case .completed:
                Button { Finder.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle(iconSize: 13)).help("Tampilkan di Finder")
            }
            Menu {
                RowMenuItems(ids: targets, onDelete: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .opacity(hovering || isSelected ? 1 : 0.55)
    }
}

struct RowMenuItems: View {
    @EnvironmentObject private var manager: DownloadManager
    let ids: Set<UUID>
    let onDelete: (Set<UUID>) -> Void

    var body: some View {
        let items = manager.items.filter { ids.contains($0.id) }
        if items.contains(where: { [.paused, .failed].contains($0.status) }) {
            Button("Lanjutkan") { manager.resume(ids) }
        }
        if items.contains(where: { [.downloading, .queued].contains($0.status) }) {
            Button("Jeda") { manager.pause(ids) }
        }
        if items.count == 1, let item = items.first, item.status == .completed {
            Button("Buka") { Finder.open(item) }
            Button("Tampilkan di Finder") { Finder.reveal(item) }
        }
        if items.contains(where: { [.paused, .failed].contains($0.status) }) {
            Button("Ulang dari awal") { manager.restart(ids) }
        }
        Divider()
        Button("Salin link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button(items.count > 1 ? "Hapus \(items.count) item…" : "Hapus…", role: .destructive) { onDelete(ids) }
    }
}
