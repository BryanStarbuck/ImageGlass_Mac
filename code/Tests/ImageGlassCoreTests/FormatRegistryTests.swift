import XCTest
@testable import ImageGlassCore

final class FormatRegistryTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-home-fmt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", dir.path, 1)
        tmpHome = dir
        FormatRegistry.shared.reload()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
        FormatRegistry.shared.reload()
    }

    // MARK: - Builtin lookups

    func testJPEGLookupByExtension() {
        let r = FormatRegistry.shared
        XCTAssertEqual(r.format(forExtension: "jpg")?.id, "jpeg")
        XCTAssertEqual(r.format(forExtension: ".JPG")?.id, "jpeg")
        XCTAssertEqual(r.format(forExtension: "jpeg")?.id, "jpeg")
        XCTAssertEqual(r.format(forExtension: "jfif")?.id, "jpeg")
        XCTAssertTrue(r.format(forExtension: "jpg")?.canRead == true)
        XCTAssertTrue(r.format(forExtension: "jpg")?.canWrite == true)
    }

    func testPNGCapabilities() {
        let f = FormatRegistry.shared.format(forExtension: "png")
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.canRead)
        XCTAssertTrue(f!.canWrite)
        XCTAssertTrue(f!.capabilities.contains(.alpha))
        XCTAssertTrue(f!.isAnimated) // APNG
    }

    func testSVGIsVector() {
        let f = FormatRegistry.shared.format(forExtension: "svg")
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.isVector)
    }

    func testUnknownExtension() {
        XCTAssertNil(FormatRegistry.shared.format(forExtension: "xyz_unknown"))
    }

    func testRAWExtensionsAreRegistered() {
        let r = FormatRegistry.shared
        for ext in ["arw", "cr2", "dng", "nef", "orf"] {
            XCTAssertEqual(r.format(forExtension: ext)?.id, "raw", "RAW should cover .\(ext)")
        }
    }

    func testJXLAndAVIFAreNativeOnMacOS14() {
        // Spec lists JXL and AVIF under "Modern raster" with no external
        // dependency. Image I/O reads JXL on macOS 14+ and AVIF on macOS 13+.
        XCTAssertEqual(FormatRegistry.shared.format(forExtension: "jxl")?.needsExternalDelegate, false)
        XCTAssertEqual(FormatRegistry.shared.format(forExtension: "avif")?.needsExternalDelegate, false)
    }

    func testDefaultScopeExtensionsExcludeDelegatesAndAreNonEmpty() {
        let exts = FormatRegistry.shared.defaultScopeExtensions()
        XCTAssertFalse(exts.isEmpty)
        // None of the delegate-only ones should appear.
        for bad in ["ai", "eps", "psd", "qoi", "fits", "hdr", "exr", "bpg"] {
            XCTAssertFalse(exts.contains(bad), "Default scope must not contain delegate-only ext .\(bad)")
        }
        // Sanity: classic raster formats present.
        for good in ["jpg", "png", "gif", "tiff", "webp", "heic", "bmp", "jxl", "avif"] {
            XCTAssertTrue(exts.contains(good), "Default scope missing .\(good)")
        }
    }

    func testAllExtensionsDeduped() {
        let exts = FormatRegistry.shared.allExtensions()
        XCTAssertEqual(exts.count, Set(exts).count)
    }

    // MARK: - User extras persistence

    func testAddUserExtensionPersists() throws {
        _ = try FormatRegistry.shared.addUserExtension(".myimg", mappedTo: "png")
        XCTAssertNotNil(FormatRegistry.shared.format(forExtension: "myimg"))

        // Reload to prove it round-trips via formats.json.
        FormatRegistry.shared.reload()
        XCTAssertNotNil(FormatRegistry.shared.format(forExtension: "myimg"))
    }

    func testRemoveUserExtension() throws {
        _ = try FormatRegistry.shared.addUserExtension("tmpfmt")
        XCTAssertNotNil(FormatRegistry.shared.format(forExtension: "tmpfmt"))
        try FormatRegistry.shared.removeUserExtension("tmpfmt")
        FormatRegistry.shared.reload()
        XCTAssertNil(FormatRegistry.shared.format(forExtension: "tmpfmt"))
    }

    func testAddInvalidExtensionThrows() {
        XCTAssertThrowsError(try FormatRegistry.shared.addUserExtension("   "))
    }
}
