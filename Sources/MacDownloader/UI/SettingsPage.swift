import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, downloads, integration, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Umum"
        case .downloads: return "Download"
        case .integration: return "Integrasi"
        case .appearance: return "Tampilan"
        case .about: return "Tentang"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Folder simpan, saat login, tidur"
        case .downloads: return "Koneksi, antrean, batas kecepatan"
        case .integration: return "Ekstensi browser, clipboard"
        case .appearance: return "Tema, menu bar"
        case .about: return "Versi dan update"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .integration: return "puzzlepiece.extension"
        case .appearance: return "circle.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var section: SettingsSection
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pengaturan")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 56)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { item in
                        SettingsSidebarRow(section: item, selected: section == item,
                                           badge: item == .about && updates.availableVersion != nil) {
                            section = item
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.chrome)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(section.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if badge {
                    Circle().fill(Theme.blue).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
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

// MARK: - Page

struct SettingsPage: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 56)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch section {
                    case .general: GeneralSettings()
                    case .downloads: DownloadSettings()
                    case .integration: IntegrationSettings()
                    case .appearance: AppearanceSettings()
                    case .about: AboutSettings()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows in one bordered card, like the steps card on the browser page.
struct SettingsGroup<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: title, detail: detail)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Label + explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if divider { Hairline().padding(.horizontal, 18) }
        }
    }
}

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// "−  value  +" in the app's bordered style; steps through a fixed list of values.
struct ValueStepper<Value: Equatable>: View {
    @Binding var value: Value
    let values: [Value]
    let label: (Value) -> String

    private var index: Int { values.firstIndex(of: value) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: 28, iconSize: 11))
                .disabled(index == 0)
            Text(label(value))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 76)
            Button { step(1) } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 28, iconSize: 11))
                .disabled(index == values.count - 1)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }

    private func step(_ delta: Int) {
        let next = min(values.count - 1, max(0, index + delta))
        value = values[next]
    }
}

/// The three speed presets as icon segments (downloads page, menu bar, settings).
struct SpeedModePicker: View {
    @EnvironmentObject private var manager: DownloadManager
    var compact = false
    /// Icons only, for narrow spots (the speed card on the downloads page).
    var iconsOnly = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SpeedMode.allCases) { mode in
                let isOn = manager.speedMode == mode
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol).font(.system(size: 12, weight: .medium))
                    if !iconsOnly {
                        Text(mode.label).font(.system(size: compact ? 12 : 12.5, weight: isOn ? .medium : .regular))
                    }
                }
                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: iconsOnly ? nil : .infinity)
                .frame(width: iconsOnly ? 32 : nil)
                .frame(height: compact ? 26 : 28)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.segmentThumb)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: ns)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { manager.speedMode = mode }
                }
                .help(tooltip(for: mode))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.segmentTrack))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private func tooltip(for mode: SpeedMode) -> String {
        let cap = manager.limit(for: mode)
        return mode.label + (cap == 0 ? " · tanpa batas kecepatan" : " · maksimal \(Format.speed(Double(cap))) untuk semua download")
    }
}

enum SpeedPresets {
    /// KB/s values offered for the Hemat and Senyap caps.
    static let valuesKB: [Int] = [256, 512, 1024, 2048, 3072, 5120, 8192, 10240, 15360, 20480, 30720, 51200]

    static func label(_ kb: Int) -> String {
        if kb < 1024 { return "\(kb) KB/s" }
        let mb = Double(kb) / 1024
        return mb == mb.rounded() ? "\(Int(mb)) MB/s" : String(format: "%.1f MB/s", mb)
    }
}

// MARK: - Umum

private struct GeneralSettings: View {
    @EnvironmentObject private var manager: DownloadManager
    @ObservedObject private var login = LoginItem.shared
    @AppStorage(SettingsKey.folder) private var folder = ""
    @AppStorage(SettingsKey.useCategoryFolders) private var useCategoryFolders = true
    @AppStorage(SettingsKey.notify) private var notify = true
    @AppStorage(SettingsKey.preventSleep) private var preventSleep = true

