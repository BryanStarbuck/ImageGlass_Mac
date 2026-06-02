import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageGlassCore

final class CropPipelineTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-crop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", dir.path, 1)
        tmpHome = dir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    // MARK: - Helpers

    /// Build a synthetic PNG file with a known fill color and dimensions.
    private func makePNG(width: Int, height: Int, name: String = "test.png") throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpc = 8
        let bpr = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bpc,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("Failed to create CGContext")
            throw CropPipelineError.invalidRectangle("ctx")
        }
        // Fill with red.
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else {
            throw CropPipelineError.invalidRectangle("image")
        }
        let url = tmpHome.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CropPipelineError.destinationFailure("png dest")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) {
            throw CropPipelineError.destinationFailure("png finalize")
        }
        return url
    }

    // MARK: - Tests

    func testReadDimensions() throws {
        let url = try makePNG(width: 400, height: 300)
        let dim = try CropPipeline.readDimensions(of: url.path)
        XCTAssertEqual(dim.width, 400)
        XCTAssertEqual(dim.height, 300)
    }

    func testCropFileWritesOutputWithExpectedSize() throws {
        let input = try makePNG(width: 400, height: 300)
        let output = tmpHome.appendingPathComponent("out.png")
        let result = try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 50, y: 60, width: 200, height: 150),
            outputPath: output.path
        )
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 150)
        XCTAssertEqual(result.format, .png)
        XCTAssertGreaterThan(result.bytesWritten, 0)

        // Verify the output file actually exists and is the right pixel size.
        let dim = try CropPipeline.readDimensions(of: output.path)
        XCTAssertEqual(dim.width, 200)
        XCTAssertEqual(dim.height, 150)
    }

    func testCropFileRejectsOutOfBoundsRectangle() throws {
        let input = try makePNG(width: 100, height: 100)
        XCTAssertThrowsError(try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 50, y: 50, width: 200, height: 200)
        )) { error in
            if case CropPipelineError.rectOutOfBounds = error { /* OK */ } else {
                XCTFail("Expected rectOutOfBounds; got \(error)")
            }
        }
    }

    func testCropFileRejectsInvalidRectangle() throws {
        let input = try makePNG(width: 100, height: 100)
        XCTAssertThrowsError(try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 0, y: 0, width: 0, height: 10)
        )) { error in
            if case CropPipelineError.invalidRectangle = error { /* OK */ } else {
                XCTFail("Expected invalidRectangle; got \(error)")
            }
        }
    }

    func testCropFileRefusesOverwriteOfDifferentPath() throws {
        let input = try makePNG(width: 100, height: 100, name: "src.png")
        let dest = try makePNG(width: 100, height: 100, name: "dst.png")
        XCTAssertThrowsError(try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 0, y: 0, width: 50, height: 50),
            outputPath: dest.path,
            options: CropOptions(overwrite: false)
        )) { error in
            if case CropPipelineError.overwriteRefused = error { /* OK */ } else {
                XCTFail("Expected overwriteRefused; got \(error)")
            }
        }
    }

    func testCropFileOverwritesWhenAsked() throws {
        let input = try makePNG(width: 100, height: 100, name: "src.png")
        let dest = try makePNG(width: 100, height: 100, name: "dst.png")
        let result = try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 0, y: 0, width: 50, height: 50),
            outputPath: dest.path,
            options: CropOptions(overwrite: true)
        )
        XCTAssertEqual(result.width, 50)
    }

    func testCropFileOverwritesInputByDefault() throws {
        let input = try makePNG(width: 200, height: 200)
        let result = try CropPipeline.cropFile(
            inputPath: input.path,
            rect: CropRect(x: 20, y: 20, width: 100, height: 100)
        )
        XCTAssertEqual(result.outputPath, input.path)
        let dim = try CropPipeline.readDimensions(of: input.path)
        XCTAssertEqual(dim.width, 100)
        XCTAssertEqual(dim.height, 100)
    }

    func testOutputFormatFromExtension() {
        XCTAssertEqual(OutputFormat.fromExtension("jpg"), .jpeg)
        XCTAssertEqual(OutputFormat.fromExtension("PNG"), .png)
        XCTAssertEqual(OutputFormat.fromExtension("heic"), .heic)
        XCTAssertNil(OutputFormat.fromExtension("xyz"))
    }
}
