import Foundation

/// On-disk locations for the spec-§2.2 `settings.json` family. Lives in the
/// same Application Support directory as the legacy `igconfig.json` (see
/// `AppPaths.appSupportDir`); separate filenames so the two systems coexist.
public struct SettingsPaths: Sendable, Equatable {
    public static let fileName = "settings.json"
    public static let backupFileName = "settings.json.bak"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var backupURL: URL { directory.appendingPathComponent(Self.backupFileName) }

    public static func resolve(directory: URL? = nil) -> SettingsPaths {
        SettingsPaths(directory: directory ?? AppPaths.appSupportDir)
    }

    public func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// Loads, saves, and atomically updates `settings.json`. The store is an
/// `actor` so concurrent MCP and GUI writes serialize through one queue.
///
/// Spec §2.4 — every write is atomic (write to a temp file, then rename).
/// The previous file is rotated to `settings.json.bak` on success so a
/// crash mid-write leaves at least one valid file on disk.
public actor SettingsStore {

    public let paths: SettingsPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: SettingsPaths = SettingsPaths.resolve()) {
        self.paths = paths
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    /// Reads `settings.json` from disk, runs `clamp`, and returns the result.
    /// Returns `Settings.defaults` if the file is missing. Throws only on
    /// malformed JSON; an out-of-range numeric is clamped silently.
    public func load() throws -> Settings {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.fileURL.path) else {
            return Settings.defaults
        }
        let data = try Data(contentsOf: paths.fileURL)
        var s = try decoder.decode(Settings.self, from: data)
        s = migrate(s)
        SettingsValidation.clamp(&s)
        return s
    }

    /// Loads and falls back to `Settings.defaults` if the file is missing or
    /// unreadable. Use this in production paths where a corrupt settings
    /// file must not prevent the app from launching.
    public func loadOrDefault() -> Settings {
        do {
            return try load()
        } catch {
            ErrorLog.log("settings load failed, falling back to defaults",
                         error: error,
                         class: "SettingsStore")
            return Settings.defaults
        }
    }

    /// Atomic save: write a temp file in the target directory then rename.
    /// On success, rotates the prior `settings.json` to `settings.json.bak`.
    public func save(_ settings: Settings) throws {
        try paths.ensureDirectory()
        var copy = settings
        SettingsValidation.clamp(&copy)
        let data = try encoder.encode(copy)

        let tempURL = paths.directory.appendingPathComponent(
            "settings.json.tmp.\(UUID().uuidString)"
        )
        try data.write(to: tempURL, options: .atomic)

        let fm = FileManager.default
        if fm.fileExists(atPath: paths.fileURL.path) {
            // Best-effort backup rotation; never block the save on backup IO.
            do {
                try fm.removeItem(at: paths.backupURL)
            } catch {
                let nsErr = error as NSError
                if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError) {
                    ErrorLog.log("backup remove failed: \(paths.backupURL.path)",
                                 error: error,
                                 class: "SettingsStore")
                }
            }
            do {
                try fm.copyItem(at: paths.fileURL, to: paths.backupURL)
            } catch {
                ErrorLog.log("backup copy failed: \(paths.fileURL.path) -> \(paths.backupURL.path)",
                             error: error,
                             class: "SettingsStore")
            }
            do {
                try fm.removeItem(at: paths.fileURL)
            } catch {
                ErrorLog.log("settings remove failed: \(paths.fileURL.path)",
                             error: error,
                             class: "SettingsStore")
            }
        }
        try fm.moveItem(at: tempURL, to: paths.fileURL)
    }

    /// Read-modify-write. The closure may mutate the settings struct; the
    /// store re-validates and writes back atomically. Returns the new value.
    @discardableResult
    public func update(_ mutate: (inout Settings) throws -> Void) throws -> Settings {
        var current: Settings
        do {
            current = try load()
        } catch {
            ErrorLog.log("update: load failed, using defaults",
                         error: error,
                         class: "SettingsStore")
            current = Settings.defaults
        }
        try mutate(&current)
        try save(current)
        return current
    }

    /// Reset one section to defaults. Path is the top-level section name
    /// (e.g. `viewer`, `image`, `tools.crop`). Throws for unknown sections.
    @discardableResult
    public func resetSection(_ section: String) throws -> Settings {
        try update { s in
            let d = Settings.defaults
            switch section {
            case "general": s.general = d.general
            case "image": s.image = d.image
            case "viewer": s.viewer = d.viewer
            case "appearance": s.appearance = d.appearance
            case "layout": s.layout = d.layout
            case "slideshow": s.slideshow = d.slideshow
            case "edit": s.edit = d.edit
            case "mouse": s.mouse = d.mouse
            case "keyboard": s.keyboard = d.keyboard
            case "gallery": s.gallery = d.gallery
            case "toolbar": s.toolbar = d.toolbar
            case "file_assoc": s.fileAssoc = d.fileAssoc
            case "language": s.language = d.language
            case "tools": s.tools = d.tools
            case "tools.crop": s.tools.crop = d.tools.crop
            case "tools.color_picker": s.tools.color_picker = d.tools.color_picker
            case "tools.frame_nav": s.tools.frame_nav = d.tools.frame_nav
            case "plugins": s.plugins = d.plugins
            case "advanced": s.advanced = d.advanced
            case "advanced.mcp": s.advanced.mcp = d.advanced.mcp
            default:
                throw SettingsValidation.ValidationError(
                    path: section,
                    reason: "unknown section"
                )
            }
        }
    }

    /// Reset everything to spec defaults.
    @discardableResult
    public func resetAll() throws -> Settings {
        try save(Settings.defaults)
        return Settings.defaults
    }

    /// In-place migration. Schema version 1 is the current and only known
    /// shape; older versions are upgraded by re-running defaults on missing
    /// sections (the permissive decoder already handles this) and bumping
    /// the `version` field. Kept as a single method so future revisions
    /// have one place to add `case 1: ... s.version = 2` style upgrades.
    private func migrate(_ original: Settings) -> Settings {
        var s = original
        if s.version < Settings.currentSchemaVersion {
            s.version = Settings.currentSchemaVersion
        }
        return s
    }
}
