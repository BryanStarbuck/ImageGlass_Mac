import Foundation

public enum AppPaths {
    public static let appName = "ImageGlass"

    /// Reads HOME from the live environment so tests can rebind it.
    /// Falls back to NSHomeDirectory() if HOME is unset.
    public static var homeDirectory: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return h
        }
        return NSHomeDirectory()
    }

    public static var appSupportDir: URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var scopesDir: URL {
        appSupportDir.appendingPathComponent("scopes", isDirectory: true)
    }

    /// Directory holding installed `.iglang` language packs (one JSON per locale).
    public static var languagesDir: URL {
        appSupportDir.appendingPathComponent("languages", isDirectory: true)
    }

    /// Directory holding installed theme packs.
    public static var themesDir: URL {
        appSupportDir.appendingPathComponent("themes", isDirectory: true)
    }

    /// Marker file used to signal "startup boost" preference on macOS.
    /// macOS has no first-class preload mechanism comparable to the
    /// Windows scheduled-task trick, so we record intent as a flag file
    /// that a future launch-agent installer can act on.
    public static var startupBoostFlag: URL {
        appSupportDir.appendingPathComponent("startup_boost.flag")
    }

    public static var configFile: URL {
        appSupportDir.appendingPathComponent("igconfig.json")
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, scopesDir, languagesDir, themesDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = homeDirectory
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public static func contractTilde(_ path: String) -> String {
        let home = homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}
