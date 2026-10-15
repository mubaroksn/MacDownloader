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
        VStack(alignment: .leading, spacing: 14) {
            Text("Tambah Download").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Link (satu per baris)").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            if urls.count <= 1 {
                TextField("Nama file (opsional)", text: $fileName)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Mulai sekarang", isOn: $startNow)

            HStack {
                Text(urls.isEmpty ? "Masukkan link http/https" : "\(urls.count) link siap")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Batal") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    let single = urls.count == 1 ? fileName.trimmingCharacters(in: .whitespaces) : ""
                    for url in urls {
                        manager.add(urlString: url, fileName: single.isEmpty ? nil : single, startNow: startNow)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urls.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.lowercased().hasPrefix("http") {
                text = clip
            }
        }
    }
}
