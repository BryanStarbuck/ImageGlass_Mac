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
}
