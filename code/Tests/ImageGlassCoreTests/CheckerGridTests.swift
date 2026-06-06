import XCTest
import CoreGraphics
@testable import ImageGlassCore

/// transparent_bk_checkers.mdx §12.1 — deterministic geometry tests
/// for the transparency-checker grid.
final class CheckerGridTests: XCTestCase {

    func testEvenViewport_TileSideIsFloorOfWidthOver20() {
        let g = CheckerGrid.compute(viewport: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(g.tileSide, 100)
        XCTAssertEqual(g.columns, 20)
        XCTAssertEqual(g.rows, 10)
        XCTAssertEqual(g.rightColumnWidth, 100)
        XCTAssertEqual(g.bottomRowHeight, 100)
    }

    func testFractionalViewport_RightColumnAbsorbsLeftover() {
        // W = 1923 ⇒ s = floor(1923/20) = 96, r = 1923 − 19·96 = 99.
        // H = 999 ⇒ rows = ceil(999/96) = 11, bottom = 999 − 10·96 = 39.
        let g = CheckerGrid.compute(viewport: CGSize(width: 1923, height: 999))
        XCTAssertEqual(g.tileSide, 96)
        XCTAssertEqual(g.columns, 20)
        XCTAssertEqual(g.rightColumnWidth, 99)
        XCTAssertEqual(g.rows, 11)
        XCTAssertEqual(g.bottomRowHeight, 39)
    }

    func testRightColumnAlwaysReachesViewportRightEdge() {
        // The promise: the 20 columns together cover the entire width.
        for w in stride(from: 200.0, through: 4000.0, by: 17.0) {
            let g = CheckerGrid.compute(viewport: CGSize(width: w, height: 800))
            let totalWidth = CGFloat(g.columns - 1) * g.tileSide + g.rightColumnWidth
            XCTAssertEqual(totalWidth, CGFloat(w), accuracy: 0.0001,
                "20 columns must sum to viewport width at W=\(w)")
        }
    }

    func testBottomRowAlwaysReachesViewportBottomEdge() {
        for h in stride(from: 100.0, through: 3000.0, by: 13.0) {
            let g = CheckerGrid.compute(viewport: CGSize(width: 1600, height: h))
            let totalHeight = CGFloat(g.rows - 1) * g.tileSide + g.bottomRowHeight
            XCTAssertEqual(totalHeight, CGFloat(h), accuracy: 0.0001,
                "rows must sum to viewport height at H=\(h)")
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
    }

    func testSubColumnCountWidth_ClampsTileSideToOne() {
        // W < 20 ⇒ floor(W/20) = 0; the renderer clamps to 1.
        let g = CheckerGrid.compute(viewport: CGSize(width: 10, height: 50))
        XCTAssertEqual(g.tileSide, 1)
        XCTAssertEqual(g.columns, 20)
        // Right column carries the leftover: 10 − 19·1 = −9.
        // Negative is allowed by the formula; the renderer simply
        // produces an off-screen rect that AppKit's clip discards.
        // The important promise — 20 columns sum to W — still holds.
        let totalWidth = CGFloat(g.columns - 1) * g.tileSide + g.rightColumnWidth
        XCTAssertEqual(totalWidth, 10, accuracy: 0.0001)
    }

    func testColumnWidthAccessor() {
        let g = CheckerGrid.compute(viewport: CGSize(width: 1923, height: 999))
        XCTAssertEqual(g.columnWidth(0), 96)
        XCTAssertEqual(g.columnWidth(18), 96)
        XCTAssertEqual(g.columnWidth(19), 99)
    }

    func testRowHeightAccessor() {
        let g = CheckerGrid.compute(viewport: CGSize(width: 1923, height: 999))
        XCTAssertEqual(g.rowHeight(0), 96)
        XCTAssertEqual(g.rowHeight(9), 96)
        XCTAssertEqual(g.rowHeight(10), 39)  // last row, clipped
    }
}
