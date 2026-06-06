import Foundation
import CoreGraphics

/// Pure-Swift geometry for the transparency-checker backdrop.
/// transparent_bk_checkers.mdx §3 — lives in ImageGlassCore so
/// XCTest can verify the formulas without an AppKit window.
///
/// v1.1: geometry is **height-driven** (`s = floor(H / 25)`), tiles
/// are *perfectly square*, and the column count is `ceil(W · K / s)`
/// where `K` is a width-safety factor (default 2.0). Columns that
/// fall past the viewport's right edge are clipped by AppKit's
/// existing bounds clip — over-allocating to the right is what makes
/// the resize contract in §2.3 cheap.
public struct CheckerGrid: Sendable, Equatable {
    /// Side length of every tile in points. All tiles are squares.
    public let tileSide: CGFloat
    /// Total columns painted (typically more than fit on screen so
    /// the right edge stays covered during a window-widening drag).
    public let columns: Int
    /// Total rows painted (≈ 25; can be 26 when `H mod tileSide != 0`,
    /// in which case the 26th row overflows below the viewport edge
    /// and AppKit clips the overhang).
    public let rows: Int
    /// Echoed back so the renderer doesn't have to thread it separately.
    public let viewport: CGSize

    public init(
        tileSide: CGFloat,
        columns: Int,
        rows: Int,
        viewport: CGSize
    ) {
        self.tileSide = tileSide
        self.columns = columns
        self.rows = rows
        self.viewport = viewport
    }

    /// Compute the canonical grid for a viewport. See spec §3.
    /// Degenerate cases (zero / negative size) return an empty grid the
    /// renderer treats as "draw nothing."
    ///
    /// - Parameters:
    ///   - viewport: the canvas size in points.
    ///   - rows: the spec-fixed visible row count (default 25).
    ///   - widthSafetyFactor: how many viewport-widths to over-paint
    ///     so a fast window-widening drag never bares the right edge
    ///     (default 2.0).
    public static func compute(
        viewport: CGSize,
        rows targetRows: Int = 25,
        widthSafetyFactor: CGFloat = 2.0
    ) -> CheckerGrid {
        let r = max(1, targetRows)
        guard viewport.width > 0, viewport.height > 0 else {
            return CheckerGrid(
                tileSide: 0, columns: 0, rows: 0, viewport: .zero
            )
        }
        let raw = floor(viewport.height / CGFloat(r))
        let side = max(1, raw)
        let rowsCount = max(1, Int(ceil(viewport.height / side)))
        let cols = max(0, Int(ceil(viewport.width * max(widthSafetyFactor, 1) / side)))
        return CheckerGrid(
            tileSide: side,
            columns: cols,
            rows: rowsCount,
            viewport: viewport
        )
    }

    /// True for the **lighter** tone. Spec §3.5 — corner (0, 0) is light.
    /// `j` is the row counted from the top, so callers in a +y-up
    /// coordinate system must convert.
    public static func isLightTile(column i: Int, row j: Int) -> Bool {
        ((i + j) & 1) == 0
    }
}
