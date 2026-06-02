import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageGlassCore

final class CropMCPToolsTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-cropmcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", dir.path, 1)
        tmpHome = dir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    private func makePNG(width: Int, height: Int, name: String) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CropPipelineError.invalidRectangle("ctx")
        }
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { throw CropPipelineError.invalidRectangle("cg") }
        let url = tmpHome.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CropPipelineError.destinationFailure("dest")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) { throw CropPipelineError.destinationFailure("finalize") }
        return url
    }

    // MARK: - Tools surface

    func testCropToolsAreRegisteredAtTopLevel() {
        let tools = MCPTools()
        let names = tools.descriptors().map(\.name)
        XCTAssertTrue(names.contains("crop_image"))
        XCTAssertTrue(names.contains("get_crop_selection"))
        XCTAssertTrue(names.contains("set_crop_selection"))
        XCTAssertTrue(names.contains("read_image_dimensions"))
    }

    func testReadImageDimensionsTool() throws {
        let url = try makePNG(width: 320, height: 240, name: "dims.png")
        let tools = MCPTools()
        let result = try tools.call(name: "read_image_dimensions", arguments: [
            "input_path": url.path as Any?,
        ])
        XCTAssertFalse(result.isError ?? false)
        let text = result.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"width\""))
        XCTAssertTrue(text.contains("320"))
        XCTAssertTrue(text.contains("240"))
    }

    func testCropImageTool() throws {
        let input = try makePNG(width: 200, height: 200, name: "crop-in.png")
        let output = tmpHome.appendingPathComponent("crop-out.png")
        let tools = MCPTools()
        let result = try tools.call(name: "crop_image", arguments: [
            "input_path": input.path as Any?,
            "output_path": output.path as Any?,
            "x": 25 as Any?,
            "y": 25 as Any?,
            "width": 100 as Any?,
            "height": 100 as Any?,
        ])
        XCTAssertFalse(result.isError ?? false)
        let dim = try CropPipeline.readDimensions(of: output.path)
        XCTAssertEqual(dim.width, 100)
        XCTAssertEqual(dim.height, 100)
    }

    func testCropImageToolRejectsOutOfBounds() throws {
        let input = try makePNG(width: 50, height: 50, name: "tiny.png")
        let tools = MCPTools()
        let result = try tools.call(name: "crop_image", arguments: [
            "input_path": input.path as Any?,
            "x": 0 as Any?,
            "y": 0 as Any?,
            "width": 200 as Any?,
            "height": 200 as Any?,
        ])
        XCTAssertTrue(result.isError ?? false)
        XCTAssertTrue(result.content.first?.text.contains("outside source bounds") ?? false)
    }

    func testSetAndGetCropSelectionRoundTrip() throws {
        // Seed a synthetic live state with known dimensions so the clamp logic
        // exercises a real bound.
        let live = LiveCropSelection(
            imagePath: "/tmp/example.jpg",
            sourceWidth: 1000,
            sourceHeight: 800,
            selection: nil,
            aspectRatio: "free",
            apply: false,
            updatedAt: Date()
        )
        try LiveCropSelection.save(live)

        let tools = MCPTools()
        let setResult = try tools.call(name: "set_crop_selection", arguments: [
            "x": 100 as Any?,
            "y": 50 as Any?,
            "width": 500 as Any?,
            "height": 400 as Any?,
            "apply": true as Any?,
        ])
        XCTAssertFalse(setResult.isError ?? false)
        XCTAssertTrue(setResult.content.first?.text.contains("\"applied\" : true") ?? false)

        let getResult = try tools.call(name: "get_crop_selection", arguments: [:])
        XCTAssertFalse(getResult.isError ?? false)
        let text = getResult.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"width\" : 500"))
        XCTAssertTrue(text.contains("\"height\" : 400"))
        XCTAssertTrue(text.contains("\"source_width\" : 1000"))
    }

    func testSetCropSelectionClampsToImageBounds() throws {
        let live = LiveCropSelection(
            imagePath: "/tmp/x.png",
            sourceWidth: 100,
            sourceHeight: 100,
            selection: nil,
            aspectRatio: "free",
            apply: false,
            updatedAt: Date()
        )
        try LiveCropSelection.save(live)

        let tools = MCPTools()
        let res = try tools.call(name: "set_crop_selection", arguments: [
            "x": 0 as Any?,
            "y": 0 as Any?,
            "width": 500 as Any?,
            "height": 500 as Any?,
        ])
        XCTAssertFalse(res.isError ?? false)
        // The set call should have written a clamped rect back.
        let stored = LiveCropSelection.load()
        XCTAssertEqual(stored?.selection?.width, 100)
        XCTAssertEqual(stored?.selection?.height, 100)
    }

    func testGetCropSelectionReturnsNullWhenAbsent() throws {
        // No prior LiveCropSelection on disk.
        let tools = MCPTools()
        let res = try tools.call(name: "get_crop_selection", arguments: [:])
        XCTAssertFalse(res.isError ?? false)
        let text = res.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"selection\" : null") || text.contains("\"selection\":null"))
    }
}
