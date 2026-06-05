import Foundation
import Observation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Reactive store for the current theme selection.
///
/// Two orthogonal pieces of state:
///
/// 1. `appearanceMode` — light / dark / system. `.system` (the default) means
///    the app follows the macOS appearance setting: a dark theme is used in
///    Dark Mode, a light theme in Light Mode. `.light` / `.dark` lock the
///    app to one side regardless of the OS.
/// 2. `lightTheme` / `darkTheme` — the user's preferred theme on each side
///    of the light/dark divide. Each theme pack declares an `isDarkMode`
///    flag, so a single user choice writes to whichever side matches.
///
/// `currentTheme` is computed: when `appearanceMode` is `.system` it depends
/// on the current `systemColorScheme`; otherwise it's whichever side is
/// locked in.
///
/// All three preferences persist as one-line plain-text files under
/// `~/Library/Application Support/ImageGlass/`:
///   - `appearance-mode.txt`     (light/dark/system)
///   - `current-theme-light.txt` (theme name)
///   - `current-theme-dark.txt`  (theme name)
///
/// Backwards compat: `current-theme.txt` is still read on first launch and
/// migrated to the appropriate light/dark file.
@MainActor
@Observable
public final class ThemeStore {

    public private(set) var availableThemes: [Theme] = []

    /// Active selection on the light side. Used when the system is in
    /// Light Mode or `appearanceMode == .light`.
    public private(set) var lightTheme: Theme = BuiltinThemes.light

    /// Active selection on the dark side. Used when the system is in
    /// Dark Mode or `appearanceMode == .dark`.
    public private(set) var darkTheme: Theme = BuiltinThemes.dark

    /// Light / Dark / System.
    public private(set) var appearanceMode: ThemeAppearanceMode = .system

    /// The current OS color scheme. SwiftUI views feed
    /// `@Environment(\.colorScheme)` into this so `currentTheme` updates
    /// when the user toggles macOS between Light and Dark.
    public var systemColorScheme: SystemColorScheme = .light {
        didSet { /* observed by SwiftUI consumers */ }
    }

    /// The theme that should be applied to the UI right now.
    public var currentTheme: Theme {
        switch appearanceMode {
        case .light:  return lightTheme
        case .dark:   return darkTheme
        case .system: return systemColorScheme == .dark ? darkTheme : lightTheme
        }
    }

    private let catalog: ThemeCatalog

    public init(catalog: ThemeCatalog = ThemeCatalog()) {
        self.catalog = catalog
    }

    // MARK: - Bootstrap

    /// Refresh the catalog from disk and apply the persisted selections.
    /// Safe to call multiple times.
    public func bootstrap() {
        let _trace = PerformanceLog.shared.start("Theme.Load")
        defer { _trace.finish() }
        do {
            try AppPaths.ensureThemesDirectory()
        } catch {
            ErrorLog.log("ensureThemesDirectory failed during bootstrap",
                         error: error,
                         class: "ThemeStore")
        }
        availableThemes = catalog.installedThemes()

        // Migrate the legacy single `current-theme.txt` selection on first
        // launch: classify it by the theme's own dark/light flag and write
        // it into the matching paired-theme file. We only do this once —
        // afterwards the paired files own the selection.
        migrateLegacyCurrentThemeIfNeeded()

        let modeResult: ThemeAppearanceMode?
        do {
            modeResult = try readPersistedAppearanceMode()
        } catch {
            ErrorLog.log("failed to read persisted appearance mode",
                         error: error,
                         class: "ThemeStore")
            modeResult = nil
        }
        if let mode = modeResult {
            appearanceMode = mode
        }

        let lightName: String?
        do {
            lightName = try readPersistedThemeName(side: .light)
        } catch {
            ErrorLog.log("failed to read persisted light theme name",
                         error: error,
                         class: "ThemeStore")
            lightName = nil
        }
        if let name = lightName,
           let theme = lookup(name), theme.settings.isDarkMode == false {
            lightTheme = theme
        } else {
            lightTheme = BuiltinThemes.light
        }

        let darkName: String?
        do {
            darkName = try readPersistedThemeName(side: .dark)
        } catch {
            ErrorLog.log("failed to read persisted dark theme name",
                         error: error,
                         class: "ThemeStore")
            darkName = nil
        }
        if let name = darkName,
           let theme = lookup(name), theme.settings.isDarkMode == true {
            darkTheme = theme
        } else {
            darkTheme = BuiltinThemes.dark
        }
    }

    /// Re-scan installed themes without changing the current selection.
    /// If a previously-selected theme was uninstalled, fall back to the
    /// built-in default on that side.
    public func refreshAvailable() {
        availableThemes = catalog.installedThemes()
        if !availableThemes.contains(where: { $0.name == lightTheme.name }) {
            lightTheme = BuiltinThemes.light
            do {
                try writePersistedThemeName(lightTheme.name, side: .light)
            } catch {
                ErrorLog.log("failed to persist fallback light theme name",
                             error: error,
                             class: "ThemeStore")
            }
        }
        if !availableThemes.contains(where: { $0.name == darkTheme.name }) {
            darkTheme = BuiltinThemes.dark
            do {
                try writePersistedThemeName(darkTheme.name, side: .dark)
            } catch {
                ErrorLog.log("failed to persist fallback dark theme name",
                             error: error,
                             class: "ThemeStore")
            }
        }
    }

