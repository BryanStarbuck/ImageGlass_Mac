import XCTest
@testable import ImageGlassCore

final class ZoomMathTests: XCTestCase {

    private let image = CGSize(width: 1000, height: 500)
    private let port  = CGSize(width: 800,  height: 600)

    // MARK: - Mode-specific scale math

    func testAutoZoom_belowViewport_keepsActualSize() {
        let s = ZoomMath.scale(
            for: .auto,
            imageSize: CGSize(width: 200, height: 100),
            viewportSize: port,
            lockedZoom: 1
        )
        XCTAssertEqual(s, 1.0)
    }

    func testAutoZoom_largerThanViewport_fits() {
        let s = ZoomMath.scale(
            for: .auto,
            imageSize: image,
            viewportSize: port,
            lockedZoom: 1
        )
        // min(800/1000, 600/500) = 0.8
        XCTAssertEqual(s, 0.8, accuracy: 0.0001)
    }

    func testScaleToWidth() {
        let s = ZoomMath.scale(for: .width, imageSize: image, viewportSize: port, lockedZoom: 1)
        XCTAssertEqual(s, 0.8, accuracy: 0.0001)
    }

    func testScaleToHeight() {
        let s = ZoomMath.scale(for: .height, imageSize: image, viewportSize: port, lockedZoom: 1)
        // 600 / 500 = 1.2
        XCTAssertEqual(s, 1.2, accuracy: 0.0001)
    }

    func testScaleToFit_picksSmaller() {
        let s = ZoomMath.scale(for: .fit, imageSize: image, viewportSize: port, lockedZoom: 1)
        XCTAssertEqual(s, 0.8, accuracy: 0.0001)
    }

    func testScaleToFill_picksLarger() {
        let s = ZoomMath.scale(for: .fill, imageSize: image, viewportSize: port, lockedZoom: 1)
        XCTAssertEqual(s, 1.2, accuracy: 0.0001)
    }

    func testLockZoom_usesProvidedFactor() {
        let s = ZoomMath.scale(for: .lock, imageSize: image, viewportSize: port, lockedZoom: 2.5)
        XCTAssertEqual(s, 2.5, accuracy: 0.0001)
    }

    func testLockZoom_clampedToLimits() {
        let high = ZoomMath.scale(for: .lock, imageSize: image, viewportSize: port, lockedZoom: 9999)
        XCTAssertEqual(high, ZoomLimits.max)
        let low = ZoomMath.scale(for: .lock, imageSize: image, viewportSize: port, lockedZoom: 0.0001)
        XCTAssertEqual(low, ZoomLimits.min)
    }

    func testZeroSizes_returnIdentity() {
        XCTAssertEqual(
            ZoomMath.scale(for: .fit, imageSize: .zero, viewportSize: port, lockedZoom: 1),
            1.0
        )
        XCTAssertEqual(
            ZoomMath.scale(for: .fit, imageSize: image, viewportSize: .zero, lockedZoom: 1),
            1.0
        )
    }

    // MARK: - Display rect

    func testDisplayRect_centered_noPan() {
        let r = ZoomMath.displayRect(
            imageSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 300, height: 300),
            scale: 1.0,
            panOffset: .zero
        )
        XCTAssertEqual(r.origin.x, 100)
        XCTAssertEqual(r.origin.y, 100)
        XCTAssertEqual(r.size.width, 100)
        XCTAssertEqual(r.size.height, 100)
    }

    func testDisplayRect_appliesScaleAndPan() {
        let r = ZoomMath.displayRect(
            imageSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 300, height: 300),
            scale: 2.0,
            panOffset: CGSize(width: 25, height: -10)
        )
        // drawn = 200x200, centered origin = (50,50), plus pan
        XCTAssertEqual(r.origin.x, 75)
        XCTAssertEqual(r.origin.y, 40)
        XCTAssertEqual(r.size.width, 200)
        XCTAssertEqual(r.size.height, 200)
    }

    // MARK: - Zoom around focal point

    func testZoom_keepsFocalPixelStable() {
        let viewport = CGSize(width: 400, height: 400)
        let focal = CGPoint(x: 350, y: 50)

        let result = ZoomMath.zoom(
            currentScale: 1.0,
            currentPan: .zero,
            viewportSize: viewport,
            focal: focal,
            multiplier: 2.0
        )

        XCTAssertEqual(result.scale, 2.0, accuracy: 0.0001)
        // ratio = 2, factor = (1 - ratio) = -1
        // dx = (350-200)*-1 = -150, dy = (50-200)*-1 = 150
        XCTAssertEqual(result.pan.width,  -150, accuracy: 0.0001)
        XCTAssertEqual(result.pan.height,  150, accuracy: 0.0001)
    }

    func testZoom_noOpWhenClamped() {
        let result = ZoomMath.zoom(
            currentScale: ZoomLimits.max,
            currentPan: CGSize(width: 5, height: 6),
            viewportSize: CGSize(width: 200, height: 200),
            focal: CGPoint(x: 100, y: 100),
            multiplier: 1.5
        )
        XCTAssertEqual(result.scale, ZoomLimits.max)
        XCTAssertEqual(result.pan.width, 5)
        XCTAssertEqual(result.pan.height, 6)
    }
}
