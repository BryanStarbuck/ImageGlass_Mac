import XCTest
@testable import ImageGlassCore

final class InitialConfigSeederTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-seed-test-\(UUID().uuidString)", isDirectory: true)
        // Don't pre-create — the seeder must handle a missing directory.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSeedsBothFilesWhenMissing() throws {
        let written = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        XCTAssertEqual(written.count, 2)
        let settingsURL = tempDir.appendingPathComponent("settings.yaml")
        let panelsURL = tempDir.appendingPathComponent("panels.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: panelsURL.path))
    }

    func testIdempotentSecondRun() throws {
        _ = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        let settingsURL = tempDir.appendingPathComponent("settings.yaml")
        let originalMTime = try FileManager.default
            .attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date
        XCTAssertNotNil(originalMTime)

        // Re-run; nothing should be written.
        let secondRun = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        XCTAssertEqual(secondRun.count, 0)

        let newMTime = try FileManager.default
            .attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date
        XCTAssertEqual(originalMTime, newMTime)
    }

    func testPreservesExistingFiles() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settingsURL = tempDir.appendingPathComponent("settings.yaml")
        let sentinel = "# user-edited\nkeep_this: true\n"
        try sentinel.write(to: settingsURL, atomically: true, encoding: .utf8)

        let written = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        // Only panels.yaml should be newly written.
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.lastPathComponent, "panels.yaml")

        let after = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertEqual(after, sentinel)
    }

    func testSettingsYAMLContainsKnownSections() throws {
        _ = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        let settingsURL = tempDir.appendingPathComponent("settings.yaml")
        let body = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(body.contains("# ImageGlass_Mac"))
        // Top-level section keys (unquoted, with trailing colon).
        for section in ["general:", "image:", "viewer:", "appearance:",
                        "layout:", "slideshow:", "edit:", "mouse:",
                        "keyboard:", "gallery:", "toolbar:",
                        "language:", "tools:", "plugins:", "advanced:"] {
            XCTAssertTrue(
                body.contains(section),
                "settings.yaml missing expected section: \(section)"
            )
        }
        // A few defaulted scalar values from §4.1.
        XCTAssertTrue(body.contains("theme_override: system"))
        XCTAssertTrue(body.contains("multi_instance: true"))
    }

    func testPanelsYAMLContainsKnownPanels() throws {
        _ = InitialConfigSeeder.seedIfMissing(directory: tempDir)
        let panelsURL = tempDir.appendingPathComponent("panels.yaml")
        let body = try String(contentsOf: panelsURL, encoding: .utf8)

        XCTAssertTrue(body.contains("schema_version:"))
        XCTAssertTrue(body.contains("active_preset:"))
        XCTAssertTrue(body.contains("- id: file_panel"))
        XCTAssertTrue(body.contains("- id: toolbar"))
    }
}
