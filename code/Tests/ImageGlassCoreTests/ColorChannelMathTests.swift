import XCTest
@testable import ImageGlassCore

final class ColorChannelMathTests: XCTestCase {

    private let mixed = RGBA(r: 200, g: 120, b: 40, a: 180)

    func testAll_passesThrough() {
        XCTAssertEqual(ColorChannelMath.apply(.all, to: mixed), mixed)
    }

    func testRed_isolatesRed() {
        let out = ColorChannelMath.apply(.red, to: mixed)
        XCTAssertEqual(out, RGBA(r: 200, g: 0, b: 0, a: 180))
    }

    func testGreen_isolatesGreen() {
        let out = ColorChannelMath.apply(.green, to: mixed)
        XCTAssertEqual(out, RGBA(r: 0, g: 120, b: 0, a: 180))
    }

    func testBlue_isolatesBlue() {
        let out = ColorChannelMath.apply(.blue, to: mixed)
        XCTAssertEqual(out, RGBA(r: 0, g: 0, b: 40, a: 180))
    }

    func testAlpha_rendersAsOpaqueGray() {
        let out = ColorChannelMath.apply(.alpha, to: mixed)
        XCTAssertEqual(out, RGBA(r: 180, g: 180, b: 180, a: 255))
    }

    func testAlpha_zeroAlpha() {
        let opaqueGrayZero = ColorChannelMath.apply(
            .alpha,
            to: RGBA(r: 255, g: 255, b: 255, a: 0)
        )
        XCTAssertEqual(opaqueGrayZero, RGBA(r: 0, g: 0, b: 0, a: 255))
    }

    // The CI matrix returns vectors whose dot-product with (R,G,B,A) gives
    // the corresponding output channel. Verify the matrix matches `apply`.
    func testCIColorMatrix_matchesApply() {
        let cases: [(ColorChannel, RGBA)] = [
            (.all,   RGBA(r: 10,  g: 20,  b: 30,  a: 200)),
            (.red,   RGBA(r: 200, g: 50,  b: 50,  a: 255)),
            (.green, RGBA(r: 50,  g: 200, b: 50,  a: 255)),
            (.blue,  RGBA(r: 50,  g: 50,  b: 200, a: 255)),
            (.alpha, RGBA(r: 99,  g: 88,  b: 77,  a: 128)),
        ]
        for (ch, pixel) in cases {
            let m = ColorChannelMath.ciColorMatrix(ch)
            let r = clampedByte(dot(m.rVec, pixel) + m.bias.0 * 255)
            let g = clampedByte(dot(m.gVec, pixel) + m.bias.1 * 255)
            let b = clampedByte(dot(m.bVec, pixel) + m.bias.2 * 255)
            let a = clampedByte(dot(m.aVec, pixel) + m.bias.3 * 255)
            let expected = ColorChannelMath.apply(ch, to: pixel)
            XCTAssertEqual(RGBA(r: r, g: g, b: b, a: a), expected,
                           "channel \(ch) mismatch on pixel \(pixel)")
        }
    }

    private func dot(_ v: (CGFloat, CGFloat, CGFloat, CGFloat), _ p: RGBA) -> CGFloat {
        v.0 * CGFloat(p.r) + v.1 * CGFloat(p.g) + v.2 * CGFloat(p.b) + v.3 * CGFloat(p.a)
    }

    private func clampedByte(_ v: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, Int(v.rounded()))))
    }
}