    // MARK: - Setters

    /// Switch to a theme by name. The theme is assigned to whichever side
    /// (light/dark) matches its `isDarkMode` flag, and persisted.
    /// Returns `false` if the name is unknown.
    @discardableResult
    public func setCurrentTheme(byName name: String) -> Bool {
        let _trace = PerformanceLog.shared.start("Theme.Switch", extra: [("theme", name)])
        defer { _trace.finish() }
        guard let theme = lookup(name) else { return false }
        if theme.settings.isDarkMode {
            darkTheme = theme
            do {
                try writePersistedThemeName(theme.name, side: .dark)
            } catch {
                ErrorLog.log("failed to persist dark theme selection '\(theme.name)'",
                             error: error,
                             class: "ThemeStore")
            }
        } else {
            lightTheme = theme
            do {
                try writePersistedThemeName(theme.name, side: .light)
            } catch {
                ErrorLog.log("failed to persist light theme selection '\(theme.name)'",
                             error: error,
                             class: "ThemeStore")
            }
        }
        if !availableThemes.contains(where: { $0.name == theme.name }) {
            availableThemes.append(theme)
        }
        return true
    }

    /// Switch the user's appearance preference (light / dark / system) and
    /// persist it.
    public func setAppearanceMode(_ mode: ThemeAppearanceMode) {
        appearanceMode = mode
        do {
            try writePersistedAppearanceMode(mode)
        } catch {
            ErrorLog.log("failed to persist appearance mode '\(mode.rawValue)'",
                         error: error,
                         class: "ThemeStore")
        }
    }

    /// Update which OS color scheme the app is currently rendering under.
    /// SwiftUI views observe `@Environment(\.colorScheme)` and forward
    /// changes to this property so `currentTheme` recomputes.
    public func updateSystemColorScheme(_ scheme: SystemColorScheme) {
        if systemColorScheme != scheme {
            systemColorScheme = scheme
        }
    }

    // MARK: - Helpers

    private func lookup(_ name: String) -> Theme? {
        if let m = availableThemes.first(where: { $0.name == name }) { return m }
        return catalog.theme(named: name)
    }

    // MARK: - Persistence (plain-text, one line)

    private enum Side { case light, dark }

    private func readPersistedThemeName(side: Side) throws -> String? {
        let url = side == .light ? AppPaths.currentLightThemeFile : AppPaths.currentDarkThemeFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writePersistedThemeName(_ name: String, side: Side) throws {
        try AppPaths.ensureThemesDirectory()
        let url = side == .light ? AppPaths.currentLightThemeFile : AppPaths.currentDarkThemeFile
        try (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPersistedAppearanceMode() throws -> ThemeAppearanceMode? {
        let url = AppPaths.appearanceModeFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThemeAppearanceMode(rawValue: trimmed)
    }

    private func writePersistedAppearanceMode(_ mode: ThemeAppearanceMode) throws {
        try AppPaths.ensureThemesDirectory()
        let url = AppPaths.appearanceModeFile
        try (mode.rawValue + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads the old `current-theme.txt` (if it still exists) and seeds the
    /// matching paired file, then deletes the legacy file. No-op on a clean
    /// install or once migration has already happened.
    private func migrateLegacyCurrentThemeIfNeeded() {
        let legacy = AppPaths.currentThemeFile
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        let raw: String
        do {
            raw = try String(contentsOf: legacy, encoding: .utf8)
        } catch {
            ErrorLog.log("failed to read legacy current-theme.txt at \(legacy.path)",
                         error: error,
                         class: "ThemeStore")
            return
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let theme = lookup(name) else {
            do {
                try fm.removeItem(at: legacy)
            } catch {
                ErrorLog.log("failed to remove legacy current-theme.txt at \(legacy.path)",
                             error: error,
                             class: "ThemeStore")
            }
            return
        }
        let side: Side = theme.settings.isDarkMode ? .dark : .light
        let target = side == .light ? AppPaths.currentLightThemeFile : AppPaths.currentDarkThemeFile
        if !fm.fileExists(atPath: target.path) {
            do {
                try writePersistedThemeName(theme.name, side: side)
            } catch {
                ErrorLog.log("failed to migrate legacy theme name '\(theme.name)' to paired file",
                             error: error,
                             class: "ThemeStore")
            }
        }
        do {
            try fm.removeItem(at: legacy)
        } catch {
            ErrorLog.log("failed to remove legacy current-theme.txt after migration",
                         error: error,
                         class: "ThemeStore")
        }
    }
}

/// A non-SwiftUI mirror of `SwiftUI.ColorScheme` so the core module stays
/// usable without forcing SwiftUI down everyone's throat (the CLI / MCP
/// targets don't link SwiftUI).
public enum SystemColorScheme: String, Sendable, Equatable {
    case light
    case dark
}
