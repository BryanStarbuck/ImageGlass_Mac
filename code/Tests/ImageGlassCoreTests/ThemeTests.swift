import XCTest
@testable import ImageGlassCore

final class ThemeTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    /// Redirect HOME so any code reaching NSHomeDirectory()/FileManager
    /// applicationSupportDirectory writes into our scratch tree.
    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        // Also create the standard Library/Application Support tree under it
        // so FileManager.default.url(for:.applicationSupportDirectory...) finds
        // a writable path rooted at our temp home.
        let appSupportRoot = tmpHome
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appSupportRoot, withIntermediateDirectories: true
        )
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let original = originalHome {
            setenv("HOME", original, 1)
        } else {
            unsetenv("HOME")
        }
    }

    // MARK: - Catalog

    func testCatalogReturnsBuiltinsByDefault() {
        let catalog = ThemeCatalog()
        let themes = catalog.installedThemes()
        XCTAssertEqual(themes.count, 2)
        XCTAssertTrue(themes.contains(where: { $0.name == Theme.Builtin.darkName }))
        XCTAssertTrue(themes.contains(where: { $0.name == Theme.Builtin.lightName }))
    }

    func testCatalogReadsInstalledThemeFolder() throws {
        try AppPaths.ensureThemesDirectory()
        let folder = AppPaths.themesDir.appendingPathComponent("Test.SomeAuthor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let theme = Theme(
            name: "Test.SomeAuthor",
            info: .init(name: "Test", version: "1.0", description: "x", author: "SomeAuthor", contact: ""),
            settings: .init(isDarkMode: true),
            colors: .init(accent: "#FF0000"),
            toolbarIcons: ["zoom_in": "zoom_in.svg"]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(theme)
        try data.write(to: folder.appendingPathComponent("igtheme.json"))

        let catalog = ThemeCatalog()
        let all = catalog.installedThemes()
        XCTAssertTrue(all.contains(where: { $0.name == "Test.SomeAuthor" }))

        let installed = catalog.scanInstalledThemeFolders()
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed[0].name, "Test.SomeAuthor")
        XCTAssertEqual(installed[0].info.author, "SomeAuthor")
        XCTAssertEqual(installed[0].colors.accent, "#FF0000")
        XCTAssertEqual(installed[0].toolbarIcons["zoom_in"], "zoom_in.svg")
        XCTAssertNotNil(installed[0].folderURL)
    }

    func testCatalogSkipsInvalidManifests() throws {
        try AppPaths.ensureThemesDirectory()
        let folder = AppPaths.themesDir.appendingPathComponent("Broken.X", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("igtheme.json"))

        let catalog = ThemeCatalog()
        let installed = catalog.scanInstalledThemeFolders()
        XCTAssertEqual(installed.count, 0)
    }

    // MARK: - Store persistence round-trip

    @MainActor
    func testStoreBootstrapDefaultsToSystemModeAndPairedBuiltins() {
        let store = ThemeStore()
        store.bootstrap()
        XCTAssertEqual(store.appearanceMode, .system)
        XCTAssertEqual(store.lightTheme.name, Theme.Builtin.lightName)
        XCTAssertEqual(store.darkTheme.name, Theme.Builtin.darkName)
        XCTAssertEqual(store.availableThemes.count, 2)
    }

    @MainActor
    func testStoreCurrentThemeFollowsSystemColorScheme() {
        let store = ThemeStore()
        store.bootstrap()
        store.updateSystemColorScheme(.light)
        XCTAssertEqual(store.currentTheme.name, Theme.Builtin.lightName)
        store.updateSystemColorScheme(.dark)
        XCTAssertEqual(store.currentTheme.name, Theme.Builtin.darkName)
    }

    @MainActor
    func testStoreLockedLightModeIgnoresSystemColorScheme() {
        let store = ThemeStore()
        store.bootstrap()
        store.setAppearanceMode(.light)
        store.updateSystemColorScheme(.dark)
        XCTAssertEqual(store.currentTheme.name, Theme.Builtin.lightName)
    }

    @MainActor
    func testStorePersistsLightSelectionToLightFile() throws {
        let store = ThemeStore()
        store.bootstrap()
        XCTAssertTrue(store.setCurrentTheme(byName: Theme.Builtin.lightName))

        let url = AppPaths.currentLightThemeFile
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), Theme.Builtin.lightName)

        // Re-bootstrap reads it back.
        let store2 = ThemeStore()
        store2.bootstrap()
        XCTAssertEqual(store2.lightTheme.name, Theme.Builtin.lightName)
    }

    @MainActor
    func testStorePersistsAppearanceMode() throws {
        let store = ThemeStore()
        store.bootstrap()
        store.setAppearanceMode(.dark)

        let url = AppPaths.appearanceModeFile
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "dark")

        let store2 = ThemeStore()
        store2.bootstrap()
        XCTAssertEqual(store2.appearanceMode, .dark)
    }

    @MainActor
    func testStoreRejectsUnknownTheme() {
        let store = ThemeStore()
        store.bootstrap()
        XCTAssertFalse(store.setCurrentTheme(byName: "does-not-exist"))
        XCTAssertEqual(store.lightTheme.name, Theme.Builtin.lightName)
        XCTAssertEqual(store.darkTheme.name, Theme.Builtin.darkName)
    }

    @MainActor
    func testStoreFallsBackWhenPersistedThemeUninstalled() throws {
        // A persisted paired-file pointing at a missing theme — bootstrap
        // should fall back to the built-in for that side.
        try AppPaths.ensureThemesDirectory()
        try "ghost-theme\n".write(to: AppPaths.currentDarkThemeFile, atomically: true, encoding: .utf8)

        let store = ThemeStore()
        store.bootstrap()
        XCTAssertEqual(store.darkTheme.name, Theme.Builtin.darkName)
    }

    @MainActor
    func testStoreMigratesLegacyCurrentThemeFile() throws {
        try AppPaths.ensureThemesDirectory()
        // Legacy single-file selection of the built-in light theme.
        try "\(Theme.Builtin.lightName)\n".write(
            to: AppPaths.currentThemeFile, atomically: true, encoding: .utf8
        )

        let store = ThemeStore()
        store.bootstrap()
        XCTAssertEqual(store.lightTheme.name, Theme.Builtin.lightName)

        // Legacy file is removed and the paired light file now holds the value.
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.currentThemeFile.path))
        let raw = try String(contentsOf: AppPaths.currentLightThemeFile, encoding: .utf8)
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), Theme.Builtin.lightName)
    }

    // MARK: - Appearance mode enum

    func testAppearanceModeRoundTrip() {
        XCTAssertEqual(ThemeAppearanceMode(rawValue: "light"), .light)
        XCTAssertEqual(ThemeAppearanceMode(rawValue: "dark"), .dark)
        XCTAssertEqual(ThemeAppearanceMode(rawValue: "system"), .system)
        XCTAssertEqual(ThemeAppearanceMode(rawValue: "auto"), .system)
        XCTAssertEqual(ThemeAppearanceMode(rawValue: ""), .system)
        XCTAssertNil(ThemeAppearanceMode(rawValue: "purple"))
    }

    // MARK: - MCP tools

    func testMCPListThemesIncludesBuiltins() throws {
        let tools = MCPTools()
        let result = try tools.call(name: "list_themes", arguments: [:])
        XCTAssertFalse(result.isError ?? false)
        let body = result.content.first?.text ?? ""
        XCTAssertTrue(body.contains(Theme.Builtin.darkName))
        XCTAssertTrue(body.contains(Theme.Builtin.lightName))
    }

    func testMCPGetCurrentThemeReportsBothSidesAndMode() throws {
        let tools = MCPTools()
        let result = try tools.call(name: "get_current_theme", arguments: [:])
        XCTAssertFalse(result.isError ?? false)
        let body = result.content.first?.text ?? ""
        XCTAssertTrue(body.contains("appearanceMode"))
        XCTAssertTrue(body.contains(Theme.Builtin.lightName))
        XCTAssertTrue(body.contains(Theme.Builtin.darkName))
    }

    func testMCPSetCurrentThemePersistsToCorrectSideFile() throws {
        let tools = MCPTools()
        let setResult = try tools.call(name: "set_current_theme", arguments: [
            "name": Theme.Builtin.lightName,
        ])
        XCTAssertFalse(setResult.isError ?? false)

        // The light file (not the dark file) gets written.
        let raw = try String(contentsOf: AppPaths.currentLightThemeFile, encoding: .utf8)
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), Theme.Builtin.lightName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.currentDarkThemeFile.path))

        // Subsequent get reflects the change.
        let getResult = try tools.call(name: "get_current_theme", arguments: [:])
        XCTAssertTrue((getResult.content.first?.text ?? "").contains(Theme.Builtin.lightName))
    }

    func testMCPSetCurrentThemeRejectsUnknown() throws {
        let tools = MCPTools()
        let result = try tools.call(name: "set_current_theme", arguments: ["name": "no-such-theme"])
        XCTAssertTrue(result.isError ?? false)
    }

    func testMCPGetAndSetAppearanceMode() throws {
        let tools = MCPTools()
        let setResult = try tools.call(name: "set_appearance_mode", arguments: ["mode": "dark"])
        XCTAssertFalse(setResult.isError ?? false)

        let getResult = try tools.call(name: "get_appearance_mode", arguments: [:])
        XCTAssertTrue((getResult.content.first?.text ?? "").contains("\"dark\""))
    }

    func testMCPSetAppearanceModeRejectsUnknown() throws {
        let tools = MCPTools()
        let result = try tools.call(name: "set_appearance_mode", arguments: ["mode": "purple"])
        XCTAssertTrue(result.isError ?? false)
    }

    func testMCPDescriptorsExposeThemeTools() {
        let tools = MCPTools()
        let names = Set(tools.descriptors().map { $0.name })
        XCTAssertTrue(names.contains("list_themes"))
        XCTAssertTrue(names.contains("get_current_theme"))
        XCTAssertTrue(names.contains("set_current_theme"))
        XCTAssertTrue(names.contains("get_appearance_mode"))
        XCTAssertTrue(names.contains("set_appearance_mode"))
    }
}
