// Color palette derived from the design mock (Session Explorer — macOS).

import SwiftUI

enum Theme {
    static let accent = Color(hex: 0x0A84FF)

    // Project dot colors, assigned stably by hashing the project path.
    static let dotPalette: [Color] = [
        Color(hex: 0xFF6B5E), Color(hex: 0xAF7BFF), Color(hex: 0x1FB6A6),
        Color(hex: 0x0A7AFF), Color(hex: 0x34C759), Color(hex: 0xFF9F0A),
        Color(hex: 0xFEBC2E), Color(hex: 0x30B0C7), Color(hex: 0x5E5CE6),
        Color(hex: 0xFF375F),
    ]

    static func dotColor(for path: String) -> Color {
        var hash = 5381
        for b in path.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
        return dotPalette[abs(hash) % dotPalette.count]
    }

    static let claudeGradient = LinearGradient(
        colors: [Color(hex: 0xD97757), Color(hex: 0xC25E3F)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Text tiers — native semantic colors, so they invert with the appearance.
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let sectionLabel = Color(nsColor: .tertiaryLabelColor)

    // Surfaces — native semantic backgrounds.
    static let cardBg = Color(nsColor: .controlBackgroundColor)
    static let panelBg = Color(nsColor: .underPageBackgroundColor)
    static let codeBg = Color(nsColor: .quaternarySystemFill)

    // A hairline rule / quiet fill that reads on either appearance.
    static let rule = Color.primary.opacity(0.12)

    static let highlight = Color(hex: 0xFFE08A).opacity(0.85)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
