import Foundation
import Observation

/// Reactive store for the current theme selection.
///
/// - `availableThemes` is the catalog of installed + built-in themes.
/// - `currentTheme` is whatever the user picked last (persisted in a plain-text
///   file under `~/Library/Application Support/ImageGlass/current-theme.txt`).
/// - `setCurrentTheme(byName:)` writes that file and updates `currentTheme`.
///
/// SwiftUI consumes this via `@Bindable` or by reading `currentTheme.colors.*`
/// through the `Color` accessors in `Theme+SwiftUI.swift`.
@MainActor
@Observable
public final class ThemeStore {

    public private(set) var availableThemes: [Theme] = []
    public private(set) var currentTheme: Theme = BuiltinThemes.defaultTheme

    private let catalog: ThemeCatalog

    public init(catalog: ThemeCatalog = ThemeCatalog()) {
        self.catalog = catalog
    }

    /// Refresh the catalog from disk and apply the persisted selection.
    /// Safe to call multiple times.
    public func bootstrap() {
        try? AppPaths.ensureThemesDirectory()
        availableThemes = catalog.installedThemes()
        let persistedName = (try? readPersistedThemeName()) ?? BuiltinThemes.defaultTheme.name
        if let match = availableThemes.first(where: { $0.name == persistedName }) {
            currentTheme = match
        } else {
            currentTheme = BuiltinThemes.defaultTheme
        }
    }

    /// Re-scan installed themes without changing the current selection.
    public func refreshAvailable() {
        availableThemes = catalog.installedThemes()
        // If the current theme was uninstalled, fall back to the default.
        if !availableThemes.contains(where: { $0.name == currentTheme.name }) {
            currentTheme = BuiltinThemes.defaultTheme
            try? writePersistedThemeName(currentTheme.name)
        }
    }

    /// Switch to a theme by name. Returns `false` if the name is unknown.
    @discardableResult
    public func setCurrentTheme(byName name: String) -> Bool {
        guard let theme = availableThemes.first(where: { $0.name == name })
            ?? catalog.theme(named: name) else {
            return false
        }
        currentTheme = theme
        if !availableThemes.contains(where: { $0.name == theme.name }) {
            availableThemes.append(theme)
        }
        try? writePersistedThemeName(theme.name)
        return true
    }

    // MARK: - Persistence (plain-text, one line)

    private func readPersistedThemeName() throws -> String {
        let url = AppPaths.currentThemeFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BuiltinThemes.defaultTheme.name
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? BuiltinThemes.defaultTheme.name : trimmed
    }

    private func writePersistedThemeName(_ name: String) throws {
        try AppPaths.ensureThemesDirectory()
        let url = AppPaths.currentThemeFile
        let body = name + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
