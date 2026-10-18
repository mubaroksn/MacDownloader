import AppKit
import Foundation
import ServiceManagement

// MARK: - Open at login

/// "Buka saat login" via `SMAppService` (macOS 13+). The system owns the truth: we read the
/// status back instead of trusting a stored flag, because the user can also switch it off in
/// System Settings › General › Login Items.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Updates

/// Checks GitHub for a newer release. Uses the `/releases/latest` redirect rather than the
/// REST API, which is rate-limited per IP for anonymous callers.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    static let repo = "mubaroksn/wwwrap"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// The DMG attached to release `version`.
    static func dmgURL(for version: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/download/v\(version)/wwwrap-\(version).dmg")!
    }

    /// The downloads-page banner can be closed per version.
    var bannerDismissed: Bool {
        guard let v = availableVersion else { return true }
        return UserDefaults.standard.string(forKey: "updateBannerDismissed") == v
    }

    func dismissBanner() {
        UserDefaults.standard.set(availableVersion, forKey: "updateBannerDismissed")
        objectWillChange.send()
    }
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash" // l10n-ignore

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var availableVersion: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    private init() {}

    /// Checks at most once a day on its own; `force` is for the button.
    func check(force: Bool = false) {
        if state == .checking { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < 20 * 3600 { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: Self.releasesPage, timeoutInterval: 15)
                request.httpMethod = "HEAD"
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let final = response.url?.absoluteString, let range = final.range(of: "/tag/v") else {
                    throw URLError(.badServerResponse)
                }
                let latest = String(final[range.upperBound...])
                lastChecked = Date()
                state = Self.isNewer(latest, than: currentVersion) ? .available(latest) : .upToDate
            } catch {
                state = .failed(L("Tidak bisa menghubungi GitHub"))
            }
        }
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    func openReleasesPage() { NSWorkspace.shared.open(Self.releasesPage) }
}

// MARK: - Appearance

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("Ikut sistem")
        case .light: return L("Terang")
        case .dark: return L("Gelap")
        }
    }

    /// Applies the stored choice. A `-appearance` launch argument (CI screenshots) wins.
    static func applyStored() {
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["appearance"] != nil { return }
        let mode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.themeMode) ?? "") ?? .system
        mode.apply()
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Main window

enum MainWindow {
    /// Brings the main window forward, opening it if it was closed.
    @MainActor
    static func show(open: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WwwrapApp.mainWindowID) == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
    }
}
