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

/// The palette offered when adding a child. Chosen to stay distinguishable from
/// each other in both light and dark mode.
enum ProfilePalette {
    static let options = ["#4C8BF5", "#E8710A", "#1DB954", "#C2185B", "#7B5CD6", "#00897B"]
}
