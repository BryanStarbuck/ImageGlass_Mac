import XCTest
@testable import ImageGlassCore

final class CropGeometryTests: XCTestCase {

    // MARK: - CropRect.clamped

    func testClampedShrinksToFitInsideSource() {
        let rect = CropRect(x: 100, y: 100, width: 1000, height: 1000)
        let clamped = rect.clamped(toSourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(clamped.x, 100)
        XCTAssertEqual(clamped.y, 100)
        XCTAssertEqual(clamped.width, 700)
        XCTAssertEqual(clamped.height, 500)
    }

    func testClampedHandlesNegativeOriginAndShrinksWidth() {
        let rect = CropRect(x: -50, y: -30, width: 200, height: 100)
        let clamped = rect.clamped(toSourceWidth: 1000, sourceHeight: 1000)
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
        XCTAssertEqual(clamped.width, 150)
        XCTAssertEqual(clamped.height, 70)
    }

    func testClampedNormalizesNegativeWidth() {
        // Drag-up-and-left semantics: negative width/height should still
        // produce a valid rectangle (spec 7.6 — negative-direction drags).
        let rect = CropRect(x: 100, y: 100, width: -40, height: -60)
        let clamped = rect.clamped(toSourceWidth: 1000, sourceHeight: 1000)
        XCTAssertEqual(clamped.x, 60)
        XCTAssertEqual(clamped.y, 40)
        XCTAssertEqual(clamped.width, 40)
        XCTAssertEqual(clamped.height, 60)
    }

    func testCenteredPercent() {
        let r = CropRect.centered(percent: 0.5, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(r.width, 400)
        XCTAssertEqual(r.height, 300)
        XCTAssertEqual(r.x, 200)
        XCTAssertEqual(r.y, 150)
    }

    func testCenteredRatioWidthLimited() {
        // 16:9 inside 800×600. Width-limited because 16/9 (1.78) > 800/600 (1.33).
        let r = CropRect.centeredRatio(w: 16, h: 9, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(r.width, 800)
        XCTAssertEqual(r.height, 450)
        XCTAssertEqual(r.x, 0)
        XCTAssertEqual(r.y, 75)
    }

    func testCenteredRatioHeightLimited() {
        // 1:2 (vertical) inside 800×600 — taller than wide, height-limited.
        let r = CropRect.centeredRatio(w: 1, h: 2, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(r.height, 600)
        XCTAssertEqual(r.width, 300)
        XCTAssertEqual(r.x, 250)
        XCTAssertEqual(r.y, 0)
    }

    // MARK: - CropMath

    func testLockRatioKeepsLargerAxis() {
        // 400×400, target 16:9 → should grow whichever axis is closer.
        let r = LegacyCropMath.lockRatio(width: 400, height: 400, ratioW: 16, ratioH: 9)
        // 16:9 means h = w * 9/16 = 225. We're locking to a side that
        // keeps the larger relative dimension. Default axis (.either)
        // picks whichever requires less change.
        XCTAssertTrue(r.w == 400 || r.h == 400)
        XCTAssertTrue(abs(Double(r.w) / Double(r.h) - 16.0/9.0) < 0.02)
    }

    func testLockRatioFreeRatioReturnsInputs() {
        // Invalid ratio → returns inputs unchanged (clamped non-negative).
        let r = LegacyCropMath.lockRatio(width: 123, height: 456, ratioW: 0, ratioH: 0)
        XCTAssertEqual(r.w, 123)
        XCTAssertEqual(r.h, 456)
    }

    func testSnapToStep() {
        XCTAssertEqual(LegacyCropMath.snap(7, to: 8), 8)
        XCTAssertEqual(LegacyCropMath.snap(4, to: 8), 8)
        XCTAssertEqual(LegacyCropMath.snap(3, to: 8), 0)
        XCTAssertEqual(LegacyCropMath.snap(16, to: 8), 16)
    }

    func testSnapToEdge() {
        XCTAssertEqual(LegacyCropMath.snapToEdge(3, bound: 800, gravity: 8), 0)
        XCTAssertEqual(LegacyCropMath.snapToEdge(795, bound: 800, gravity: 8), 800)
        XCTAssertEqual(LegacyCropMath.snapToEdge(400, bound: 800, gravity: 8), 400)
    }

    // MARK: - SelectionResizer

    func testEightResizersAroundLargeRect() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resizers = SelectionResizer.eight(around: rect)
        XCTAssertEqual(resizers.count, 8)
        let kinds = Set(resizers.map(\.kind))
        XCTAssertTrue(kinds.contains(.topLeft))
        XCTAssertTrue(kinds.contains(.bottomRight))
        XCTAssertTrue(kinds.contains(.top))
        XCTAssertTrue(kinds.contains(.left))
    }

    func testEdgeHandlesHideWhenTooSmall() {
        // A 30×30 rect with default 12pt handles → side length must be
        // < 60 (12 * 5) to hide edge handles.
        let rect = CGRect(x: 0, y: 0, width: 30, height: 30)
        let resizers = SelectionResizer.eight(around: rect)
        // Corners present, edges hidden because rect is too narrow & short.
        let kinds = Set(resizers.map(\.kind))
        XCTAssertTrue(kinds.contains(.topLeft))
        XCTAssertFalse(kinds.contains(.top))
        XCTAssertFalse(kinds.contains(.left))
    }

    func testHitTestPicksCornerOverEdge() {
        // Rect with corner at (0,0). Click at (0,0) should hit topLeft,
        // not top or left, because corner priority is higher.
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let resizers = SelectionResizer.eight(around: rect)
        let hit = SelectionResizer.hitTest(resizers, at: CGPoint(x: 0, y: 0))
        XCTAssertEqual(hit?.kind, .topLeft)
    }

    // MARK: - AspectRatio

    func testAspectRatioResolvedRatio() {
        XCTAssertEqual(AspectRatio.ratio(w: 16, h: 9).resolved(sourceWidth: 1000, sourceHeight: 1000)?.w, 16)
        XCTAssertEqual(AspectRatio.ratio(w: 16, h: 9).resolved(sourceWidth: 1000, sourceHeight: 1000)?.h, 9)
        XCTAssertNil(AspectRatio.free.resolved(sourceWidth: 1000, sourceHeight: 1000))
        XCTAssertEqual(AspectRatio.original.resolved(sourceWidth: 800, sourceHeight: 600)?.w, 800)
    }

    func testAspectRatioRoundTripsThroughCodable() throws {
        let cases: [AspectRatio] = [
            .free,
            .original,
            .custom(w: 21, h: 9),
            .ratio(w: 4, h: 3),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for ar in cases {
            let data = try enc.encode(ar)
            let round = try dec.decode(AspectRatio.self, from: data)
            XCTAssertEqual(round, ar)
        }
    }

    // MARK: - DefaultSelectionType

    func testDefaultSelectionPercentResolves() {
        let r = DefaultSelectionType.percent(0.5).resolve(
            sourceWidth: 1000,
            sourceHeight: 800,
            lastUsed: nil
        )
        XCTAssertEqual(r?.width, 500)
        XCTAssertEqual(r?.height, 400)
    }

    func testDefaultSelectionLastUsedClampsToBounds() {
        let last = CropRect(x: 200, y: 200, width: 5000, height: 5000)
        let r = DefaultSelectionType.lastUsed.resolve(
            sourceWidth: 800,
            sourceHeight: 600,
            lastUsed: last
        )
        XCTAssertEqual(r?.x, 200)
        XCTAssertEqual(r?.y, 200)
        XCTAssertEqual(r?.width, 600)
        XCTAssertEqual(r?.height, 400)
    }

    func testDefaultSelectionNoneReturnsNil() {
        XCTAssertNil(DefaultSelectionType.none.resolve(
            sourceWidth: 100, sourceHeight: 100, lastUsed: nil
        ))
    }

    func testDefaultSelectionRoundTripsThroughCodable() throws {
        let cases: [DefaultSelectionType] = [
            .none,
            .lastUsed,
            .percent(0.6666),
            .customRect(CropRect(x: 10, y: 20, width: 100, height: 200)),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for d in cases {
            let data = try enc.encode(d)
            let round = try dec.decode(DefaultSelectionType.self, from: data)
            XCTAssertEqual(round, d)
        }
    }
}
