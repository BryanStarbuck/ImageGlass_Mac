import XCTest
@testable import ImageGlassCore

final class ConfigLoaderTests: XCTestCase {

    private var rootDir: URL!
    private var startupDir: URL!
    private var userDir: URL!
    private var savedHome: String?

    override func setUpWithError() throws {
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-config-test-\(UUID().uuidString)", isDirectory: true)
        startupDir = rootDir.appendingPathComponent("Startup", isDirectory: true)
        userDir = rootDir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: startupDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Rebind HOME so any code that uses AppPaths.homeDirectory points
        // at the throw-away root.
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", rootDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let h = savedHome {
            setenv("HOME", h, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: rootDir)
    }

    private func writeJSON(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private func paths(portable: Bool = false) -> ConfigPaths {
        if portable {
            try? Data().write(to: startupDir.appendingPathComponent(ConfigPaths.portableFlagName))
        }
        return ConfigPaths.resolve(startupDir: startupDir, userConfigDir: userDir)
    }

    // MARK: - Built-in defaults

    func testBuiltInDefaultsWhenNoFiles() throws {
        let loader = ConfigLoader(paths: paths())
        let r = try loader.resolve()
        XCTAssertEqual(r.config, .builtIn)
        XCTAssertTrue(r.config.showToolbar)
        XCTAssertTrue(r.config.showGallery)
        XCTAssertEqual(r.config.windowBackdrop, .none)
        XCTAssertNil(r.layers.defaultFile)
        XCTAssertNil(r.layers.userFile)
        XCTAssertNil(r.layers.adminFile)
    }

    // MARK: - Layer-by-layer priority

    func testDefaultFileOverridesBuiltIn() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": false}"#, to: p.defaultFileURL)
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertFalse(r.config.showToolbar)
        // Untouched fields still match built-in.
        XCTAssertTrue(r.config.showGallery)
    }

    func testUserFileOverridesDefaultFile() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": false, "ShowGallery": false}"#, to: p.defaultFileURL)
        try writeJSON(#"{"ShowToolbar": true}"#, to: p.userFileURL)
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertTrue(r.config.showToolbar, "user file must override default file")
        XCTAssertFalse(r.config.showGallery, "default-only field survives")
    }