    var body: some View {
        SettingsGroup(title: "Simpan") {
            SettingsRow(title: "Folder download", detail: manager.downloadFolder.path) {
                HStack(spacing: 8) {
                    Button("Buka") { NSWorkspace.shared.open(manager.downloadFolder) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Pilih…", action: chooseFolder)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsRow(title: "Pisahkan per kategori",
                        detail: "Video, Musik, Dokumen, dan lainnya masuk ke subfolder masing-masing.",
                        divider: false) {
                SettingsToggle(isOn: $useCategoryFolders)
            }
        }

        SettingsGroup(title: "Sistem") {
            SettingsRow(title: "Buka saat login",
                        detail: login.needsApproval
                            ? "Menunggu izin di System Settings › General › Login Items."
                            : (login.lastError ?? "MacDownloader berjalan di latar saat Mac menyala, siap menerima download dari browser.")) {
                HStack(spacing: 8) {
                    if login.needsApproval {
                        Button("Buka System Settings") { login.openSystemSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    SettingsToggle(isOn: Binding(get: { login.isEnabled || login.needsApproval },
                                                 set: { login.set($0) }))
                }
            }
            SettingsRow(title: "Cegah Mac tidur saat mengunduh",
                        detail: "Layar tetap boleh mati. Kembali normal begitu semua download selesai.") {
                SettingsToggle(isOn: $preventSleep)
                    .onChange(of: preventSleep) { _ in manager.refreshSystemActivity() }
            }
            SettingsRow(title: "Notifikasi saat selesai", detail: "Tampilkan notifikasi macOS untuk setiap file yang selesai.",
                        divider: false) {
                SettingsToggle(isOn: $notify)
            }
        }
        .onAppear { login.refresh() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = manager.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Download

private struct DownloadSettings: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage(SettingsKey.connections) private var connections = 8
    @AppStorage(SettingsKey.autoScale) private var autoScale = true
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(SettingsKey.saverLimitKB) private var saverKB = SpeedMode.defaultSaverKB
    @AppStorage(SettingsKey.quietLimitKB) private var quietKB = SpeedMode.defaultQuietKB

    var body: some View {
        SettingsGroup(title: "Koneksi") {
            SettingsRow(title: "Koneksi awal per file",
                        detail: "Berlaku untuk download berikutnya. 8 sudah cukup untuk kebanyakan server.") {
                ValueStepper(value: $connections, values: Array(1...32)) { "\($0)" }
            }
            SettingsRow(title: "Tambah koneksi otomatis",
                        detail: "Selama kecepatan masih naik, sampai 32 koneksi. Dilepas lagi kalau tidak menambah speed.") {
                SettingsToggle(isOn: $autoScale)
            }
            SettingsRow(title: "Download bersamaan", detail: "Sisanya menunggu di antrean.", divider: false) {
                ValueStepper(value: $maxConcurrent, values: Array(1...10)) { "\($0) file" }
            }
        }

        SettingsGroup(title: "Batas kecepatan", detail: "untuk semua download sekaligus") {
            SettingsRow(title: "Mode sekarang",
                        detail: "Bisa juga diganti dari halaman Download atau ikon menu bar.") {
                SpeedModePicker()
                    .frame(width: 300)
            }
            SettingsRow(title: "Hemat", detail: "Sisakan bandwidth untuk video call dan streaming.") {
                ValueStepper(value: $saverKB, values: SpeedPresets.valuesKB, label: SpeedPresets.label)
                    .onChange(of: saverKB) { _ in manager.applySpeedLimit() }
            }
            SettingsRow(title: "Senyap", detail: "Hampir tidak terasa, cocok saat meeting atau main game online.",
                        divider: false) {
                ValueStepper(value: $quietKB, values: SpeedPresets.valuesKB, label: SpeedPresets.label)
                    .onChange(of: quietKB) { _ in manager.applySpeedLimit() }
            }
        }
    }
}

// MARK: - Integrasi

private struct IntegrationSettings: View {
    @EnvironmentObject private var ui: UIState
    @ObservedObject private var server = LocalServer.shared
    @AppStorage(SettingsKey.monitorClipboard) private var monitorClipboard = true

    var body: some View {
        SettingsGroup(title: "Ekstensi browser") {
            SettingsRow(title: status.title, detail: status.detail) {
                Button("Panduan pasang") { ui.page = .browser }
                    .buttonStyle(SecondaryButtonStyle())
            }
            SettingsRow(title: "Server lokal",
                        detail: server.isRunning
                            ? "Menerima download dari ekstensi di 127.0.0.1:\(String(LocalServer.port))."
                            : "Tidak berjalan. Port \(String(LocalServer.port)) mungkin dipakai aplikasi lain.",
                        divider: false) {
                Circle().fill(server.isRunning ? Theme.green : Theme.red).frame(width: 8, height: 8)
            }
        }

        SettingsGroup(title: "Tanpa ekstensi") {
            SettingsRow(title: "Tawarkan download saat link disalin",
                        detail: "Berlaku di semua browser termasuk Safari, dan di app apa pun.",
                        divider: false) {
                SettingsToggle(isOn: $monitorClipboard)
                    .onChange(of: monitorClipboard) { ClipboardMonitor.shared.setEnabled($0) }
            }
        }
    }

    private var status: (title: String, detail: String) {
        if server.extensionConnected {
            return ("Ekstensi terhubung" + (server.extensionBrowser.map { " · \($0)" } ?? ""),
                    "Download di browser otomatis diambil alih MacDownloader.")
        }
        return ("Ekstensi belum terhubung", "Pasang untuk Chrome, Edge, Brave, Arc, Dia, atau Firefox.")
    }
}

// MARK: - Tampilan

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.themeMode) private var themeMode = ThemeMode.system.rawValue
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true

    var body: some View {
        SettingsGroup(title: "Tema") {
            SettingsRow(title: "Tampilan", detail: "Ikut sistem berganti otomatis bersama mode gelap macOS.",
                        divider: false) {
                SegmentedSwitch(selection: Binding(get: { ThemeMode(rawValue: themeMode) ?? .system },
                                                   set: { themeMode = $0.rawValue; $0.apply() }),
                                options: ThemeMode.allCases.map { ($0, $0.label) })
                    .frame(width: 300)
            }
        }

        SettingsGroup(title: "Menu bar") {
            SettingsRow(title: "Tampilkan ikon di menu bar",
                        detail: "Lihat progres, ganti mode kecepatan, dan jeda semua tanpa membuka jendela.",
                        divider: false) {
                SettingsToggle(isOn: $showMenuBar)
            }
        }
    }
}

// MARK: - Tentang

private struct AboutSettings: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheck = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.primary)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.onPrimary))
            VStack(alignment: .leading, spacing: 4) {
                Text("MacDownloader")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Versi \(updates.currentVersion)" + (updates.currentBuild.isEmpty ? "" : " (\(updates.currentBuild))"))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }

        SettingsGroup(title: "Update") {
            SettingsRow(title: statusTitle, detail: statusDetail) {
                Button {
                    updates.check(force: true)
                } label: {
                    if updates.state == .checking {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text("Cek sekarang")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(updates.state == .checking)
            }
            if let version = updates.availableVersion {
                SettingsRow(title: "Pasang versi \(version)",
                            detail: "Tempel perintah ini di Terminal. App akan ditutup, diganti, lalu dibuka lagi.") {
                    HStack(spacing: 8) {
                        Button(copied ? "Tersalin" : "Salin perintah") {
                            updates.copyInstallCommand()
                            copied = true
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button("Halaman rilis") { updates.openReleasesPage() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            SettingsRow(title: "Cek update otomatis", detail: "Sekali sehari saat app dibuka.", divider: false) {
                SettingsToggle(isOn: $autoCheck)
            }
        }

        SettingsGroup(title: "Proyek") {
            SettingsRow(title: "Kode sumber dan rilis", detail: "github.com/\(UpdateChecker.repo)", divider: false) {
                Button("Buka GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)")!) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var statusTitle: String {
        switch updates.state {
        case .idle: return "Belum dicek"
        case .checking: return "Mengecek…"
        case .upToDate: return "Sudah versi terbaru"
        case .available(let v): return "Versi \(v) tersedia"
        case .failed(let message): return message
        }
    }

    private var statusDetail: String {
        guard let date = updates.lastChecked else { return "Rilis baru diambil dari GitHub." }
        return "Terakhir dicek \(date.formatted(date: .omitted, time: .shortened))."
    }
}
