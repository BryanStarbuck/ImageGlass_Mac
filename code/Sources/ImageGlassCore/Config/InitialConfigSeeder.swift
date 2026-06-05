import Foundation

/// Seeds the Mac-fork's plain-text YAML configuration files when they
/// are missing from disk. Called once at app launch so a fresh machine
/// — with nothing under `~/Library/Application Support/ImageGlass_Mac/`
/// — gets a complete, human-readable starting state instead of the
/// historical "no settings.json on disk" failure mode.
///
/// What gets seeded:
/// * `settings.yaml`  — `Settings.defaults` projected to YAML.
/// * `panels.yaml`    — the Browser preset (default panel layout).
///
/// Idempotent: an existing file is left untouched. The runtime stores
/// (`SettingsStore` for JSON, `PanelStateYAMLStore` for layout) keep
/// owning their respective writes; this seeder only fills the empty
/// state on first launch.
public enum InitialConfigSeeder {

    /// Run on app launch (or any other safe-to-create-files moment).
    /// Returns the list of files that were actually written so the
    /// caller can log them.
    @discardableResult
    public static func seedIfMissing(directory: URL? = nil) -> [URL] {
        let _trace = PerformanceLog.shared.start("Config.Seed")
        defer { _trace.finish() }
        let dir = directory ?? AppPaths.macAppSupportDir
        var seeded: [URL] = []

        do {
            try ensureDirectory(dir)
        } catch {
            ErrorLog.log("InitialConfigSeeder: failed to create \(dir.path)",
                         error: error, class: "InitialConfigSeeder")
            return seeded
        }

        let settingsURL = dir.appendingPathComponent("settings.yaml")
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let yaml = try SettingsYAML.encode(Settings.defaults)
                try atomicWrite(yaml, to: settingsURL)
                seeded.append(settingsURL)
            } catch {
                ErrorLog.log("InitialConfigSeeder: settings.yaml seed failed",
                             error: error, class: "InitialConfigSeeder")
            }
        }

        let panelsURL = dir.appendingPathComponent("panels.yaml")
        if !FileManager.default.fileExists(atPath: panelsURL.path) {
            let yaml = PanelStateYAML.encode(PresetCatalog.defaultLayout)
            do {
                try atomicWrite(yaml, to: panelsURL)
                seeded.append(panelsURL)
            } catch {
                ErrorLog.log("InitialConfigSeeder: panels.yaml seed failed",
                             error: error, class: "InitialConfigSeeder")
            }
        }

        return seeded
    }

    // MARK: - Internals

    private static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func atomicWrite(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "InitialConfigSeeder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "UTF-8 encoding failed for \(url.lastPathComponent)"
            ])
        }
        let tmp = url.deletingPathExtension()
            .appendingPathExtension("yaml.seed.tmp")
        try data.write(to: tmp, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
