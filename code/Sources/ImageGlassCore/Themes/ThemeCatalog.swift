import Foundation

/// Discovers installed themes on disk.
///
/// Layout (managed by the `.igtheme` loader — separate agent):
/// ```
/// ~/Library/Application Support/ImageGlass/themes/
///   ├─ Kobe.Duong-Dieu-Phap/
///   │   ├─ igtheme.json
///   │   ├─ preview.webp
///   │   └─ *.svg
///   └─ ko-Z.SomeAuthor/
///       └─ igtheme.json ...
/// ```
///
/// This catalog scans that directory, reads each `igtheme.json` manifest, and
/// returns parsed `Theme` values. It also always exposes the built-in themes
/// so the UI has something to render before any pack is installed.
///
/// The catalog does NOT install / uninstall packs — the `theme-pack.mdx` agent
/// owns that. We just read what's already on disk in the documented layout.
public struct ThemeCatalog {

    public init() {}

    /// Returns built-ins plus any valid themes found in `themesDir`.
    /// Invalid manifests are skipped silently.
    public func installedThemes() -> [Theme] {
        var all = BuiltinThemes.all
        all.append(contentsOf: scanInstalledThemeFolders())
        return all
    }

    /// Look up a single theme by name. Checks built-ins first, then disk.
    public func theme(named name: String) -> Theme? {
        if let builtin = BuiltinThemes.named(name) { return builtin }
        return scanInstalledThemeFolders().first(where: { $0.name == name })
    }

    /// Just the disk-installed themes (no built-ins).
    public func scanInstalledThemeFolders() -> [Theme] {
        let _trace = PerformanceLog.shared.start("Theme.ScanCatalog")
        defer { _trace.finish() }
        let fm = FileManager.default
        let dir = AppPaths.themesDir
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            ErrorLog.log("contentsOfDirectory failed for \(dir.path)",
                         error: error,
                         class: "ThemeCatalog")
            return []
        }

        var out: [Theme] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            do {
                let theme = try loadTheme(fromFolder: entry)
                out.append(theme)
            } catch {
                // By design (see ThemeTests.testCatalogSkipsInvalidManifests):
                // invalid manifests are silently skipped. Use NSLog so the
                // skip is still visible to developers but does not pollute
                // the user-facing error stream on every launch.
                NSLog("ThemeCatalog: skipping invalid theme '%@': %@",
                      entry.lastPathComponent,
                      String(describing: error))
            }
        }
        return out
    }

    /// Load a single theme from an on-disk folder containing `igtheme.json`.
    /// The pack-loader agent calls this after extracting a `.igtheme` archive
    /// into the themes directory — that way both code paths produce identical
    /// `Theme` values.
    public func loadTheme(fromFolder folder: URL) throws -> Theme {
        let manifestURL = folder.appendingPathComponent("igtheme.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        var theme = try decoder.decode(Theme.self, from: data)
        // Authoritative: folder name overrides whatever the file says.
        theme.name = folder.lastPathComponent
        theme.folderURL = folder
        return theme
    }
}

// MARK: - Path extension

extension AppPaths {
    /// Directory holding one folder per installed theme pack.
    public static var themesDir: URL {
        appSupportDir.appendingPathComponent("themes", isDirectory: true)
    }

    /// Plain-text file recording the user's currently selected theme name.
    /// One line, just the theme name. Fork charter: plain-text persistence.
    public static var currentThemeFile: URL {
        appSupportDir.appendingPathComponent("current-theme.txt")
    }

    /// Plain-text file recording the user's currently selected LIGHT-side
    /// theme name. Used when the appearance mode is `.system` (so the OS
    /// switches between light and dark) or `.light` (locked light).
    public static var currentLightThemeFile: URL {
        appSupportDir.appendingPathComponent("current-theme-light.txt")
    }

    /// Plain-text file recording the user's currently selected DARK-side
    /// theme name. Counterpart of `currentLightThemeFile`.
    public static var currentDarkThemeFile: URL {
        appSupportDir.appendingPathComponent("current-theme-dark.txt")
    }

    /// Plain-text file recording the user's appearance mode (`light`,
    /// `dark`, or `system`). One line.
    public static var appearanceModeFile: URL {
        appSupportDir.appendingPathComponent("appearance-mode.txt")
    }

    /// Ensure the themes directory exists.
    /// Called separately from `ensureDirectories()` so we don't fight the
    /// scope/MCP bootstrap path — the theme subsystem is self-contained.
    public static func ensureThemesDirectory() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, themesDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
