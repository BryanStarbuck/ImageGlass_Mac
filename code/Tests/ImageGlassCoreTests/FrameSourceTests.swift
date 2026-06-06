import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageGlassCore

final class FrameSourceTests: XCTestCase {

    func testStillImage_singleFrame_notAnimated() throws {
        let url = try writeStillPNG()
        let fs = try XCTUnwrap(FrameSource.load(url: url))
        XCTAssertEqual(fs.frameCount, 1)
        XCTAssertFalse(fs.isAnimated)
        XCTAssertFalse(fs.isMultiFrame)
    }

    func testNonexistent_returnsNil() {
        let url = URL(fileURLWithPath: "/nope/does/not/exist.png")
        XCTAssertNil(FrameSource.load(url: url))
    }

    /// Regression: provenance-tagged JPEGs (the JFK_Mar_c_files/img_*.jpg
    /// case in error.err) produced a URL-based CGImageSource whose
    /// `CGImageSourceGetCount` returned 0 even though the bytes on disk
    /// were a valid progressive JPEG. The Data fallback should take over
    /// and produce a frame so the viewer doesn't show cyan-without-image.
    /// We can't perfectly reproduce the URL-side failure mode in a unit
    /// test (it's specific to ImageIO's lazy-open behavior on certain
    /// macOS file-system attributes), but we *can* assert that progressive
    /// JPEGs themselves still load through both pipelines.
    func testProgressiveJPEG_loadsViaPrimaryOrFallback() throws {
        let url = try writeProgressiveJPEG()
        let fs = try XCTUnwrap(FrameSource.load(url: url), "progressive JPEG must load")
        XCTAssertEqual(fs.frameCount, 1)
        XCTAssertFalse(fs.isAnimated)
        // Frame 0 should yield a non-zero CGImage on dereference (lazy
        // decode actually runs).
        let cg = fs.frames[0].cgImage
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    /// Empty file → both URL and Data paths refuse it. The previous
    /// behavior was a single log line from the URL path; the new fallback
    /// path adds a second line. Either way, the public contract is "load
    /// returns nil".
    func testEmptyFile_returnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("framesource-empty-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(), attributes: nil)
        XCTAssertNil(FrameSource.load(url: tmp))
    }

    // MARK: - Helpers

    private func writeStillPNG() throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 16,
            space: cs, bitmapInfo: info
        ) else { throw XCTSkip("CGContext unavailable") }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let img = try XCTUnwrap(ctx.makeImage())

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("framesource-test-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return tmp
    }

    /// Build and write a progressive JPEG to disk. CGImageDestination's
    /// progressive option is exposed via the `kCGImagePropertyJFIFIsProgressive`
    /// frame-properties key (mirrors the JFIF header bit set by libjpeg).
    private func writeProgressiveJPEG() throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: cs, bitmapInfo: info
        ) else { throw XCTSkip("CGContext unavailable") }
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let img = try XCTUnwrap(ctx.makeImage())

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("framesource-progressive-\(UUID().uuidString).jpg")
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let frameProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            // The JFIF dictionary key for progressive encoding.
            kCGImagePropertyJFIFDictionary: [
                kCGImagePropertyJFIFIsProgressive: true,
            ],
        ]
        CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return tmp
    }
}
