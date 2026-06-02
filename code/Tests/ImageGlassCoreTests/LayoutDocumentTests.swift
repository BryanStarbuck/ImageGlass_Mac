import XCTest
@testable import ImageGlassCore

final class LayoutDocumentTests: XCTestCase {

    private var tmpDir: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let h = originalHome {
            setenv("HOME", h, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Defaults

    func testInitialDocumentHoldsBuiltInPresets() {
        let doc = LayoutDocument.initial
        XCTAssertEqual(doc.version, LayoutDocument.currentVersion)
        XCTAssertEqual(doc.activePresetId, "browser")
        XCTAssertEqual(doc.presets.count, 5)
        XCTAssertEqual(doc.presets.map(\.id),
            ["viewer_only", "browser", "photographer", "power_user", "slideshow"])
    }

    func testActivePresetLookup() {
        let doc = LayoutDocument.initial
        XCTAssertEqual(doc.activePreset.id, "browser")
    }

    func testPresetLookupByIdAndByName() {
        let doc = LayoutDocument.initial
        XCTAssertEqual(doc.preset(named: "power_user")?.id, "power_user")
        XCTAssertEqual(doc.preset(named: "Power user")?.id, "power_user")
        XCTAssertNil(doc.preset(named: "no_such_preset"))
    }

    // MARK: - Serialization round-trip

    func testRoundTrip() throws {
        let doc = LayoutDocument.initial
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(LayoutDocument.self, from: data)
        XCTAssertEqual(round.version, doc.version)
        XCTAssertEqual(round.activePresetId, doc.activePresetId)
        XCTAssertEqual(round.presets.count, doc.presets.count)
        XCTAssertEqual(round.presets.map(\.id), doc.presets.map(\.id))
    }

    func testUnknownFieldsPreserved() throws {
        // Inject an unknown field through raw JSON, decode, encode, verify it
        // round-trips. This is the forward-compat guarantee from spec §3.4.
        let raw = """
        {
          "version": 1,
          "activePresetId": "browser",
          "presets": [],
          "userPresets": [],
          "tabGroups": [],
          "futureFeatureX": { "enabled": true, "count": 7 }
        }
        """
        let decoder = JSONDecoder()
        let doc = try decoder.decode(LayoutDocument.self, from: Data(raw.utf8))
        XCTAssertNotNil(doc.unknownFields["futureFeatureX"])

        let encoder = JSONEncoder()
        let reencoded = try encoder.encode(doc)
        let json = String(data: reencoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("futureFeatureX"),
            "unknown field 'futureFeatureX' must survive a round-trip")
    }

    func testFallbacksOnMissingFields() throws {
        let raw = "{}"
        let decoder = JSONDecoder()
        let doc = try decoder.decode(LayoutDocument.self, from: Data(raw.utf8))
        XCTAssertEqual(doc.version, LayoutDocument.currentVersion)
        XCTAssertEqual(doc.activePresetId, "browser")
        XCTAssertFalse(doc.presets.isEmpty)
    }

    // MARK: - LayoutStore

    func testStoreReadWriteRoundTrip() throws {
        let store = LayoutStore()
        // Should return defaults when the file does not exist.
        let initial = try store.load()
        XCTAssertEqual(initial.activePresetId, "browser")

        var doc = initial
        doc.activePresetId = "photographer"
        doc.userPresets = [LayoutPreset(
            id: "my_preset",
            name: "My Preset",
            builtin: false,
            windows: [LayoutWindow(id: "main")]
        )]
        try store.save(doc)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.activePresetId, "photographer")
        XCTAssertEqual(reloaded.userPresets.count, 1)
        XCTAssertEqual(reloaded.userPresets.first?.id, "my_preset")
        XCTAssertNotNil(reloaded.lastSavedAt)
    }

    func testStoreUpdateHelper() throws {
        let store = LayoutStore()
        _ = try store.update { doc in
            doc.activePresetId = "power_user"
        }
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.activePresetId, "power_user")
    }
}
