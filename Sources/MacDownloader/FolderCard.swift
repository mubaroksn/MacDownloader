import SwiftUI

/// Front panel of a folder: a raised tab on the left that slopes down to the right.
struct FolderFrontShape: Shape {
    func path(in r: CGRect) -> Path {
        let radius: CGFloat = min(14, r.height * 0.14)
        let drop = r.height * 0.1
        let tabEnd = r.minX + r.width * 0.36
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
        p.addLine(to: CGPoint(x: tabEnd - drop, y: r.minY))
        p.addCurve(to: CGPoint(x: tabEnd + drop, y: r.minY + drop),
                   control1: CGPoint(x: tabEnd, y: r.minY),
                   control2: CGPoint(x: tabEnd, y: r.minY + drop))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY + drop), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.closeSubpath()
        return p
    }
}

/// A sheet of paper peeking out of a folder, with a file glyph and extension label.
private struct Paper: View {
    let label: String
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.paper)
            .overlay(alignment: .topLeading) {
                Image(systemName: "doc")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.paperInk)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.85)))
                        .padding(.top, 22)
                        .padding(.trailing, 7)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
    }
}

/// Folder illustration drawn in code: back panel, papers, front panel and badges.
struct FolderIllustration: View {
    let fileCount: Int
    let extLabel: String
    let badges: [(symbol: String, tint: Color)]

    private let w: CGFloat = 176
    private let h: CGFloat = 128

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.folderBack)
                .frame(width: w * 0.9, height: h * 0.82)

            if fileCount > 0 {
                ZStack {
                    Paper(label: "")
                        .rotationEffect(.degrees(-7))
                        .offset(x: -w * 0.17, y: 6)
                    if fileCount > 2 {
                        Paper(label: "")
                            .rotationEffect(.degrees(6))
                            .offset(x: w * 0.15, y: 8)
                    }
                    Paper(label: extLabel)
                        .offset(x: fileCount > 1 ? w * 0.02 : 0, y: 2)
                }
                .frame(width: w * 0.36, height: h * 0.52)
                .offset(y: h * 0.08)
            }

            FolderFrontShape()
                .fill(LinearGradient(colors: [Theme.folderFrontTop, Theme.folderFrontBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(FolderFrontShape().stroke(Theme.folderEdge, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 5, y: -2)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: -6) {
                        ForEach(badges.indices, id: \.self) { i in
                            Circle()
                                .fill(badges[i].tint)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: badges[i].symbol)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(i == 0 ? Color.black.opacity(0.8) : .white)
                                )
                                .overlay(Circle().strokeBorder(Theme.folderFrontBottom, lineWidth: 2))
                        }
                    }
                    .padding(12)
                }
                .frame(width: w, height: h * 0.72)
                .offset(y: h * 0.28)
        }
        .frame(width: w, height: h)
    }
}

struct FolderCard: View {
    let category: FileCategory
    let items: [DownloadItem]
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var totalBytes: Int64 { items.reduce(0) { $0 + max(0, $1.totalBytes) } }

    private var badges: [(symbol: String, tint: Color)] {
        var result: [(String, Color)] = [(category.symbol, Color.white)]
        if items.contains(where: { $0.status == .downloading }) { result.append(("arrow.down", Theme.blue)) }
        if items.contains(where: { $0.status == .failed }) { result.append(("exclamationmark", Theme.red)) }
        else if !items.isEmpty && items.allSatisfy({ $0.status == .completed }) { result.append(("checkmark", Theme.green)) }
        return result.map { (symbol: $0.0, tint: $0.1) }
    }

    private var extLabel: String {
        guard let latest = items.max(by: { $0.addedAt < $1.addedAt }) else { return "" }
        return String((latest.fileName as NSString).pathExtension.uppercased().prefix(4))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                FolderIllustration(fileCount: items.count, extLabel: extLabel, badges: badges)
                VStack(spacing: 3) {
                    Text(category.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(totalBytes > 0 ? "\(items.count) file · \(Format.bytes(totalBytes))" : "\(items.count) file")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering || isSelected ? Theme.cardHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering || isSelected ? Theme.border : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
