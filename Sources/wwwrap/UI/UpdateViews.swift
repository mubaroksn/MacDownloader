import SwiftUI

/// "Update sekarang" with live progress; shared by the downloads-page banner and Settings › Tentang.
struct UpdateButton: View {
    let version: String
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        switch updater.phase {
        case .idle:
            Button(L("Update sekarang")) { updater.install(version: version) }
                .buttonStyle(PrimaryButtonStyle())
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressBar(value: fraction, color: Theme.primary)
                    .frame(width: 90)
                Text(L("Mengunduh %ld%%", Int(fraction * 100)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Memasang…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed:
            Button(L("Coba lagi")) { updater.install(version: version) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}

/// Shown above the file list when a newer release exists.
struct UpdateBanner: View {
    let version: String
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Versi %@ tersedia", version))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Group {
                    if let message = failure {
                        Text(message).foregroundStyle(Theme.red)
                    } else {
                        Text(L("Sekali klik: diunduh, dipasang, lalu app dibuka lagi. Download yang berjalan dilanjutkan."))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !updater.isBusy {
                Button { UpdateChecker.shared.dismissBanner() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(iconSize: 11))
                    .help(L("Nanti saja"))
            }
            UpdateButton(version: version)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private var failure: String? {
        if case .failed(let message) = updater.phase { return message }
        return nil
    }
}
