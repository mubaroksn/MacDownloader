import AppKit
import SwiftUI

enum SidebarFilter: Hashable {
    case all, active, paused, completed, failed
    case category(FileCategory)

    static let statusFilters: [SidebarFilter] = [.active, .paused, .completed, .failed]
    static var allFilters: [SidebarFilter] { [.all] + statusFilters + FileCategory.allCases.map { .category($0) } }

    var title: String {
        switch self {
        case .all: return "Semua Download"
        case .active: return "Mengunduh"
        case .paused: return "Dijeda"
        case .completed: return "Selesai"
        case .failed: return "Gagal"
        case .category(let c): return c.label
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .active: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .category(let c): return c.symbol
        }
    }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.status == .downloading || item.status == .queued
        case .paused: return item.status == .paused
        case .completed: return item.status == .completed
        case .failed: return item.status == .failed
        case .category(let c): return item.category == c
        }
    }

    var isCategory: Bool { if case .category = self { return true } else { return false } }
}

enum AppPage { case downloads, browser }
enum SidebarTab: Hashable { case status, category }

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: UIState
    @State private var page: AppPage = .downloads
    @State private var filter: SidebarFilter = .all
    @State private var tab: SidebarTab = .status
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var sidebarVisible = true
    @State private var pendingDelete = Set<UUID>()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Hairline()
            HStack(spacing: 0) {
                Rail(page: $page)
                Hairline(vertical: true)
                if page == .downloads && sidebarVisible {
                    SidebarPanel(filter: $filter, tab: $tab, search: $search,
                                 onAdd: { ui.showAddSheet = true },
                                 onCollapse: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } })
                        .frame(width: 272)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Hairline(vertical: true)
                }
                Group {
                    switch page {
                    case .downloads:
                        DownloadsPage(filter: $filter, tab: $tab, search: $search, selection: $selection,
                                      sidebarVisible: $sidebarVisible,
                                      onDelete: { ids in pendingDelete = ids; confirmDelete = true })
                    case .browser:
                        BrowserPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
            }
        }
        .background(Theme.chrome)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .sheet(isPresented: $ui.showAddSheet) {
            AddDownloadView().environmentObject(manager)
        }
        .confirmationDialog("Hapus \(pendingDelete.count) download?", isPresented: $confirmDelete) {
            Button("Hapus dari daftar") {
                manager.remove(pendingDelete, deleteFiles: false)
                selection.subtract(pendingDelete)
            }
            Button("Hapus beserta file", role: .destructive) {
                manager.remove(pendingDelete, deleteFiles: true)
                selection.subtract(pendingDelete)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let web = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            web.forEach { manager.add(urlString: $0.absoluteString) }
            return !web.isEmpty
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        let totalSpeed = manager.items.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speed }
        HStack(spacing: 10) {
            Color.clear.frame(width: 70) // traffic lights
            AppMark()
            Text("MacDownloader")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if totalSpeed > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    Text(Format.speed(totalSpeed)).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.hover))
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(LocalServer.shared.isRunning ? Theme.green : Theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(LocalServer.shared.isRunning ? "Browser terhubung" : "Browser tidak terhubung")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Theme.border))
        }
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(Theme.chrome)
    }
}

/// Monochrome logo tile in the spirit of the reference's cube mark.
struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.primary)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onPrimary)
            )
    }
}

// MARK: - Rail

struct Rail: View {
    @Binding var page: AppPage

    var body: some View {
        VStack(spacing: 8) {
            Button { page = .downloads } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(IconButtonStyle(size: 40, active: page == .downloads, iconSize: 18))
                .help("Download")
            Button { page = .browser } label: { Image(systemName: "globe") }
                .buttonStyle(IconButtonStyle(size: 40, active: page == .browser, iconSize: 18))
                .help("Integrasi browser")
            Spacer()
            SettingsButton()
        }
        .padding(.vertical, 14)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(Theme.chrome)
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle(size: 40, iconSize: 18))
                .help("Pengaturan")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle(size: 40, iconSize: 18))
                .help("Pengaturan")
        }
    }
}

// MARK: - Sidebar

struct SidebarPanel: View {
    @EnvironmentObject private var manager: DownloadManager
    @Binding var filter: SidebarFilter
    @Binding var tab: SidebarTab
    @Binding var search: String
    let onAdd: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Download")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle())
                    .help("Tambah download (⌘N)")
                Button(action: onCollapse) { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle())
                    .help("Sembunyikan panel")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 56)
            Hairline()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Cari file…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SegmentedSwitch(selection: $tab, options: [(.status, "Status"), (.category, "Kategori")])
                        .padding(.bottom, 12)

                    if tab == .status {
                        tree(root: .all, rootTitle: "Semua Download", children: SidebarFilter.statusFilters)
                    } else {
                        tree(root: .all, rootTitle: "Semua Kategori",
                             children: FileCategory.allCases.map { .category($0) })
                    }

                    SidebarRow(title: "Buka folder download", symbol: "arrow.up.forward.square",
                               count: nil, selected: false) {
                        NSWorkspace.shared.open(manager.downloadFolder)
                    }
                    .padding(.top, 8)
                }
                .padding(12)
            }

            SummaryCard()
                .padding(12)
        }
        .background(Theme.chrome)
    }

    @ViewBuilder
    private func tree(root: SidebarFilter, rootTitle: String, children: [SidebarFilter]) -> some View {
        SidebarRow(title: rootTitle, symbol: filter == root ? "folder.fill" : "folder",
                   count: manager.items.count, selected: filter == root) { filter = root }
        ForEach(children.indices, id: \.self) { i in
            let child = children[i]
            HStack(spacing: 0) {
                TreeConnector(isLast: i == children.count - 1)
                    .stroke(Theme.border, lineWidth: 1.2)
                    .frame(width: 16)
                    .padding(.leading, 12)
                SidebarRow(title: child.title, symbol: child.symbol,
                           count: manager.items.filter { child.matches($0) }.count,
                           selected: filter == child) { filter = child }
                    .padding(.leading, 2)
            }
        }
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 { CountBadge(count: count) }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SummaryCard: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        let done = manager.items.filter { $0.status == .completed }
        let bytes = done.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        VStack(alignment: .leading, spacing: 6) {
            Text("Total diunduh")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(bytes > 0 ? Format.bytes(bytes) : "0 MB")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text("\(done.count) file selesai · \(manager.connectionsPerDownload) koneksi per file")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}
