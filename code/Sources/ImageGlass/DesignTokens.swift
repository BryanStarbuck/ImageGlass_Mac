import SwiftUI
import AppKit

/// Design tokens from the Claude Design handoff bundle ("Design Review"
/// macOS window). Light + dark values resolve automatically via a dynamic
/// `NSColor` so every surface follows the system appearance.
///
/// Source: imageglass design bundle — `ImageGlass for Mac.html` `:root` /
/// `[data-theme="dark"]` custom properties. Keep these in sync if the
/// design is re-exported.
enum IG {

    // MARK: - Dynamic color helper

    /// Builds an appearance-adaptive `NSColor` from a light + dark pair.
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    private static func hex(_ rgb: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: a)
    }

    // MARK: - Tokens (NSColor)

    static let text       = dyn(hex(0x1d1d22), hex(0xf2f2f5))
    static let text2      = dyn(hex(0x5f5f68), hex(0xa2a2aa))
    static let text3      = dyn(hex(0x9a9aa2), hex(0x6e6e78))
    static let accent     = dyn(hex(0x0a82ff), hex(0x0a84ff))
    static let sel        = dyn(hex(0x0a78f5), hex(0x0a6ce0))
    static let selFg      = NSColor.white
    static let sidebar    = dyn(hex(0xf3f3f5), hex(0x222226))
    static let sidebarLine = dyn(hex(0xe1e1e5), hex(0x34343b))
    static let toolbar    = dyn(hex(0xe9e9ec), hex(0x2a2a2f))
    static let canvas     = dyn(hex(0xaeaeb3), hex(0x19191c))
    static let line       = dyn(hex(0xe5e5e9), hex(0x34343b))
    static let line2      = dyn(hex(0xcfcfd5), hex(0x42424a))
    static let field      = dyn(hex(0xffffff), hex(0x19191d))
    static let control    = dyn(hex(0xe3e3e8), hex(0x1a1a1e))
    static let controlOn  = dyn(hex(0xffffff), hex(0x48484f))
    static let glass      = dyn(hex(0xfafafc, 0.78), hex(0x2c2c31, 0.72))
    static let glassLine  = dyn(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.13))
    static let imgEdge    = dyn(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.08))
    static let mcpGreen   = hex(0x34C759)

    // include_checks.mdx §2.3 — the four-variant Include column.
    // Saturated greens/reds for explicit decisions; muted grays for
    // inherited ones. Light + dark pairs swap luminance only — the
    // glyph color is constant so the polarity (green check vs. red X)
    // stays readable in both appearances.
    static let includeGreen      = dyn(hex(0x2E7D32), hex(0x43A047))
    static let excludeRed        = dyn(hex(0xC62828), hex(0xE53935))
    static let inheritIncludeBg  = dyn(hex(0xB0B0B0), hex(0x5C5C5C))
    static let inheritExcludeBg  = dyn(hex(0xEDEDED), hex(0x3A3A3A))

    // MARK: - SwiftUI Color accessors

    static var textC: Color       { Color(nsColor: text) }
    static var text2C: Color      { Color(nsColor: text2) }
    static var text3C: Color      { Color(nsColor: text3) }
    static var accentC: Color     { Color(nsColor: accent) }
    static var selC: Color        { Color(nsColor: sel) }
    static var sidebarC: Color    { Color(nsColor: sidebar) }
    static var sidebarLineC: Color { Color(nsColor: sidebarLine) }
    static var toolbarC: Color    { Color(nsColor: toolbar) }
    static var canvasC: Color     { Color(nsColor: canvas) }
    static var lineC: Color       { Color(nsColor: line) }
    static var line2C: Color      { Color(nsColor: line2) }
    static var fieldC: Color      { Color(nsColor: field) }
    static var controlC: Color    { Color(nsColor: control) }
    static var controlOnC: Color  { Color(nsColor: controlOn) }
    static var glassC: Color      { Color(nsColor: glass) }
    static var glassLineC: Color  { Color(nsColor: glassLine) }
    static var mcpGreenC: Color   { Color(nsColor: mcpGreen) }
    static var includeGreenC: Color     { Color(nsColor: includeGreen) }
    static var excludeRedC: Color       { Color(nsColor: excludeRed) }
    static var inheritIncludeBgC: Color { Color(nsColor: inheritIncludeBg) }
    static var inheritExcludeBgC: Color { Color(nsColor: inheritExcludeBg) }
}
