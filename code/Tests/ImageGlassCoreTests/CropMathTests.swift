import XCTest
import CoreGraphics
@testable import ImageGlassCore

final class CropMathTests: XCTestCase {

    // MARK: - Initial rect

    func testInitialRect_selectAll_returnsImageBounds() {
        let size = CGSize(width: 1000, height: 800)
        let r = CropMath.initialRect(for: .selectAll, imageSize: size)
        XCTAssertEqual(r, CGRect(origin: .zero, size: size))
    }

    func testInitialRect_selectNone_returnsNil() {
        XCTAssertNil(CropMath.initialRect(for: .selectNone, imageSize: CGSize(width: 100, height: 100)))
    }

    func testInitialRect_select50Percent_centered() {
        let r = CropMath.initialRect(for: .select50Percent, imageSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(r, CGRect(x: 250, y: 200, width: 500, height: 400))
    }

    func testInitialRect_selectOneThird_centered() {
        let r = CropMath.initialRect(for: .selectOneThird, imageSize: CGSize(width: 900, height: 600))!
        XCTAssertEqual(r.width, 300, accuracy: 1)
        XCTAssertEqual(r.height, 200, accuracy: 1)
        XCTAssertEqual(r.midX, 450, accuracy: 1)
        XCTAssertEqual(r.midY, 300, accuracy: 1)
    }

    // MARK: - Clip & snap

    func testClip_pushesNegativeOriginToZero() {
        let r = CropMath.clip(CGRect(x: -10, y: -20, width: 200, height: 200), to: CGSize(width: 100, height: 100))
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.minY, 0)
        XCTAssertEqual(r.width, 100)
        XCTAssertEqual(r.height, 100)
    }

    func testSnapToIntegerPixels_expandsOutward() {
        let r = CropMath.snapToIntegerPixels(CGRect(x: 1.4, y: 2.6, width: 3.5, height: 4.5))
        XCTAssertEqual(r.minX, 1)
        XCTAssertEqual(r.minY, 2)
        XCTAssertEqual(r.maxX, 5)
        XCTAssertEqual(r.maxY, 8)
    }

    // MARK: - Aspect

    func testApplyAspect_freeReturnsCandidate() {
        let cand = CGRect(x: 0, y: 0, width: 100, height: 50)
        let out = CropMath.applyAspect(candidate: cand, anchor: .zero, aspect: nil)
        XCTAssertEqual(out, cand)
    }

    func testApplyAspect_squareConstrainsBoth() {
        let cand = CGRect(x: 0, y: 0, width: 100, height: 50)
        let out = CropMath.applyAspect(candidate: cand, anchor: .zero, aspect: (1, 1))
        XCTAssertEqual(out.width, out.height)
    }

    func testApplyAspect_keepsAnchorAtOppositeCorner() {
        // Anchor at top-left (0,0); user dragged bottom-right corner to (100,50).
        let cand = CGRect(x: 0, y: 0, width: 100, height: 50)
        let out = CropMath.applyAspect(candidate: cand, anchor: CGPoint(x: 0, y: 0), aspect: (1, 1))
        XCTAssertEqual(out.minX, 0)
        XCTAssertEqual(out.minY, 0)
    }

    // MARK: - Hit-test handles

    func testHitHandle_topLeftCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let handle = CropMath.hitHandle(at: CGPoint(x: 100, y: 100), for: rect, handleSize: 14)
        XCTAssertEqual(handle, .topLeft)
    }

    func testHitHandle_middleOfRectMisses() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let handle = CropMath.hitHandle(at: CGPoint(x: 200, y: 200), for: rect, handleSize: 14)
        XCTAssertNil(handle)
    }

    // MARK: - Resize / Move

    func testMove_clampsToImageBounds() {
        let r = CGRect(x: 90, y: 90, width: 50, height: 50)
        let moved = CropMath.move(rect: r, by: CGSize(width: 200, height: 200), imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(moved.maxX, 100)
        XCTAssertEqual(moved.maxY, 100)
    }

    func testResize_centeredKeepsCenter() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 100)
        let out = CropMath.resize(
            rect: r,
            handle: .bottomRight,
            to: CGPoint(x: 180, y: 180),
            imageSize: CGSize(width: 500, height: 500),
            centered: true,
            aspect: nil
        )
        XCTAssertEqual(out.midX, 150, accuracy: 1)
        XCTAssertEqual(out.midY, 150, accuracy: 1)
    }

    // MARK: - MCU rounding

    func testRoundOutwardToMCU_alreadyAligned_returnsSame() {
        let r = CGRect(x: 16, y: 32, width: 64, height: 48)
        let out = CropMath.roundOutwardToMCU(r, mcu: 16, imageSize: CGSize(width: 320, height: 240))
        XCTAssertEqual(out, r)
    }

    func testRoundOutwardToMCU_expandsOutward() {
        // x=20 → 16, maxX=20+60=80 already aligned, stays 80.
        // y=35 → 32, maxY=35+50=85 → 96.
        let r = CGRect(x: 20, y: 35, width: 60, height: 50)
        let out = CropMath.roundOutwardToMCU(r, mcu: 16, imageSize: CGSize(width: 320, height: 240))
        XCTAssertEqual(out.minX, 16)
        XCTAssertEqual(out.minY, 32)
        XCTAssertEqual(out.maxX, 80)
        XCTAssertEqual(out.maxY, 96)
    }

    func testRoundOutwardToMCU_clipsToImageEdge() {
        let r = CGRect(x: 300, y: 200, width: 30, height: 50)
        let out = CropMath.roundOutwardToMCU(r, mcu: 16, imageSize: CGSize(width: 320, height: 240))
        XCTAssertEqual(out.maxX, 320)
        XCTAssertEqual(out.maxY, 240)
    }

    func testIsMCUAligned_imageEdgeIsAllowedNonMultiple() {
        let r = CGRect(x: 0, y: 0, width: 313, height: 237)
        XCTAssertTrue(CropMath.isMCUAligned(r, mcu: 16, imageSize: CGSize(width: 313, height: 237)))
    }
}
