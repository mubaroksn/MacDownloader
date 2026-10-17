import SwiftUI

/// At-a-glance numbers above the file list: live speed (with the speed-mode switch),
/// what's running, and what came in today.
struct DashboardStrip: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SpeedCard()
                .frame(maxWidth: .infinity)
            StatCard(title: "Aktif",
                     value: "\(manager.activeCount)",
                     detail: activeDetail)
                .frame(width: 176)
            StatCard(title: "Hari ini",
                     value: manager.todayBytes > 0 ? Format.bytes(manager.todayBytes) : "0 MB",
                     detail: manager.completedTodayCount == 0 ? "Belum ada file selesai"
                         : "\(manager.completedTodayCount) file selesai")
                .frame(width: 176)
        }
        .frame(height: 124)
    }

    private var activeDetail: String {
        var parts: [String] = []
        if manager.queuedCount > 0 { parts.append("\(manager.queuedCount) antre") }
        if manager.pausedCount > 0 { parts.append("\(manager.pausedCount) dijeda") }
        return parts.isEmpty ? "Tidak ada antrean" : parts.joined(separator: " · ")
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(height: 26, alignment: .center)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .dashboardCard()
    }
}

private struct SpeedCard: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        let speed = manager.totalSpeed
        let cap = manager.limit(for: manager.speedMode)
        ZStack(alignment: .bottom) {
            Sparkline(samples: manager.speedHistory, cap: Double(cap))
                .frame(height: 54)
                .padding(.horizontal, 1)
                .padding(.bottom, 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Kecepatan")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    SpeedModePicker(compact: true, iconsOnly: true)
                }
                .frame(height: 26)
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(speed >= 1 ? Format.speed(speed) : "0 B/s")
                        .font(.system(size: 24, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(cap > 0 ? "batas \(Format.speed(Double(cap)))" : "tanpa batas")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(manager.activeCount > 0 ? "\(totalConnections) koneksi terbuka" : "Diam")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .dashboardCard()
    }

    private var totalConnections: Int {
        manager.items.filter { $0.status == .downloading }.reduce(0) { $0 + $1.activeConnections }
    }
}

/// Speed over the last minute: soft area + line, and a dashed line at the cap when one is set.
private struct Sparkline: View {
    let samples: [Double]
    let cap: Double

    var body: some View {
        GeometryReader { geo in
            let peak = max(samples.max() ?? 0, cap, 1)
            let points = Self.points(samples, peak: peak, in: geo.size)
            ZStack {
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Theme.primary.opacity(0.10), Theme.primary.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
                if cap > 0 {
                    let y = geo.size.height * (1 - CGFloat(cap / peak)) + 1
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func points(_ samples: [Double], peak: Double, in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let step = size.width / CGFloat(samples.count - 1)
        let usable = size.height - 2
        return samples.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: 1 + usable * (1 - CGFloat(min(v, peak) / peak)))
        }
    }
}

private extension View {
    func dashboardCard() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
