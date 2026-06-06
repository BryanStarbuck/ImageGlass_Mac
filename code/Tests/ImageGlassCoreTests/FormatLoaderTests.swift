import XCTest
@testable import ImageGlassCore

final class FormatLoaderTests: XCTestCase {

    /// 1x1 transparent PNG, base64-encoded.
    /// Decoding round-trips through Image I/O.
    static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    /// Same payload wrapped in a Data URI prefix, exercising the parser.
    static let onePixelPNGDataURI =
        "data:image/png;base64," + FormatLoaderTests.onePixelPNGBase64

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Sniffing

    func testSniffPNG() {
        let data = Data(base64Encoded: Self.onePixelPNGBase64)!
        XCTAssertEqual(FormatLoader.sniffExtension(from: data), "png")
    }

    func testSniffJPEG() {
        // FF D8 FF E0 ...
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        XCTAssertEqual(FormatLoader.sniffExtension(from: Data(bytes)), "jpg")
    }

    func testSniffBMP() {
        let bytes: [UInt8] = [0x42, 0x4D, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(FormatLoader.sniffExtension(from: Data(bytes)), "bmp")
    }

    func testSniffGIF() {
        let bytes: [UInt8] = Array("GIF89a".utf8)
        XCTAssertEqual(FormatLoader.sniffExtension(from: Data(bytes)), "gif")
    }

    func testSniffSVG() {
        let svg = "<?xml version=\"1.0\"?><svg xmlns=\"...\"></svg>"
        XCTAssertEqual(FormatLoader.sniffExtension(from: Data(svg.utf8)), "svg")
    }

    func testSniffUnknown() {
        XCTAssertNil(FormatLoader.sniffExtension(from: Data([0x00, 0x01, 0x02, 0x03])))
    }

    // MARK: - Load round-trip

    func testLoadPNGFromData() throws {
        let data = Data(base64Encoded: Self.onePixelPNGBase64)!
        let loaded = try FormatLoader.load(data: data)
        XCTAssertEqual(loaded.pixelWidth, 1)
        XCTAssertEqual(loaded.pixelHeight, 1)
        XCTAssertEqual(loaded.format?.id, "png")
        XCTAssertGreaterThanOrEqual(loaded.frameCount, 1)
    }

    func testLoadPNGFromURL() throws {
        let url = tmpDir.appendingPathComponent("tiny.png")
        try Data(base64Encoded: Self.onePixelPNGBase64)!.write(to: url)
        let loaded = try FormatLoader.load(url: url)
        XCTAssertEqual(loaded.pixelWidth, 1)
        XCTAssertEqual(loaded.format?.id, "png")
        XCTAssertEqual(loaded.sourceURL, url)
    }

    func testLoadMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try FormatLoader.load(url: url)) { err in
            guard case FormatLoaderError.fileNotFound = err else {
                XCTFail("expected fileNotFound, got \(err)")
                return
            }
        }
    }

    func testLoadEmptyData() {
        XCTAssertThrowsError(try FormatLoader.load(data: Data())) { err in
            guard case FormatLoaderError.emptyData = err else {
                XCTFail("expected emptyData, got \(err)")
                return
            }
        }
    }

    // MARK: - Cache + downsample

    func testCacheHitOnRepeatLoad() throws {
        FormatLoader.clearCache()
        let url = tmpDir.appendingPathComponent("cached.png")
        try Data(base64Encoded: Self.onePixelPNGBase64)!.write(to: url)
        let first = try FormatLoader.load(url: url)
        let second = try FormatLoader.load(url: url)
        // Same CGImage instance proves cache hit (we did not re-decode).
        XCTAssertTrue(first.cgImage === second.cgImage)
    }

    func testCacheInvalidatedByMtimeChange() throws {
        FormatLoader.clearCache()
        let url = tmpDir.appendingPathComponent("mutating.png")
        try Data(base64Encoded: Self.onePixelPNGBase64)!.write(to: url)
        let first = try FormatLoader.load(url: url)
        // Rewrite with an explicitly later mtime so the cache key changes.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: url.path
        )
        let second = try FormatLoader.load(url: url)
        XCTAssertFalse(first.cgImage === second.cgImage)
    }

    func testFullResAndDownsampleAreSeparateCacheEntries() throws {
        FormatLoader.clearCache()
        let url = tmpDir.appendingPathComponent("two-keys.png")
        try Data(base64Encoded: Self.onePixelPNGBase64)!.write(to: url)
        let fullRes = try FormatLoader.load(url: url, targetMaxDim: 0)
        let thumb = try FormatLoader.load(url: url, targetMaxDim: 64)
        // Distinct cache entries means distinct CGImage instances.
        XCTAssertFalse(fullRes.cgImage === thumb.cgImage)
        // Both should still report the source url and a valid pixel size.
        XCTAssertEqual(fullRes.sourceURL, url)
        XCTAssertEqual(thumb.sourceURL, url)
        XCTAssertGreaterThan(thumb.pixelWidth, 0)
    }

    func testLoadAsyncReturnsImage() async throws {
        FormatLoader.clearCache()
        let url = tmpDir.appendingPathComponent("async.png")
        try Data(base64Encoded: Self.onePixelPNGBase64)!.write(to: url)
        let loaded = try await FormatLoader.loadAsync(url: url)
        XCTAssertEqual(loaded.pixelWidth, 1)
        XCTAssertEqual(loaded.sourceURL, url)
    }

    func testLoadFakeBPGReportsExternalDelegate() throws {
        // BPG remains spec-marked as needing external tools (see
        // docs/supported-formats.mdx optional-dependencies table). Image I/O
        // can't decode BPG, so the loader should report the delegate error
        // rather than a generic decode failure.
        let url = tmpDir.appendingPathComponent("fake.bpg")
        try Data([0x42, 0x50, 0x47, 0xFB, 0x00, 0x00]).write(to: url)
        XCTAssertThrowsError(try FormatLoader.load(url: url)) { err in
            guard case FormatLoaderError.requiresExternalDelegate = err else {
                XCTFail("expected requiresExternalDelegate, got \(err)")
                return
            }
        }
    }
}
