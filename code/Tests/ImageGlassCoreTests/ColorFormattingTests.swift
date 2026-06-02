import XCTest
@testable import ImageGlassCore

final class ColorFormattingTests: XCTestCase {

    private let red    = RGBA(r: 255, g: 0,   b: 0,   a: 255)
    private let half   = RGBA(r: 128, g: 128, b: 128, a: 128)
    private let green  = RGBA(r: 0,   g: 255, b: 0,   a: 255)
    private let opaque = RGBA(r: 16,  g: 32,  b: 48,  a: 255)

    func testHex() {
        XCTAssertEqual(ColorFormatting.format(opaque, as: .hex),  "#102030")
        XCTAssertEqual(ColorFormatting.format(opaque, as: .hexA), "#102030FF")
    }

    func testRGB() {
        XCTAssertEqual(ColorFormatting.format(red, as: .rgb),  "rgb(255, 0, 0)")
        XCTAssertEqual(ColorFormatting.format(half, as: .rgba), "rgba(128, 128, 128, 0.50)")
    }

    func testHSL_red() {
        let hsl = ColorFormatting.toHSL(red)
        XCTAssertEqual(hsl.h, 0, accuracy: 0.01)
        XCTAssertEqual(hsl.s, 1.0, accuracy: 0.01)
        XCTAssertEqual(hsl.l, 0.5, accuracy: 0.01)
    }

    func testHSV_green() {
        let hsv = ColorFormatting.toHSV(green)
        XCTAssertEqual(hsv.h, 120, accuracy: 0.01)
        XCTAssertEqual(hsv.s, 1.0, accuracy: 0.01)
        XCTAssertEqual(hsv.v, 1.0, accuracy: 0.01)
    }

    func testCMYK_blackOnly() {
        let black = RGBA(r: 0, g: 0, b: 0, a: 255)
        let cmyk = ColorFormatting.toCMYK(black)
        XCTAssertEqual(cmyk.k, 1.0, accuracy: 0.001)
    }

    func testAllCasesFormatWithoutCrashing() {
        for fmt in ColorFormat.allCases {
            let s = ColorFormatting.format(half, as: fmt)
            XCTAssertFalse(s.isEmpty, "format \(fmt) produced empty string")
        }
    }
}
