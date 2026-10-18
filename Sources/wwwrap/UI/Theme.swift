import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// A color that follows the system light/dark appearance.
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Monochrome palette modeled on the reference design: white/near-black chrome,
/// a slightly darker canvas, hairline borders and soft gray folders.
enum Theme {
    static let chrome = Color.dynamic(0xFFFFFF, 0x141414)        // top bar, rail, sidebar
    static let canvas = Color.dynamic(0xF6F6F7, 0x0A0A0A)        // main area
    static let card = Color.dynamic(0xFFFFFF, 0x141414)
    static let cardHover = Color.dynamic(0xECECEE, 0x1C1C1D)
    static let border = Color.dynamic(0xE5E5E8, 0x262628)
    static let hover = Color.dynamic(0xF3F3F5, 0x1C1C1D)
    static let selected = Color.dynamic(0xEDEDF0, 0x2A2A2C)
    static let badge = Color.dynamic(0xFFFFFF, 0x2A2A2C)
    static let segmentTrack = Color.dynamic(0xF0F0F2, 0x0A0A0A)
    static let segmentThumb = Color.dynamic(0xFFFFFF, 0x2A2A2C)

    static let textPrimary = Color.dynamic(0x18181B, 0xF4F4F5)
    static let textSecondary = Color.dynamic(0x6E6E76, 0xA1A1AA)
    static let textTertiary = Color.dynamic(0xA1A1AA, 0x63636B)

    static let folderBack = Color.dynamic(0x55555A, 0x232325)
    static let folderFrontTop = Color.dynamic(0x76767B, 0x3A3A3D)
    static let folderFrontBottom = Color.dynamic(0x66666B, 0x2D2D30)
    static let folderEdge = Color.dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.22, darkAlpha: 0.09)
    static let paper = Color.dynamic(0xFFFFFF, 0xEDEDED)
    static let paperInk = Color.dynamic(0xC4C4C8, 0xB0B0B4)

    static let primary = Color.dynamic(0x18181B, 0xF4F4F5)
    static let onPrimary = Color.dynamic(0xFFFFFF, 0x0A0A0A)

    static let blue = Color.dynamic(0x2563EB, 0x60A5FA)
    static let green = Color.dynamic(0x16A34A, 0x4ADE80)
    static let orange = Color.dynamic(0xD97706, 0xFBBF24)
    static let red = Color.dynamic(0xDC2626, 0xF87171)
}

extension DownloadStatus {
    var color: Color {
        switch self {
        case .downloading: return Theme.blue
        case .completed: return Theme.green
        case .failed: return Theme.red
        case .paused, .queued: return Theme.orange
        }
    }
}
