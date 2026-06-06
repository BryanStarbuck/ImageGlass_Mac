import XCTest
@testable import ImageGlassCore

/// Coverage for `LocalStorage.loadScope` failure modes — specifically that
/// "file missing" surfaces as the typed `LocalStorage.Error.notFound` while
/// a present-but-malformed file still throws the underlying `DecodingError`.
/// Originating bug: `crop-live.json` (a non-Scope sidecar JSON file) sitting
/// in `scopes/` got picked up by `bootstrapIfNeeded` and produced an opaque
/// `keyNotFound("name")` decode error every launch. The fix splits the two
/// cases so `AppState.activate(scopeNamed:)` can fall back gracefully on a
/// missing file while keeping a real ERROR log for schema mismatches.
final class LocalStorageTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?
    private var storage: LocalStorage!

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-localstorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
        // Fresh instance — `shared` carries no per-test state, but a local
        // instance keeps tests obviously independent.
        storage = LocalStorage()
        try AppPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    // MARK: - Missing file → typed notFound error

    func testLoadScopeThrowsNotFoundWhenFileMissing() {
        XCTAssertFalse(storage.scopeExists("nope"))
        do {
            _ = try storage.loadScope("nope")
            XCTFail("expected LocalStorage.Error.notFound; got success")
        } catch let LocalStorage.Error.notFound(name) {
            XCTAssertEqual(name, "nope")
        } catch {
            XCTFail("expected LocalStorage.Error.notFound; got \(error)")
        }
    }

    // MARK: - Malformed file → DecodingError (NOT notFound)

    /// This is the exact on-disk shape that produced the original
    /// `crop-live.json` regression: a JSON object with no `name` key and an
    /// otherwise alien schema. Loading it must NOT collapse into
    /// `notFound` — the caller needs the underlying `DecodingError` so the
    /// ERROR log captures the schema mismatch.
    func testLoadScopeThrowsDecodingErrorOnSchemaMismatch() throws {
        let url = storage.scopeURL(for: "crop-live")
        let payload = """
        {
          "apply": false,
          "imagePath": "/tmp/x.png",
          "selection": { "height": 100, "width": 100, "x": 0, "y": 0 }
        }
        """
        try Data(payload.utf8).write(to: url, options: .atomic)
        XCTAssertTrue(storage.scopeExists("crop-live"))

        do {
            _ = try storage.loadScope("crop-live")
            XCTFail("expected DecodingError; got success")
        } catch is LocalStorage.Error {
            XCTFail("malformed file must not surface as LocalStorage.Error.notFound")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("expected DecodingError; got \(error)")
        }
    }

    // MARK: - Well-formed file → round-trips

    func testLoadScopeRoundTripsWellFormedFile() throws {
        let original = Scope(
            name: "writing",
            description: "Test scope",
            include: .init(directories: ["~/Pictures"], recursive: true, extensions: ["png"])
        )
        try storage.saveScope(original)

        let loaded = try storage.loadScope("writing")
        XCTAssertEqual(loaded.name, "writing")
        XCTAssertEqual(loaded.description, "Test scope")
        XCTAssertEqual(loaded.include.directories, ["~/Pictures"])
        XCTAssertEqual(loaded.include.extensions, ["png"])
    }

    // MARK: - listScopes filters sidecar files

    func testListScopesSkipsReservedSidecars() throws {
        // Drop the historical sidecar files that caused the original bug
        // alongside a real scope. Only the real one should be listed.
        let cropLiveURL = storage.scopeURL(for: "crop-live")
        try Data("{\"apply\":false}".utf8).write(to: cropLiveURL, options: .atomic)
        let cropURL = storage.scopeURL(for: "crop")
        try Data("{\"jpeg\":{}}".utf8).write(to: cropURL, options: .atomic)
        try storage.saveScope(Scope(name: "real", include: .init(directories: ["~/Pictures"])))

        let listed = try storage.listScopes()
        XCTAssertEqual(listed, ["real"])
    }
}
