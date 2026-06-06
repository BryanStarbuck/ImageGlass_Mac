import Foundation
import CoreGraphics

/// Pure-Swift geometry for the transparency-checker backdrop.
/// transparent_bk_checkers.mdx §3 / §12.1 — lives in ImageGlassCore
/// so XCTest can verify the formulas without an AppKit window.
public struct CheckerGrid: Sendable, Equatable {
    /// Side length of a "normal" tile in points (== viewport_width / N,
    /// floored). The rightmost column and bottom row may be smaller.
    public let tileSide: CGFloat
    public let columns: Int           // canonically 20
    public let rows: Int              // ceil(H / tileSide)
    /// Width of the 20th column (lines up with the right edge of the
    /// viewport; can be up to ~0.9pt larger than tileSide).
    public let rightColumnWidth: CGFloat
    /// Height of the bottom row (clipped to the viewport).
    public let bottomRowHeight: CGFloat
    /// Echoed back so the renderer doesn't have to thread it separately.
    public let viewport: CGSize

    public init(
        tileSide: CGFloat,
        columns: Int,
        rows: Int,
        rightColumnWidth: CGFloat,
        bottomRowHeight: CGFloat,
        viewport: CGSize
    ) {
        self.tileSide = tileSide
        self.columns = columns
        self.rows = rows
        self.rightColumnWidth = rightColumnWidth
        self.bottomRowHeight = bottomRowHeight
        self.viewport = viewport
    }

    /// Compute the canonical grid for a viewport. See spec §3.
    /// Degenerate cases (zero / negative size) return an empty grid the
    /// renderer treats as "draw nothing."
    public static func compute(viewport: CGSize, columns: Int = 20) -> CheckerGrid {
        let n = max(1, columns)
        guard viewport.width > 0, viewport.height > 0 else {
            return CheckerGrid(
                tileSide: 0, columns: n, rows: 0,
                rightColumnWidth: 0, bottomRowHeight: 0,
                viewport: .zero
            )
        }
        let raw = floor(viewport.width / CGFloat(n))
        let side = max(1, raw)
        // r = W − (N − 1)·s, always ≥ s because s = floor(W/N).
        let right = viewport.width - CGFloat(n - 1) * side
        let rows = max(1, Int(ceil(viewport.height / side)))
        let bottom = viewport.height - CGFloat(rows - 1) * side
        return CheckerGrid(
            tileSide: side,
            columns: n,
            rows: rows,
            rightColumnWidth: right,
            bottomRowHeight: bottom,
            viewport: viewport
        )
    }

    /// Width of column `i` (0-indexed). The last column carries the
    /// leftover so the right edge of the grid lands exactly on the
    /// viewport's right edge.
    public func columnWidth(_ i: Int) -> CGFloat {
        i == columns - 1 ? rightColumnWidth : tileSide
    }

    /// Height of row `j` (0-indexed from the *top*). The bottom row is
    /// clipped to the viewport.
    public func rowHeight(_ j: Int) -> CGFloat {
        j == rows - 1 ? bottomRowHeight : tileSide
    }

    /// True for the **lighter** tone. Spec §3 — corner (0, 0) is light.
    /// `j` is the row counted from the top, so callers in a +y-up
    /// coordinate system must convert.
    public static func isLightTile(column i: Int, row j: Int) -> Bool {
        ((i + j) & 1) == 0
    }
}
