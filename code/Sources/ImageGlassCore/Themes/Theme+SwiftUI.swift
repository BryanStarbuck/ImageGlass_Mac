#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// SwiftUI color accessors keyed off a theme's HEX color strings.
/// Lives in ImageGlassCore so both the app and any preview/embedded UI can
/// consume the same `Color` values.
public extension Theme.Colors {

    var accentColor: Color {
        if accent.lowercased() == "system" { return .accentColor }
        return Color(hex: accent) ?? .accentColor
    }

    // Fallback colors are neutral SwiftUI semantic colors — `.windowBackground`
    // / `.primary` / `.secondary` automatically adapt to light vs. dark mode.
    // The previous `.black` / `.gray` defaults always looked wrong under one
    // appearance.
    var viewerBackgroundColor: Color { Color(hex: viewerBackground) ?? Self.fallbackWindowBackground }
    var toolbarBackgroundColor: Color { Color(hex: toolbarBackground) ?? Self.fallbackControlBackground }
    var galleryBackgroundColor: Color { Color(hex: galleryBackground) ?? Self.fallbackUnderPageBackground }
    var menuBackgroundColor: Color { Color(hex: menuBackground) ?? Self.fallbackControlBackground }
    var foregroundColor: Color { Color(hex: foreground) ?? .primary }

    // Neutral, appearance-adaptive fallbacks — these track NSAppearance,
    // so a light/dark mode swap automatically picks the right shade when
    // a theme color is missing or malformed.
    #if canImport(AppKit)
    private static var fallbackWindowBackground: Color { Color(nsColor: NSColor.windowBackgroundColor) }
    private static var fallbackControlBackground: Color { Color(nsColor: NSColor.controlBackgroundColor) }
    private static var fallbackUnderPageBackground: Color { Color(nsColor: NSColor.underPageBackgroundColor) }
    #else
    private static var fallbackWindowBackground: Color { .gray }
    private static var fallbackControlBackground: Color { .gray }
    private static var fallbackUnderPageBackground: Color { .gray }
    #endif
}

public extension Theme {
    /// Convenience: the SwiftUI `ColorScheme` this theme prefers.
    var preferredColorScheme: ColorScheme {
        settings.isDarkMode ? .dark : .light
    }
}

// MARK: - Appearance mode bridging

public extension ThemeAppearanceMode {
    /// The `ColorScheme?` to pass to SwiftUI `.preferredColorScheme(...)`.
    /// `nil` (system mode) means "don't override — follow the OS".
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}

public extension SystemColorScheme {
    init(_ scheme: ColorScheme) {
        self = (scheme == .dark) ? .dark : .light
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
