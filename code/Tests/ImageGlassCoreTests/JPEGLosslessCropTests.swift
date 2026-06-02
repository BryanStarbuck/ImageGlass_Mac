import XCTest
@testable import ImageGlassCore

final class JPEGLosslessCropTests: XCTestCase {

    /// Build a synthetic JPEG header containing only the SOI + a single
    /// SOF0 marker with the given Y component sampling factors. Real
    /// JPEGs have much more in front of pixels; the MCU detector only
    /// needs the header to find the SOF.
    private func makeJPEGHeader(yH: UInt8, yV: UInt8) -> Data {
        var data = Data()
        data.append(contentsOf: [0xFF, 0xD8])           // SOI

        // SOF0 marker (baseline DCT): FF C0
        // length (2) = 8 + 3*1 = 11
        // precision (1) = 8
        // height (2) = 600
        // width (2) = 800
        // numComponents (1) = 1
        // component spec: id=1, samplingFactors=(yH << 4 | yV), qTableId=0
        let samplingFactors: UInt8 = (yH << 4) | (yV & 0x0F)
        data.append(contentsOf: [
            0xFF, 0xC0,
            0x00, 0x0B,
            0x08,
            0x02, 0x58,         // height = 600
            0x03, 0x20,         // width  = 800
            0x01,               // numComponents
            0x01, samplingFactors, 0x00, // Y component
        ])
        // Add EOI for sanity.
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    func testDetectMCU_4_4_4() {
        let data = makeJPEGHeader(yH: 1, yV: 1)
        let mcu = JPEGLosslessCrop.detectMCU(jpegData: data)
        XCTAssertNotNil(mcu)
        XCTAssertEqual(mcu?.mcuWidth, 8)
        XCTAssertEqual(mcu?.mcuHeight, 8)
        XCTAssertFalse(mcu?.chromaSubsampled ?? true)
    }

    func testDetectMCU_4_2_0() {
        let data = makeJPEGHeader(yH: 2, yV: 2)
        let mcu = JPEGLosslessCrop.detectMCU(jpegData: data)
        XCTAssertNotNil(mcu)
        XCTAssertEqual(mcu?.mcuWidth, 16)
        XCTAssertEqual(mcu?.mcuHeight, 16)
        XCTAssertTrue(mcu?.chromaSubsampled ?? false)
    }

    func testDetectMCURejectsNonJPEG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertNil(JPEGLosslessCrop.detectMCU(jpegData: png))
    }

    func testDetectMCURejectsEmpty() {
        XCTAssertNil(JPEGLosslessCrop.detectMCU(jpegData: Data()))
    }

    func testRoundToMCU_4_4_4_AlreadyAligned() {
        let mcu = JPEGLosslessCrop.MCUInfo(mcuWidth: 8, mcuHeight: 8, chromaSubsampled: false)
        let r = CropRect(x: 16, y: 16, width: 64, height: 64)
        let rounded = JPEGLosslessCrop.roundToMCU(r, mcu: mcu, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(rounded, r)
        XCTAssertTrue(JPEGLosslessCrop.isAligned(r, mcu: mcu, sourceWidth: 800, sourceHeight: 600))
    }

    func testRoundToMCU_4_2_0_GrowsOutward() {
        let mcu = JPEGLosslessCrop.MCUInfo(mcuWidth: 16, mcuHeight: 16, chromaSubsampled: true)
        let r = CropRect(x: 5, y: 7, width: 100, height: 50)
        let rounded = JPEGLosslessCrop.roundToMCU(r, mcu: mcu, sourceWidth: 800, sourceHeight: 600)
        // x: 5 → 0, y: 7 → 0, right: 105 → 112, bottom: 57 → 64.
        XCTAssertEqual(rounded.x, 0)
        XCTAssertEqual(rounded.y, 0)
        XCTAssertEqual(rounded.width, 112)
        XCTAssertEqual(rounded.height, 64)
        XCTAssertFalse(JPEGLosslessCrop.isAligned(r, mcu: mcu, sourceWidth: 800, sourceHeight: 600))
        XCTAssertTrue(JPEGLosslessCrop.isAligned(rounded, mcu: mcu, sourceWidth: 800, sourceHeight: 600))
    }

    func testRoundToMCUCapsAtSourceBounds() {
        let mcu = JPEGLosslessCrop.MCUInfo(mcuWidth: 16, mcuHeight: 16, chromaSubsampled: true)
        // Source 800×600; right edge near 800 should clamp at 800.
        let r = CropRect(x: 700, y: 500, width: 99, height: 99)
        let rounded = JPEGLosslessCrop.roundToMCU(r, mcu: mcu, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(rounded.x + rounded.width, 800)
        XCTAssertEqual(rounded.y + rounded.height, 600)
        XCTAssertTrue(JPEGLosslessCrop.isAligned(rounded, mcu: mcu, sourceWidth: 800, sourceHeight: 600))
    }
}
