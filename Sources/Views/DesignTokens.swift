import SwiftUI

/// Design tokens mirroring `design/project/styles.css` :root variables.
///
/// The CSS uses OKLCH; for v0.1 we render straight sRGB approximations close
/// enough for visual parity. (A later pass via `scripts/colors-from-css.swift`
/// can compute exact sRGB from the OKLCH literals.)
enum DesignColor {
    // Accent is the SYSTEM accent — applied via `.tint(.accentColor)` at the app root so
    // every control inherits the user's chosen Mac accent (charter: never a hardcoded blue).

    static let bg           = Color(red: 252/255, green: 252/255, blue: 253/255)
    static let bgPane       = Color(red: 247/255, green: 247/255, blue: 249/255)
    static let bgSoft       = Color(red: 243/255, green: 244/255, blue: 246/255)
    static let bgSelected   = Color(red: 232/255, green: 240/255, blue: 252/255)

    static let fg           = Color(red: 21/255,  green: 23/255,  blue: 28/255)
    static let fgMute       = Color(red: 102/255, green: 107/255, blue: 117/255)
    static let fgFaint      = Color(red: 140/255, green: 145/255, blue: 156/255)
    static let fgGhost      = Color(red: 184/255, green: 188/255, blue: 197/255)

    static let border       = Color(red: 221/255, green: 224/255, blue: 230/255)
    static let borderSoft   = Color(red: 235/255, green: 237/255, blue: 241/255)

    static let green        = Color(red: 36/255,  green: 156/255, blue: 80/255)
    static let amber        = Color(red: 215/255, green: 145/255, blue: 30/255)
    static let red          = Color(red: 220/255, green: 56/255,  blue: 45/255)

}

enum DesignRadius {
    static let window: CGFloat = 14
    static let regular: CGFloat = 8
    static let small: CGFloat = 5
}

enum DesignFont {
    static let ui = Font.system(size: 13, design: .default)
    static let uiMedium = Font.system(size: 13, weight: .medium, design: .default)
    static let uiSmall = Font.system(size: 12.5)
    static let display = Font.system(size: 13.5, weight: .medium, design: .default)
    static let displayName = Font.system(size: 17, weight: .medium, design: .default)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
    static let label = Font.system(size: 12.5)
    static let cap10 = Font.system(size: 10, weight: .medium, design: .default).leading(.tight)
}

extension Color {
    /// Parse a `#rrggbb` or `#rgb` literal into a `Color`. Returns `.clear` on bad input
    /// because the GUI's hex picker should validate before we ever reach this path.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        let normalized: String
        if trimmed.count == 3 {
            normalized = trimmed.map { "\($0)\($0)" }.joined()
        } else {
            normalized = trimmed
        }
        guard normalized.count == 6, let int = UInt32(normalized, radix: 16) else {
            self = .clear
            return
        }
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >> 8) & 0xff) / 255
        let b = Double(int & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
