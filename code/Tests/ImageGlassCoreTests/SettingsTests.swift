import XCTest
@testable import ImageGlassCore

final class SettingsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-settings-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func paths() -> SettingsPaths {
        SettingsPaths(directory: dir)
    }

    // MARK: - Defaults

    func testDefaultsMatchSpec() {
        let s = Settings.defaults
        XCTAssertEqual(s.version, Settings.currentSchemaVersion)

        // §4.1 General
        XCTAssertEqual(s.general.theme_override, .system)
        XCTAssertTrue(s.general.open_last_image)
        XCTAssertTrue(s.general.multi_instance)
        XCTAssertFalse(s.general.window_top_most)
        XCTAssertFalse(s.general.start_full_screen)
        XCTAssertFalse(s.general.frameless)
        XCTAssertTrue(s.general.window_fit_centered)
        XCTAssertTrue(s.general.confirm_delete)
        XCTAssertTrue(s.general.confirm_overwrite)
        XCTAssertEqual(s.general.update_cadence, .weekly)
        XCTAssertEqual(s.general.toast_duration_ms, 2000)

        // §4.2 Image — Mac default for scale-down switched to lanczos.
        XCTAssertEqual(s.image.interp_scale_down, .lanczos)
        XCTAssertEqual(s.image.interp_scale_up, .nearest)
        XCTAssertEqual(s.image.color_profile, .currentMonitor)

        // §4.3 Viewer — Mac defaults preserve upstream.
        XCTAssertEqual(s.viewer.zoom_mode, .autoZoom)
        XCTAssertEqual(s.viewer.zoom_lock_percent, 100)
        XCTAssertEqual(s.viewer.pan_speed, 20)
        XCTAssertTrue(s.viewer.gesture_pinch_zoom)
        XCTAssertFalse(s.viewer.gesture_rotate, "rotate is off by default per §4.3")
        XCTAssertEqual(s.viewer.huge_image_threshold, 16000)

        // §4.4 Appearance
        XCTAssertEqual(s.appearance.window_material, .underWindowBackground)
        XCTAssertEqual(s.appearance.light_theme, "Kobe-Light")

        // §4.6 Slideshow
        XCTAssertEqual(s.slideshow.interval_seconds, 5.0)

        // §4.10 Gallery — default thumb_size is 128 per spec (Retina).
        XCTAssertEqual(s.gallery.thumb_size, 128)

        // §4.11 Toolbar
        XCTAssertEqual(s.toolbar.icon_height, 24)

        // §4.14.1 Tools / Crop
        XCTAssertEqual(s.tools.crop.aspect_ratio, .freeRatio)
        XCTAssertEqual(s.tools.crop.init_selection, .select50Percent)
        XCTAssertTrue(s.tools.crop.auto_center)

        // §4.14.2 Color picker
        XCTAssertEqual(s.tools.color_picker.copy_format, .hex)

        // §4.16 Advanced
        XCTAssertTrue(s.advanced.mcp.enabled)
        XCTAssertEqual(s.advanced.mcp.transport, .stdio)
        XCTAssertEqual(s.advanced.mcp.client_allowlist, ["*"])
        XCTAssertEqual(s.advanced.thumb_cache_mb, 1024)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllSections() async throws {
        let store = SettingsStore(paths: paths())
        var s = Settings.defaults
        s.general.theme_override = .dark
        s.general.confirm_delete = false
        s.image.color_profile = .displayP3
        s.image.info_tags = ["name", "size"]
        s.viewer.zoom_mode = .scaleToFit
        s.viewer.zoom_lock_percent = 200
        s.slideshow.interval_seconds = 12.5
        s.gallery.thumb_size = 256
        s.tools.crop.aspect_ratio = .sixteenToNine
        s.advanced.mcp.transport = .unixSocket
        try await store.save(s)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, s)
    }

    func testMissingFileReturnsDefaults() async throws {
        let store = SettingsStore(paths: paths())
        let s = try await store.load()
        XCTAssertEqual(s, Settings.defaults)
    }

    func testMalformedFileThrows() async throws {
        let p = paths()
        try p.ensureDirectory()
        try Data("not json".utf8).write(to: p.fileURL)
        let store = SettingsStore(paths: p)
        do {
            _ = try await store.load()
            XCTFail("expected throw on malformed JSON")
        } catch {
            // expected
        }
        // loadOrDefault must NOT throw — must fall back.
        let safe = await store.loadOrDefault()
        XCTAssertEqual(safe, Settings.defaults)
    }

    func testPartialJSONFillsMissingSectionsWithDefaults() async throws {
        let p = paths()
        try p.ensureDirectory()
        try Data(#"{"version":1,"general":{"confirm_delete":false}}"#.utf8).write(to: p.fileURL)
        let store = SettingsStore(paths: p)
        let s = try await store.load()
        XCTAssertFalse(s.general.confirm_delete)
        // Sections not present fall back to defaults.
        XCTAssertEqual(s.viewer, ViewerSettings())
        XCTAssertEqual(s.gallery.thumb_size, 128)
    }

    func testBackupRotationOnSecondSave() async throws {
        let store = SettingsStore(paths: paths())
        try await store.save(Settings.defaults)
        var s = Settings.defaults
        s.general.theme_override = .light
        try await store.save(s)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: paths().fileURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths().backupURL.path))
    }

    // MARK: - Validation

    func testValidationRejectsOutOfRange() {
        var s = Settings.defaults
        s.edit.quality = 200
        s.gallery.thumb_size = 999
        s.viewer.cache_max_dim = 10
        s.viewer.huge_image_threshold = 100
        s.toolbar.icon_height = 99
        s.slideshow.use_random_interval = true
        s.slideshow.interval_seconds = 10
        s.slideshow.interval_to_seconds = 5
        s.tools.crop.default_output_quality = 0
        s.tools.crop.aspect_values = [1, 2, 3]
        s.tools.crop.init_rect = [0]
        s.advanced.mcp.http_port = 999_999

        let errs = SettingsValidation.validate(s)
        XCTAssertFalse(errs.isEmpty)
        XCTAssertTrue(errs.contains(where: { $0.path == "edit.quality" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "gallery.thumb_size" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "viewer.cache_max_dim" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "viewer.huge_image_threshold" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "toolbar.icon_height" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "slideshow.interval_to_seconds" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "tools.crop.default_output_quality" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "tools.crop.aspect_values" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "tools.crop.init_rect" }))
        XCTAssertTrue(errs.contains(where: { $0.path == "advanced.mcp.http_port" }))
    }

    func testClampBringsInvalidValuesIntoRange() {
        var s = Settings.defaults
        s.edit.quality = 200
        s.gallery.thumb_size = 999
        s.viewer.cache_max_dim = 10
        s.viewer.zoom_lock_percent = -1
        s.toolbar.icon_height = 99
        s.slideshow.use_random_interval = true
        s.slideshow.interval_seconds = 10
        s.slideshow.interval_to_seconds = 5

        SettingsValidation.clamp(&s)

        XCTAssertEqual(s.edit.quality, 100)
        XCTAssertTrue(SettingsDefaults.galleryThumbSizes.contains(s.gallery.thumb_size))
        XCTAssertGreaterThanOrEqual(s.viewer.cache_max_dim, 256)
        XCTAssertGreaterThan(s.viewer.zoom_lock_percent, 0)
        XCTAssertTrue(SettingsDefaults.toolbarIconHeights.contains(s.toolbar.icon_height))
        XCTAssertGreaterThanOrEqual(s.slideshow.interval_to_seconds, s.slideshow.interval_seconds)
    }

    func testStoreSaveClampsBeforeWrite() async throws {
        let store = SettingsStore(paths: paths())
        var s = Settings.defaults
        s.edit.quality = 9999
        s.gallery.thumb_size = 1   // not in allowed set
        try await store.save(s)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.edit.quality, 100)
        XCTAssertTrue(SettingsDefaults.galleryThumbSizes.contains(loaded.gallery.thumb_size))
    }

    // MARK: - Reset

    func testResetSection() async throws {
        let store = SettingsStore(paths: paths())
        var s = Settings.defaults
        s.viewer.zoom_mode = .scaleToFill
        s.viewer.pan_speed = 999
        try await store.save(s)
        let reset = try await store.resetSection("viewer")
        XCTAssertEqual(reset.viewer, ViewerSettings())
    }

    func testResetAll() async throws {
        let store = SettingsStore(paths: paths())
        var s = Settings.defaults
        s.general.theme_override = .dark
        try await store.save(s)
        let reset = try await store.resetAll()
        XCTAssertEqual(reset, Settings.defaults)
    }

    func testResetUnknownSectionThrows() async throws {
        let store = SettingsStore(paths: paths())
        do {
            _ = try await store.resetSection("does_not_exist")
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    // MARK: - SettingsPath (MCP get/set by dotted key)

    func testGetByPath() throws {
        let s = Settings.defaults
        let theme = try SettingsPath.get("general.theme_override", in: s) as? String
        XCTAssertEqual(theme, "system")

        let pan = try SettingsPath.get("viewer.pan_speed", in: s) as? Double
        XCTAssertEqual(pan, 20)

        let cadence = try SettingsPath.get("general.update_cadence", in: s) as? String
        XCTAssertEqual(cadence, "weekly")
    }

    func testGetUnknownPathThrows() {
        let s = Settings.defaults
        XCTAssertThrowsError(try SettingsPath.get("nope.does.not.exist", in: s))
    }

    func testSetByPathUpdatesValue() throws {
        var s = Settings.defaults
        let prior = try SettingsPath.set("viewer.pan_speed", value: 42, in: &s)
        XCTAssertEqual(prior as? Double, 20)
        XCTAssertEqual(s.viewer.pan_speed, 42)
    }

    func testSetByPathOnEnum() throws {
        var s = Settings.defaults
        _ = try SettingsPath.set("general.theme_override", value: "dark", in: &s)
        XCTAssertEqual(s.general.theme_override, .dark)
    }

    func testSetByPathClampsOutOfRange() throws {
        var s = Settings.defaults
        _ = try SettingsPath.set("edit.quality", value: 9999, in: &s)
        XCTAssertEqual(s.edit.quality, 100)
    }

    func testListPathsCoversEverySection() {
        let pairs = SettingsPath.listPaths(Settings.defaults)
        let paths = pairs.map { $0.path }
        XCTAssertTrue(paths.contains("general.theme_override"))
        XCTAssertTrue(paths.contains("viewer.zoom_mode"))
        XCTAssertTrue(paths.contains("image.color_profile"))
        XCTAssertTrue(paths.contains("appearance.window_material"))
        XCTAssertTrue(paths.contains("slideshow.interval_seconds"))
        XCTAssertTrue(paths.contains("gallery.thumb_size"))
        XCTAssertTrue(paths.contains("toolbar.icon_height"))
        XCTAssertTrue(paths.contains("advanced.mcp.enabled"))
    }

    // MARK: - JSON shape

    func testJSONUsesSnakeCaseFileAssocKey() async throws {
        let store = SettingsStore(paths: paths())
        try await store.save(Settings.defaults)
        let raw = try String(contentsOf: paths().fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"file_assoc\""), "file_assoc must use snake_case JSON key per spec §2.3")
        XCTAssertTrue(raw.contains("\"version\""))
    }

    func testJSONIsPrettyAndSorted() async throws {
        let store = SettingsStore(paths: paths())
        try await store.save(Settings.defaults)
        let raw = try String(contentsOf: paths().fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\n"), "expected pretty-printed JSON")
        // sortedKeys → "advanced" comes before "appearance" alphabetically.
        if let a = raw.range(of: "\"advanced\""), let b = raw.range(of: "\"appearance\"") {
            XCTAssertLessThan(a.lowerBound, b.lowerBound)
        } else {
            XCTFail("expected both keys in output")
        }
    }
}