    func testCLIOverridesUserFile() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": true}"#, to: p.userFileURL)
        let cli = CLIOverrides.parse(["/ShowToolbar=false"])
        let r = try ConfigLoader(paths: p).resolve(cli: cli)
        XCTAssertFalse(r.config.showToolbar)
    }

    func testAdminFileOverridesEverything() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": false}"#, to: p.defaultFileURL)
        try writeJSON(#"{"ShowToolbar": false}"#, to: p.userFileURL)
        let cli = CLIOverrides.parse(["/ShowToolbar=false"])
        try writeJSON(#"{"ShowToolbar": true, "WindowBackdrop": "Acrylic"}"#, to: p.adminFileURL)
        let r = try ConfigLoader(paths: p).resolve(cli: cli)
        XCTAssertTrue(r.config.showToolbar, "admin file is highest priority")
        XCTAssertEqual(r.config.windowBackdrop, .acrylic)
    }

    func testFullPriorityChain() throws {
        // Exercises every tier on the same key to lock the spec ordering in.
        let p = paths()
        try writeJSON(#"{"Language": "from-default"}"#, to: p.defaultFileURL)
        try writeJSON(#"{"Language": "from-user"}"#, to: p.userFileURL)
        let cli = CLIOverrides.parse(["/Language=from-cli"])

        // No admin file → CLI wins.
        var r = try ConfigLoader(paths: p).resolve(cli: cli)
        XCTAssertEqual(r.config.language, "from-cli")

        // Admin file → admin wins.
        try writeJSON(#"{"Language": "from-admin"}"#, to: p.adminFileURL)
        r = try ConfigLoader(paths: p).resolve(cli: cli)
        XCTAssertEqual(r.config.language, "from-admin")
    }

    // MARK: - Portable mode

    func testPortableModeUsesStartupDirAsConfigDir() {
        let p = paths(portable: true)
        XCTAssertTrue(p.isPortable)
        XCTAssertEqual(p.configDir, p.startupDir)
        XCTAssertEqual(p.userFileURL.deletingLastPathComponent(), p.startupDir)
    }

    func testNonPortableModeUsesSeparateConfigDir() {
        let p = paths(portable: false)
        XCTAssertFalse(p.isPortable)
        XCTAssertEqual(p.configDir, userDir)
        XCTAssertNotEqual(p.configDir, p.startupDir)
    }

    // MARK: - Round-trip persistence

    func testRoundTripPersistence() throws {
        let p = paths()
        let loader = ConfigLoader(paths: p)

        var c = Config.builtIn
        c.showToolbar = false
        c.showGallery = false
        c.windowBackdrop = .acrylic
        c.theme = "Midnight"
        try loader.save(c)

        // File must exist and be pretty/sorted plain text.
        let raw = try String(contentsOf: p.userFileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\n"), "expected pretty-printed JSON")
        // Sorted keys: "Language" comes before "ShowToolbar" alphabetically.
        let languageIdx  = raw.range(of: "\"Language\"")
        let toolbarIdx   = raw.range(of: "\"ShowToolbar\"")
        XCTAssertNotNil(languageIdx)
        XCTAssertNotNil(toolbarIdx)
        XCTAssertLessThan(languageIdx!.lowerBound, toolbarIdx!.lowerBound)

        // Reload and confirm equality.
        let r = try loader.resolve()
        XCTAssertEqual(r.config, c)
    }

    func testResolveAndPersistWritesUserFile() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": false}"#, to: p.defaultFileURL)
        let loader = ConfigLoader(paths: p)
        let r = try loader.resolveAndPersist()
        XCTAssertFalse(r.config.showToolbar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.userFileURL.path))
    }

    // MARK: - CLI parsing

    func testCLIParsingExampleFromSpec() {
        // Spec example: ImageGlass.exe /ShowToolbar=false /ShowGallery=false
        //                              /WindowBackdrop="Acrylic" "C:\my photos\sky.jpg"
        let cli = CLIOverrides.parse([
            "/ShowToolbar=false",
            "/ShowGallery=false",
            "/WindowBackdrop=\"Acrylic\"",
            "C:\\my photos\\sky.jpg"
        ])
        XCTAssertEqual(cli.partial.showToolbar, false)
        XCTAssertEqual(cli.partial.showGallery, false)
        XCTAssertEqual(cli.partial.windowBackdrop, .acrylic)
        XCTAssertEqual(cli.positionalArguments, ["C:\\my photos\\sky.jpg"])
        XCTAssertEqual(cli.rawPairs.count, 3)
    }

    func testCLIParsingCaseInsensitiveKeys() {
        let cli = CLIOverrides.parse(["/showtoolbar=true", "/FULLSCREEN=true"])
        XCTAssertEqual(cli.partial.showToolbar, true)
        XCTAssertEqual(cli.partial.fullScreen, true)
    }

    func testCLIParsingBooleanForms() {
        for (s, expected) in [("true", true), ("1", true), ("yes", true), ("on", true),
                              ("false", false), ("0", false), ("no", false), ("off", false)] {
            let cli = CLIOverrides.parse(["/ShowToolbar=\(s)"])
            XCTAssertEqual(cli.partial.showToolbar, expected, "input=\(s)")
        }
    }

    func testCLIParsingIgnoresUnknownFlags() {
        let cli = CLIOverrides.parse(["/NotARealFlag=42", "/ShowToolbar=false"])
        XCTAssertTrue(cli.partial.isEmpty == false)
        XCTAssertEqual(cli.partial.showToolbar, false)
        XCTAssertEqual(cli.rawPairs.count, 2)  // both pairs preserved verbatim
    }

    func testCLIParsingRejectsMalformedValues() {
        // A non-bool value for a bool flag must NOT crash and must leave
        // the field unset so the next tier wins.
        let cli = CLIOverrides.parse(["/ShowToolbar=maybe"])
        XCTAssertNil(cli.partial.showToolbar)
    }

    func testEmptyCLIIsEmptyPartial() {
        XCTAssertTrue(CLIOverrides.parse([]).partial.isEmpty)
        XCTAssertTrue(CLIOverrides.parse(["just-a-path.jpg"]).partial.isEmpty)
    }

    // MARK: - Sparse merge semantics

    func testSparseMergePreservesUnrelatedFields() throws {
        // Default file sets ShowGallery; user file sets ShowToolbar. The
        // merged config must reflect BOTH — neither layer should reset the
        // other's field to its built-in value.
        let p = paths()
        try writeJSON(#"{"ShowGallery": false}"#, to: p.defaultFileURL)
        try writeJSON(#"{"ShowToolbar": false}"#, to: p.userFileURL)
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertFalse(r.config.showToolbar)
        XCTAssertFalse(r.config.showGallery)
    }

    // MARK: - Locked keys (admin tier)

    func testLockedKeysEmptyWhenNoAdminFile() throws {
        let p = paths()
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertTrue(r.layers.lockedKeys.isEmpty)
        XCTAssertFalse(r.layers.isLocked(.showToolbar))
    }

    func testLockedKeysReflectAdminFile() throws {
        let p = paths()
        try writeJSON(#"{"ShowToolbar": true, "WindowBackdrop": "Acrylic"}"#, to: p.adminFileURL)
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertEqual(r.layers.lockedKeys, [.showToolbar, .windowBackdrop])
        XCTAssertTrue(r.layers.isLocked(.showToolbar))
        XCTAssertTrue(r.layers.isLocked(.windowBackdrop))
        XCTAssertFalse(r.layers.isLocked(.showGallery))
    }

    // MARK: - Bundle Resources fallback

    func testBundleResourcesFallbackForDefaultFile() throws {
        // Simulate an installer that ships `igconfig.default.json` inside
        // the bundle's Resources directory. The Startup Dir has no copy —
        // the loader must pick up the bundle copy.
        let bundleRes = rootDir.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRes, withIntermediateDirectories: true)
        try writeJSON(#"{"ShowToolbar": false}"#,
                      to: bundleRes.appendingPathComponent(ConfigPaths.defaultFileName))
        let p = ConfigPaths.resolve(
            startupDir: startupDir,
            userConfigDir: userDir,
            bundleResourcesDir: bundleRes
        )
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertFalse(r.config.showToolbar, "default file from Bundle.Resources should apply")
    }

    func testStartupDirWinsOverBundleResources() throws {
        // When BOTH locations have the file, the Startup Dir (analog of the
        // Windows install dir) takes precedence so a sysadmin override
        // placed there is preferred over the installer-shipped copy.
        let bundleRes = rootDir.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRes, withIntermediateDirectories: true)
        try writeJSON(#"{"Language": "from-bundle"}"#,
                      to: bundleRes.appendingPathComponent(ConfigPaths.defaultFileName))
        let p = ConfigPaths.resolve(
            startupDir: startupDir,
            userConfigDir: userDir,
            bundleResourcesDir: bundleRes
        )
        try writeJSON(#"{"Language": "from-startup"}"#, to: p.defaultFileURL)
        let r = try ConfigLoader(paths: p).resolve()
        XCTAssertEqual(r.config.language, "from-startup")
    }

    func testPortableFlagInBundleResourcesActivatesPortableMode() throws {
        let bundleRes = rootDir.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRes, withIntermediateDirectories: true)
        try Data().write(to: bundleRes.appendingPathComponent(ConfigPaths.portableFlagName))
        let p = ConfigPaths.resolve(
            startupDir: startupDir,
            userConfigDir: userDir,
            bundleResourcesDir: bundleRes
        )
        XCTAssertTrue(p.isPortable)
        XCTAssertEqual(p.configDir, p.startupDir)
    }
}
