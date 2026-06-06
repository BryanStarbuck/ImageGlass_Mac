import XCTest
import CoreGraphics
@testable import ImageGlassCore

/// transparent_bk_checkers.mdx §12.1 — deterministic geometry tests
/// for the height-driven transparency-checker grid.
final class CheckerGridTests: XCTestCase {

    func testEvenViewport_TileSideIsFloorOfHeightOver25() {
        let g = CheckerGrid.compute(viewport: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(g.tileSide, 40)
        XCTAssertEqual(g.rows, 25)
        // columns = ceil(2000 · 2 / 40) = 100
        XCTAssertEqual(g.columns, 100)
    }

    func testFractionalViewport_BottomRowOverflows() {
        // H = 999 ⇒ s = floor(999/25) = 39
        // rows = ceil(999/39) = 26 (the 26th row overflows below)
        // columns = ceil(1923 · 2 / 39) = ceil(98.6) = 99
        let g = CheckerGrid.compute(viewport: CGSize(width: 1923, height: 999))
        XCTAssertEqual(g.tileSide, 39)
        XCTAssertEqual(g.rows, 26)
        XCTAssertEqual(g.columns, 99)
    }

    func testTypical1080pViewport() {
        // H = 1080 ⇒ s = floor(1080/25) = 43
        // rows = ceil(1080/43) = 26
        // columns = ceil(1920 · 2 / 43) = ceil(89.3) = 90
        let g = CheckerGrid.compute(viewport: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(g.tileSide, 43)
        XCTAssertEqual(g.rows, 26)
        XCTAssertEqual(g.columns, 90)
    }

    func testColumnsAlwaysOverflowTheViewport() {
        // The promise: the painted column count always covers more
        // than the visible width — at least 2× by spec §3.3.
        for w in stride(from: 200.0, through: 4000.0, by: 17.0) {
            let g = CheckerGrid.compute(viewport: CGSize(width: w, height: 1000))
            let paintedWidth = CGFloat(g.columns) * g.tileSide
            XCTAssertGreaterThanOrEqual(
                paintedWidth, CGFloat(w) * 2,
                "painted column run must cover ≥ 2 viewport widths at W=\(w)"
            )
        }
    }

    func testRowsAlwaysCoverTheViewportHeight() {
        for h in stride(from: 100.0, through: 3000.0, by: 13.0) {
            let g = CheckerGrid.compute(viewport: CGSize(width: 1600, height: h))
            let paintedHeight = CGFloat(g.rows) * g.tileSide
            XCTAssertGreaterThanOrEqual(
                paintedHeight, CGFloat(h),
                "painted rows must cover the full viewport height at H=\(h)"
            )
        }
    }

    func testRowCountIs25Or26AtTypicalSizes() {
        // Spec §3.2 — at typical viewport heights, rows = 25 when
        // H is divisible by tileSide, else 26 (one-row overflow).
        // Algebra: with s = floor(H/25), rows = 25 + ceil(r/s) where
        // r = H mod 25. For rows ≤ 26 we need r ≤ s, which holds
        // unconditionally once H ≥ 650 (where s ≥ 26 > r). The spec
        // explicitly tolerates degenerate small heights (§11) and
        // the user does not perceive a 25-row grid at those sizes.
        for h in stride(from: 650.0, through: 3000.0, by: 7.0) {
            let g = CheckerGrid.compute(viewport: CGSize(width: 1600, height: h))
            XCTAssertTrue(g.rows == 25 || g.rows == 26,
                "rows must be 25 or 26 at H=\(h), got \(g.rows)")
        }
    }

    func testTopLeftTileIsLight() {
        XCTAssertTrue(CheckerGrid.isLightTile(column: 0, row: 0))
        XCTAssertFalse(CheckerGrid.isLightTile(column: 1, row: 0))
        XCTAssertFalse(CheckerGrid.isLightTile(column: 0, row: 1))
        XCTAssertTrue(CheckerGrid.isLightTile(column: 1, row: 1))
    }

    func testZeroViewport_ReturnsEmptyGrid() {
        let g = CheckerGrid.compute(viewport: .zero)
        XCTAssertEqual(g.tileSide, 0)
        XCTAssertEqual(g.rows, 0)
        XCTAssertEqual(g.columns, 0)
    }

    func testSubRowCountHeight_ClampsTileSideToOne() {
        // H < 25 ⇒ floor(H/25) = 0; the renderer clamps to 1.
        let g = CheckerGrid.compute(viewport: CGSize(width: 100, height: 10))
        XCTAssertEqual(g.tileSide, 1)
        XCTAssertEqual(g.rows, 10)  // ceil(10/1)
        // columns = ceil(100 · 2 / 1) = 200
        XCTAssertEqual(g.columns, 200)
    }

    func testCustomSafetyFactor() {
        // K = 3.0 — paint triple-width.
        let g = CheckerGrid.compute(
            viewport: CGSize(width: 2000, height: 1000),
            widthSafetyFactor: 3.0
        )
        XCTAssertEqual(g.tileSide, 40)
        XCTAssertEqual(g.columns, 150)  // ceil(2000·3/40)
    }

    func testCustomRowCount() {
        // R = 10 — fewer, bigger rows.
        let g = CheckerGrid.compute(
            viewport: CGSize(width: 2000, height: 1000),
            rows: 10
        )
        XCTAssertEqual(g.tileSide, 100)
        XCTAssertEqual(g.rows, 10)
    }
}
