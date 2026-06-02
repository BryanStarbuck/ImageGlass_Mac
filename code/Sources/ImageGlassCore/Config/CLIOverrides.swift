import Foundation

/// Parses ImageGlass.exe-style `/Name=Value` command-line overrides into
/// a `Config.Partial` and surfaces remaining positional arguments (file
/// paths to open).
///
/// Per `docs/command-line.mdx`:
///
///     ImageGlass.exe /ShowToolbar=false /ShowGallery=false
///                    /WindowBackdrop="Acrylic" "C:\my photos\sky.jpg"
///
/// Quotes around values are stripped — `Process.arguments` already strips
/// shell quotes, so we only strip residual quotes the user embedded.
public struct CLIOverrides: Equatable, Sendable {

    /// The parsed overrides as a sparse `Config.Partial`.
    public var partial: Config.Partial

    /// Positional arguments left over after extracting `/Name=Value` flags.
    /// Typically file paths to open at launch.
    public var positionalArguments: [String]

    /// Raw `/Name=Value` pairs as they were parsed, preserved verbatim for
    /// diagnostics. Keys keep their original casing.
    public var rawPairs: [(name: String, value: String)]

    public init(
        partial: Config.Partial = Config.Partial(),
        positionalArguments: [String] = [],
        rawPairs: [(name: String, value: String)] = []
    ) {
        self.partial = partial
        self.positionalArguments = positionalArguments
        self.rawPairs = rawPairs
    }

    public static func == (lhs: CLIOverrides, rhs: CLIOverrides) -> Bool {
        guard lhs.partial == rhs.partial,
              lhs.positionalArguments == rhs.positionalArguments,
              lhs.rawPairs.count == rhs.rawPairs.count else { return false }
        for (l, r) in zip(lhs.rawPairs, rhs.rawPairs) {
            if l.name != r.name || l.value != r.value { return false }
        }
        return true
    }

    // MARK: - Parsing

    /// Parses a full argv array. The first element (program name) is
    /// **not** skipped — pass `Array(CommandLine.arguments.dropFirst())`
    /// when calling from `main`.
    public static func parse(_ args: [String]) -> CLIOverrides {
        var partial = Config.Partial()
        var positional: [String] = []
        var rawPairs: [(name: String, value: String)] = []

        for arg in args {
            // Special-case the long-form switch the spec calls out by name:
            //   `ImageGlass.exe --startup-boost`  (no `=value`).
            // Treat it as `StartupBoost=true` so the rest of the pipeline
            // doesn't need to special-case it.
            if arg == "--startup-boost" {
                partial.startupBoost = true
                rawPairs.append((name: "StartupBoost", value: "true"))
                continue
            }
            guard arg.hasPrefix("/"), let eq = arg.firstIndex(of: "=") else {
                positional.append(arg)
                continue
            }
            let nameStart = arg.index(after: arg.startIndex)
            guard nameStart < eq else { continue } // "/=foo" — skip
            let name = String(arg[nameStart..<eq])
            var value = String(arg[arg.index(after: eq)...])
            value = stripQuotes(value)
            rawPairs.append((name: name, value: value))
            apply(name: name, value: value, to: &partial)
        }
        return CLIOverrides(partial: partial, positionalArguments: positional, rawPairs: rawPairs)
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Matches by case-insensitive name so users can write
    /// `/showtoolbar=false` or `/ShowToolbar=false` interchangeably.
    private static func apply(name: String, value: String, to partial: inout Config.Partial) {
        switch name.lowercased() {
        case "showtoolbar":    if let v = parseBool(value)    { partial.showToolbar = v }
        case "showgallery":    if let v = parseBool(value)    { partial.showGallery = v }
        case "showstatusbar":  if let v = parseBool(value)    { partial.showStatusBar = v }
        case "fullscreen":     if let v = parseBool(value)    { partial.fullScreen = v }
        case "frameless":      if let v = parseBool(value)    { partial.frameless = v }
        case "windowfit":      if let v = parseBool(value)    { partial.windowFit = v }
        case "windowbackdrop":
            if let v = WindowBackdrop(rawValue: value) { partial.windowBackdrop = v }
        case "zoommode":
            // ZoomMode raw values are lowercase: auto, lock, width, height, fit, fill.
            if let v = ZoomMode(rawValue: value.lowercased()) { partial.zoomMode = v }
        case "theme":          partial.theme = value
        case "language":       partial.language = value
        case "startupboost":   if let v = parseBool(value)    { partial.startupBoost = v }
        default: break // Unknown flag — silently ignored so older builds tolerate newer flags.
        }
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "1", "yes", "on":  return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }
}
