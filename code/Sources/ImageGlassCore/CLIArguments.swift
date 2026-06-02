import Foundation

/// Catalog of the `/Name=Value` switches the main `ImageGlass` binary
/// accepts at launch (per `docs/command-line.mdx`).
///
/// This sits next to ``CLIOverrides`` (which does the actual parsing
/// into a ``Config/Partial``) and provides the metadata needed for
/// `--help` printing and for the test that asserts every documented
/// switch maps to a real `Config` field.
public enum CLIArguments {

    /// One documented launch-time switch.
    public struct Switch: Sendable, Equatable {
        /// The canonical name as it appears in the spec
        /// (e.g. `ShowToolbar`, `WindowBackdrop`).
        public let name: String
        /// Value grammar, e.g. `true|false` or `Auto|Lock|Fit|Fill|...`.
        public let valueSyntax: String
        /// One-line description.
        public let summary: String
    }

    /// The full table, kept in spec order so `--help` output reads like
    /// the docs.
    public static let switches: [Switch] = [
        .init(name: "ShowToolbar",     valueSyntax: "true|false",
              summary: "Show or hide the top toolbar."),
        .init(name: "ShowGallery",     valueSyntax: "true|false",
              summary: "Show or hide the thumbnail gallery strip."),
        .init(name: "ShowStatusBar",   valueSyntax: "true|false",
              summary: "Show or hide the bottom status bar."),
        .init(name: "FullScreen",      valueSyntax: "true|false",
              summary: "Launch the window in full-screen mode."),
        .init(name: "Frameless",       valueSyntax: "true|false",
              summary: "Launch with a borderless / frameless window chrome."),
        .init(name: "WindowFit",       valueSyntax: "true|false",
              summary: "Resize the window to match the image."),
        .init(name: "WindowBackdrop",  valueSyntax: "None|Acrylic|Mica|Vibrant",
              summary: "Window backdrop / vibrancy style."),
        .init(name: "ZoomMode",        valueSyntax: "auto|lock|width|height|fit|fill",
              summary: "Initial zoom mode."),
        .init(name: "Theme",           valueSyntax: "<theme-name>",
              summary: "Override the theme by name."),
        .init(name: "Language",        valueSyntax: "<locale>",
              summary: "Override the UI language."),
        .init(name: "StartupBoost",    valueSyntax: "true|false",
              summary: "Enable Startup Boost preloading (v9.1+)."),
    ]

    /// Renders the same kind of help table as `igcmd --help` for the
    /// main `ImageGlass` binary.
    public static func helpText() -> String {
        var lines: [String] = []
        lines.append("ImageGlass — Mac-native image viewer")
        lines.append("")
        lines.append("Usage:")
        lines.append("  ImageGlass [/Name=Value ...] [--startup-boost] [file ...]")
        lines.append("")
        lines.append("Switches (any igconfig.json setting can be overridden):")
        for s in switches {
            let head = "/\(s.name)=\(s.valueSyntax)"
            let pad = head.padding(toLength: 44, withPad: " ", startingAt: 0)
            lines.append("  \(pad)\(s.summary)")
        }
        lines.append("")
        lines.append("Long-form switches:")
        lines.append("  --startup-boost    Equivalent to /StartupBoost=true")
        lines.append("")
        lines.append("Positional arguments are interpreted as file paths to open.")
        return lines.joined(separator: "\n")
    }

    /// True when `args` contains a help-request token. Provided so the
    /// main binary can intercept `--help` before SwiftUI sets up a window.
    public static func wantsHelp(_ args: [String]) -> Bool {
        for a in args {
            if a == "--help" || a == "-h" || a == "/?" { return true }
        }
        return false
    }
}
