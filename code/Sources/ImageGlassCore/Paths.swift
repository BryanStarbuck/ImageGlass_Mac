import Foundation

public enum AppPaths {
    public static let appName = "ImageGlass"

    /// Reads HOME from the live environment so tests can rebind it via
    /// `setenv("HOME", ...)`. Falls back to NSHomeDirectory() if HOME is unset.
    /// (NSHomeDirectory() ignores HOME mid-process on macOS, so reading the
    /// env directly is what keeps tests hermetic.)
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

    /// Directory holding one plain-text JSON file per external tool descriptor.
    /// Layout mirrors `scopesDir` so the on-disk story is uniform.
    public static var toolsDir: URL {
        appSupportDir.appendingPathComponent("tools", isDirectory: true)
    }

    /// Directory holding runtime sockets (Unix-domain socket for tool IPC).
    public static var runtimeDir: URL {
        appSupportDir.appendingPathComponent("runtime", isDirectory: true)
    }

    /// Named rule-set storage (spec §3 "Named rule sets that can be referenced
    /// and reused"). One plain-text JSON file per rule set.
    public static var ruleSetsDir: URL {
        appSupportDir.appendingPathComponent("rulesets", isDirectory: true)
    }

    /// Per-scope audit log directory. Each scope gets its own JSONL file
    /// (`<scope>.log`) recording every evaluation: timestamp, file count,
    /// and the (added, removed) diff against the previous run.
    public static var auditDir: URL {
        appSupportDir.appendingPathComponent("audit", isDirectory: true)
    }

    /// Directory holding installed `.iglang` language packs (one JSON per locale).
    public static var languagesDir: URL {
        appSupportDir.appendingPathComponent("languages", isDirectory: true)
    }

    // `themesDir` is declared in Themes/ThemeCatalog.swift.

    /// Marker file used to signal "startup boost" preference on macOS.
    /// macOS has no first-class preload mechanism comparable to the Windows
    /// scheduled-task trick, so we record intent as a flag file that a future
    /// launch-agent installer can act on.
    public static var startupBoostFlag: URL {
        appSupportDir.appendingPathComponent("startup_boost.flag")
    }

    public static var configFile: URL {
        appSupportDir.appendingPathComponent("igconfig.json")
    }

    /// User-extensible format registry overlay (see `docs/supported-formats.mdx`).
    public static var formatsFile: URL {
        appSupportDir.appendingPathComponent("formats.json")
    }

    /// Directory holding the panel-framework layout files (see `docs/panels.mdx` §6).
    public static var layoutDir: URL {
        appSupportDir.appendingPathComponent("layout", isDirectory: true)
    }

    public static var layoutFile: URL {
        layoutDir.appendingPathComponent("layout.json")
    }

    public static var layoutBackupFile: URL {
        layoutDir.appendingPathComponent("layout.json.bak")
    }

    public static var layoutPresetsDir: URL {
        layoutDir.appendingPathComponent("presets", isDirectory: true)
    }

    // MARK: - Mac fork directory tree
    //
    // The spec (docs/use_cases/mcp_file.mdx §0) names the fork's on-disk
    // home as `~/Library/Application Support/ImageGlass_Mac/`, distinct
    // from the upstream-compatible `ImageGlass/` tree used by the rest of
    // the app. We keep both in parallel: GUI state stays under
    // `appSupportDir`; new MCP tools (`update_scope`,
    // `list_files_in_scope`, `select_file`, `panel.set_view_mode`) read
    // and write the spec-mandated YAML scope files and `log.log` here.

    public static let macAppName = "ImageGlass_Mac"

    public static var macAppSupportDir: URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(macAppName, isDirectory: true)
    }

    public static var macScopesDir: URL {
        macAppSupportDir.appendingPathComponent("scopes", isDirectory: true)
    }

    public static var macLogsDir: URL {
        macAppSupportDir.appendingPathComponent("logs", isDirectory: true)
    }

    public static var macLogFile: URL {
        macLogsDir.appendingPathComponent("log.log")
    }

    /// The directory tree panel's own store (use_cases/mcp_file.mdx §0,
    /// list_of_files.mdx §3A.1). A single YAML file alongside `scopes/`
    /// and `logs/`.
    public static var macDirectoriesFile: URL {
        macAppSupportDir.appendingPathComponent("directories.yaml")
    }

    public static func ensureMacDirectories() throws {
        let fm = FileManager.default
        for dir in [macAppSupportDir, macScopesDir, macLogsDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, scopesDir, toolsDir, runtimeDir, ruleSetsDir, auditDir, languagesDir, themesDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    public static func ensureLayoutDirectories() throws {
        let fm = FileManager.default
        for dir in [layoutDir, layoutPresetsDir] {
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
