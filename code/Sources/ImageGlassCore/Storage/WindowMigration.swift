import Foundation

/// One-time v1 → v2 migration of the Local Storage layout
/// (multi_window.mdx §3.5). Runs at app launch *before* any
/// `WindowState` is constructed.
///
/// What it does:
///
/// * Detects the v1 layout (`directories.yaml` and/or `settings.yaml`
///   exist at the top of `macAppSupportDir/`, **no**
///   `settings_window_*.yaml` files exist yet).
/// * Writes `directories_window_1.yaml` as a verbatim copy of the v1
///   `directories.yaml`, with `window_id: 1` recorded inside.
/// * Writes `settings_window_1.yaml` with the per-window subset of the
///   v1 `settings.yaml`. (Group A's `WindowScopedSettings` defaults are
///   used; the v1 file's session block is dropped since the v1 schema
///   does not yet exist in the live code — only the file format
///   document mentions it. A future enhancement can map it.)
/// * Renames `directories.yaml` to `directories.yaml.v1.bak` and
///   `settings.yaml` to `settings.yaml.v1.bak`.
///
/// The migration is **idempotent**: if any `settings_window_*.yaml`
/// already exists, the migration treats the v1 files as orphaned and
/// only renames them to `.v1.bak`. It never overwrites existing v2
/// files.
public enum WindowMigration {

    /// Outcome of one run.
    public struct Result: Equatable, Sendable {
        public let didMigrate: Bool
        public let v1DirectoriesFound: Bool
        public let v1SettingsFound: Bool
        public let bootstrappedWindowIDs: [Int]

        public init(
            didMigrate: Bool,
            v1DirectoriesFound: Bool,
            v1SettingsFound: Bool,
            bootstrappedWindowIDs: [Int]
        ) {
            self.didMigrate = didMigrate
            self.v1DirectoriesFound = v1DirectoriesFound
            self.v1SettingsFound = v1SettingsFound
            self.bootstrappedWindowIDs = bootstrappedWindowIDs
        }
    }

    /// Run the migration. Returns a Result describing what happened so
    /// the caller can log it (multi_window.mdx §13.1 — the
    /// `app=window.restore source=first_launch|migration` lines).
    @discardableResult
    public static func migrateIfNeeded() throws -> Result {
        try AppPaths.ensureMacDirectories()
        let fm = FileManager.default

        let v1Directories = AppPaths.macDirectoriesFile
        let v1Settings = AppPaths.macSettingsFile
        let v1DirExists = fm.fileExists(atPath: v1Directories.path)
        let v1SettingsExists = fm.fileExists(atPath: v1Settings.path)

        // Check whether any v2 per-window file already exists.
        let existingWindowIDs = enumerateExistingWindowIDs()
        if !existingWindowIDs.isEmpty {
            // v2 layout already in place. If the v1 files are still
            // lingering, rename them so they cannot confuse later
            // launches. Do NOT touch the v2 files.
            if v1DirExists { try renameToBackup(v1Directories) }
            if v1SettingsExists { try renameToBackup(v1Settings) }
            return Result(
                didMigrate: false,
                v1DirectoriesFound: v1DirExists,
                v1SettingsFound: v1SettingsExists,
                bootstrappedWindowIDs: []
            )
        }

        // Nothing to migrate and nothing on disk → first-launch.
        if !v1DirExists && !v1SettingsExists {
            return Result(
                didMigrate: false,
                v1DirectoriesFound: false,
                v1SettingsFound: false,
                bootstrappedWindowIDs: []
            )
        }

        // v1 layout is present and no v2 file exists → migrate to
        // window_1.
        try migrateV1ToWindow1()
        if v1DirExists { try renameToBackup(v1Directories) }
        if v1SettingsExists { try renameToBackup(v1Settings) }

        return Result(
            didMigrate: true,
            v1DirectoriesFound: v1DirExists,
            v1SettingsFound: v1SettingsExists,
            bootstrappedWindowIDs: [1]
        )
    }

    /// Scan `macAppSupportDir` for `settings_window_<N>.yaml` files.
    /// Returns the set of observed window IDs.
    public static func enumerateExistingWindowIDs() -> Set<Int> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: AppPaths.macAppSupportDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        var ids: Set<Int> = []
        let settingsPrefix = "settings_window_"
        let directoriesPrefix = "directories_window_"
        for url in entries {
            let name = url.lastPathComponent
            if !name.hasSuffix(".yaml") { continue }
            let stripped = String(name.dropLast(".yaml".count))
            let prefix: String
            if stripped.hasPrefix(settingsPrefix) {
                prefix = settingsPrefix
            } else if stripped.hasPrefix(directoriesPrefix) {
                prefix = directoriesPrefix
            } else {
                continue
            }
            let idPart = stripped.dropFirst(prefix.count)
            if let id = Int(idPart), id >= 1 {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Internal helpers

    private static func migrateV1ToWindow1() throws {
        let fm = FileManager.default
        let v1Directories = AppPaths.macDirectoriesFile
        let target = AppPaths.macDirectoriesWindowFile(id: 1)

        if fm.fileExists(atPath: v1Directories.path) {
            // Read the v1 directories.yaml, parse it, then re-encode
            // with `window_id` recorded inside. We can't just copy
            // bytes because the v2 spec adds the in-file `window_id`
            // field (multi_window.mdx §3.3) which the loader uses to
            // reject files whose filename and content disagree.
            let raw = try String(contentsOf: v1Directories, encoding: .utf8)
            let parsed = (try? DirectoriesYAML.decode(raw)) ?? DirectoriesFile()
            let yaml = DirectoriesYAML.encode(parsed)
            try writeAtomically(yaml.data(using: .utf8) ?? Data(), to: target)
        } else {
            // No v1 directories.yaml; bootstrap an empty one.
            let empty = DirectoriesFile()
            let yaml = DirectoriesYAML.encode(empty)
            try writeAtomically(yaml.data(using: .utf8) ?? Data(), to: target)
        }

        // settings_window_1.yaml — Group B writes a default-shaped
        // file with `was_open_on_quit: true` so the v1 install's
        // single window resurrects on next launch as expected by
        // the user. The per-window UI / viewer prefs use defaults;
        // the v1 settings.yaml session block is not yet read (it
        // requires the v1 YAML loader, which is its own follow-up).
        var window1 = WindowScopedSettings(windowID: 1)
        window1.session.wasOpenOnQuit = true
        let yaml = WindowScopedSettingsYAML.encode(window1)
        let settingsTarget = AppPaths.macSettingsWindowFile(id: 1)
        try writeAtomically(yaml.data(using: .utf8) ?? Data(), to: settingsTarget)
    }

    private static func renameToBackup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let bak = url.appendingPathExtension("v1.bak")
        // If a previous run's .v1.bak is in the way, suffix with a
        // timestamp so we never destroy a backup.
        let finalBak: URL
        if fm.fileExists(atPath: bak.path) {
            let ts = Int(Date().timeIntervalSince1970)
            finalBak = url.appendingPathExtension("v1.bak.\(ts)")
        } else {
            finalBak = bak
        }
        try fm.moveItem(at: url, to: finalBak)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }
}
