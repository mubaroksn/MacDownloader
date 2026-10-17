import AppKit
import SwiftUI

// MARK: - Buttons

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var active = false
    var iconSize: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, active: active, iconSize: iconSize)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let size: CGFloat
        let active: Bool
        let iconSize: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(active || hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(active ? Theme.selected : (hovering || configuration.isPressed ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.primary))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration)
    }

    private struct SecondaryBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Theme.hover : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Small pieces

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.badge))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
    }
}

struct StatusPill: View {
    let status: DownloadStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(status.color.opacity(0.12)))
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(color)
                    .frame(width: max(value > 0 ? 4 : 0, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Two-option segmented control in the reference style (track + floating thumb).
struct SegmentedSwitch<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.0 == selection
                Text(option.1)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
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
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = option.0 }
                    }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.segmentTrack))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Elbow line that links a child row to its parent in the sidebar tree.
struct TreeConnector: Shape {
    var isLast: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let x = r.midX, y = r.midY, bend: CGFloat = 6
        p.move(to: CGPoint(x: x, y: r.minY))
        p.addLine(to: CGPoint(x: x, y: y - bend))
        p.addQuadCurve(to: CGPoint(x: x + bend, y: y), control: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: r.maxX, y: y))
        if !isLast {
            p.move(to: CGPoint(x: x, y: y - bend))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        return p
    }
}

// MARK: - Window

/// Hides the title, extends content under a 52pt unified title bar and keeps the
/// traffic lights vertically centered in our custom top bar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "MacDownloaderToolbar")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = true
        }
    }
}

// MARK: - Finder helpers

enum Finder {
    static func open(_ item: DownloadItem) {
        guard item.status == .completed, let path = item.destinationPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ item: DownloadItem) {
        guard let path = item.destinationPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// "You copied a download link" prompt, shown in the window and the menu bar panel.
struct ClipboardOfferBanner: View {
    let url: URL
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 2) {
                Text("Link download tersalin")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(LinkOffer.displayName(for: url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { LinkOffer.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(iconSize: 11))
                .help("Abaikan")
            Button("Download") { LinkOffer.accept(url) }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}
