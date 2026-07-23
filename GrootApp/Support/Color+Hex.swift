import SwiftUI

extension Color {
    /// Create a Color from a "#RRGGBB" hex string (used for agent bubble tints).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        } else {
            r = 0.4; g = 0.6; b = 1.0 // sensible fallback
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
