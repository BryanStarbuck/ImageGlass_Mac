#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI color accessors keyed off a theme's HEX color strings.
/// Lives in ImageGlassCore so both the app and any preview/embedded UI can
/// consume the same `Color` values.
public extension Theme.Colors {

    var accentColor: Color {
        if accent.lowercased() == "system" { return .accentColor }
        return Color(hex: accent) ?? .accentColor
    }

    var viewerBackgroundColor: Color { Color(hex: viewerBackground) ?? .black }
    var toolbarBackgroundColor: Color { Color(hex: toolbarBackground) ?? .gray }
    var galleryBackgroundColor: Color { Color(hex: galleryBackground) ?? .black }
    var menuBackgroundColor: Color { Color(hex: menuBackground) ?? .gray }
    var foregroundColor: Color { Color(hex: foreground) ?? .primary }
}

public extension Theme {
    /// Convenience: the SwiftUI `ColorScheme` this theme prefers.
    var preferredColorScheme: ColorScheme {
        settings.isDarkMode ? .dark : .light
    }
}

// MARK: - HEX → Color

public extension Color {
    /// Parses `#RRGGBB`, `#RRGGBBAA`, `RRGGBB`, or `RRGGBBAA`.
    /// Returns `nil` if the input isn't recognizable.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        guard let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        } else {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
#endif
