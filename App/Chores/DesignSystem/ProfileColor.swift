import SwiftUI

extension Color {
    /// Parses "#RRGGBB". Falls back to gray on anything unexpected, because a bad
    /// colour must never take a screen down.
    init(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// The palette offered when adding a child. Six hues at identical lightness and
/// chroma (OKLCH L 0.66, C 0.125), so every child weighs the same on the dark
/// ground of the kid screens. Each carries a 700 and a 900 step for the
/// selected-day cell; see `ChildHue`.
enum ProfilePalette {
    /// Blurple, Teal, Mint, Coral, Amber, Rose.
    static let options = ["#9084da", "#00a7b6", "#3ca977", "#d4716b", "#be8628", "#ca709d"]

    /// Keyed by lowercase base hex.
    static let steps: [String: (step700: String, step900: String)] = [
        "#9084da": ("#544c84", "#2d2945"), // Blurple
        "#00a7b6": ("#00636d", "#02353a"), // Teal
        "#3ca977": ("#1a6444", "#143525"), // Mint
        "#d4716b": ("#803f3b", "#442321"), // Coral
        "#be8628": ("#724d0b", "#3c2a0e"), // Amber
        "#ca709d": ("#7a3f5c", "#412331"), // Rose
    ]
}
