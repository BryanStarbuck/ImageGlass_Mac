import Foundation

/// Parses the command-line surface accepted by the **ImageGlass** SwiftUI app.
///
/// Per `docs/command-line.mdx`:
///   * Setting overrides use a `/Name=Value` form. Any setting exposed in
///     `igconfig.json` can be overridden this way.
///   * Anything that isn't a `/Name=…` flag is treated as a positional file path
///     to open.
///
/// We intentionally **don't** apply the overrides to `igconfig` here — the
/// config subsystem owns that. The parser simply collects them so an
/// `AppState` (or test) can hand the dictionary to whoever wants it later.
///
/// Quoting behaviour: the shell strips outer quotes for us, so by the time
/// values land in `argv` the string is already unquoted. However, when callers
/// pre-join an argv (e.g. tests that exercise a single string), we still want
/// to honour quotes around the value of `/Name="Value With Spaces"`. The
/// tokenizer therefore understands matched `"` and `'` pairs around values.
public struct ImageGlassLaunchArguments: Equatable, Sendable {
    /// Setting overrides collected from `/Name=Value` flags.
    public var overrides: [String: String]
    /// File / directory paths to open, in the order seen on the command line.
    public var openPaths: [String]
    /// `true` if the magic `--startup-boost` flag was present.
    public var startupBoost: Bool

    public init(
        overrides: [String: String] = [:],
        openPaths: [String] = [],
        startupBoost: Bool = false
    ) {
        self.overrides = overrides
        self.openPaths = openPaths
        self.startupBoost = startupBoost
    }

    /// Parse an `argv`-style array. The first element is treated as the
    /// program name and skipped if `skipProgramName` is true (matches
    /// `CommandLine.arguments` conventions).
    public static func parse(
        _ argv: [String],
        skipProgramName: Bool = true
    ) -> ImageGlassLaunchArguments {
        var args = argv
        if skipProgramName, !args.isEmpty {
            args.removeFirst()
        }
        var result = ImageGlassLaunchArguments()
        for raw in args {
            if raw == "--startup-boost" {
                result.startupBoost = true
                continue
            }
            // `/Name=Value` style setting override. The leading `/` form
            // collides with Unix absolute paths, so we *only* treat the
            // token as an override if it contains a `=` AND the name segment
            // is a plain identifier (letters / digits / dot / underscore).
            // Anything else is a positional path.
            if raw.hasPrefix("/"), let eq = raw.firstIndex(of: "="), eq > raw.index(after: raw.startIndex) {
                let nameRange = raw.index(after: raw.startIndex)..<eq
                let name = String(raw[nameRange])
                if Self.isValidSettingName(name) {
                    let value = stripOuterQuotes(String(raw[raw.index(after: eq)...]))
                    result.overrides[name] = value
                    continue
                }
            }
            // Fallback: positional file argument.
            result.openPaths.append(stripOuterQuotes(raw))
        }
        return result
    }

    /// Setting names must look like config keys — alphanumerics plus `.` and
    /// `_`. We require at least one character. This is what distinguishes
    /// `/ShowToolbar=false` (override) from `/Users/me/photo.jpg` (path).
    static func isValidSettingName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "." || ch == "_" { continue }
            return false
        }
        return true
    }

    static func stripOuterQuotes(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
