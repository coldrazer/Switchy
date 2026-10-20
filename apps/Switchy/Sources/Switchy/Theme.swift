#if canImport(SwiftUI)
import SwiftUI

/// Design tokens. The game menu ("launcher") is a full-bleed, console-style home screen over the selected game's art;
/// the management panels use a red sidebar with white content and dark game cards.
enum Theme {
    // Launcher
    static let deepTeal = Color(hex: 0x0A2E36)
    static let teal = Color(hex: 0x0F4C57)
    static let tealLight = Color(hex: 0x1D7480)
    static let selection = Color(hex: 0x3EE6EE)          // the glow around the selected tile
    static let statusPill = Color(hex: 0xF5913A)
    static let success = Color(hex: 0x86E05A)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.78)
    static let iconBuilds = Color(hex: 0xFF6A5C)
    static let iconMods = Color(hex: 0xF7BE3B)
    static let iconAdd = Color(hex: 0x4FB1FF)

    // Panels
    static let red = Color(hex: 0xD7262E)
    static let redDark = Color(hex: 0x9E1219)
    static let panelBackground = Color.white
    static let card = Color(hex: 0x2B3039)
    static let cardRaised = Color(hex: 0x3A404B)
    static let statBlue = Color(hex: 0x2F8CFF)
    static let ink = Color(hex: 0x1D2128)
    static let inkSecondary = Color(hex: 0x5D6470)

    static let tileCorner: CGFloat = 10
    static let selectedTile: CGFloat = 300
    static let tile: CGFloat = 176
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Font {
    static func launcher(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A capsule label like the version and platform badges on a game card.
struct Pill: View {
    var text: String
    var filled = true
    var color = Theme.red
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(filled ? color : Color.white))
            .overlay(Capsule().strokeBorder(filled ? .clear : color, lineWidth: 1))
    }
}
#endif
