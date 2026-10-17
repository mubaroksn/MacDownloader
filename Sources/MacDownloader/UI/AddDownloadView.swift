import AppKit
import SwiftUI

struct AddDownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fileName = ""
    @State private var startNow = true

    private var urls: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tambah Download")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Tempel satu atau beberapa link, satu per baris.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))

            if urls.count <= 1 {
                TextField("Nama file (opsional)", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
            }

            Toggle("Mulai sekarang", isOn: $startNow)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13))

            HStack(spacing: 8) {
                Text(urls.isEmpty ? "Masukkan link http/https" : "\(urls.count) link siap")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Batal") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    let single = urls.count == 1 ? fileName.trimmingCharacters(in: .whitespaces) : ""
                    for url in urls {
                        manager.add(urlString: url, fileName: single.isEmpty ? nil : single, startNow: startNow)
                    }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(urls.isEmpty)
                .opacity(urls.isEmpty ? 0.4 : 1)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.chrome)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.lowercased().hasPrefix("http") {
                text = clip
            }
        }
    }
}
