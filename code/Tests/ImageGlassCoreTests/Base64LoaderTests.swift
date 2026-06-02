import XCTest
@testable import ImageGlassCore

final class Base64LoaderTests: XCTestCase {

    func testExtractBarePayload() {
        let result = Base64Loader.extractBase64Payload(from: "  abc==  ")
        XCTAssertEqual(result, "abc==")
    }

    func testExtractStripsDataURIPrefix() {
        let result = Base64Loader.extractBase64Payload(from: "data:image/png;base64,iVBOR")
        XCTAssertEqual(result, "iVBOR")
    }

    func testExtractStripsInternalWhitespace() {
        let messy = "iVBO\nR\r\nw0K\tGgo"
        let result = Base64Loader.extractBase64Payload(from: messy)
        XCTAssertEqual(result, "iVBORw0KGgo")
    }

    func testEmptyTextReturnsNil() {
        XCTAssertNil(Base64Loader.extractBase64Payload(from: "   \n  "))
    }

    // MARK: - Decode round-trip

    func testDecodePNGFromBareBase64() throws {
        let loaded = try Base64Loader.loadFromBase64(text: FormatLoaderTests.onePixelPNGBase64)
        XCTAssertEqual(loaded.pixelWidth, 1)
        XCTAssertEqual(loaded.pixelHeight, 1)
        XCTAssertEqual(loaded.format?.id, "png")
    }

    func testDecodePNGFromDataURI() throws {
        let loaded = try Base64Loader.loadFromBase64(text: FormatLoaderTests.onePixelPNGDataURI)
        XCTAssertEqual(loaded.pixelWidth, 1)
        XCTAssertEqual(loaded.format?.id, "png")
    }

    func testDecodeInvalidThrows() {
        XCTAssertThrowsError(try Base64Loader.loadFromBase64(text: "not base64 !!"))
    }

    func testDecodeFromFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-b64-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("img.txt")
        try FormatLoaderTests.onePixelPNGBase64.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try Base64Loader.loadFromBase64File(url: file)
        XCTAssertEqual(loaded.pixelWidth, 1)
    }
}
