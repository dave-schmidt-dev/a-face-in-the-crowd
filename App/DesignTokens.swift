import SwiftUI

/// Accepted adaptive neutral palette. Photos retain their original colors.
struct DesignTokens {
    let scheme: ColorScheme
    func color(_ dark: UInt32, _ light: UInt32) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var surface: Color { color(0x20262A, 0xFFFDF8) }
    var secondary: Color { color(0xC2CBD0, 0x4E5960) }
    var primary: Color { color(0x7EC5E8, 0x0F4C81) }
    var border: Color { color(0x9CAFB9, 0x68737A) }
}
