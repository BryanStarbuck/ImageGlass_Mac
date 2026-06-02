import Foundation
import CoreGraphics

/// Pure geometry helpers for the crop tool.
///
/// All rectangles are in **image pixel coordinates** with origin at the
/// top-left of the image (y grows downward). The viewer overlay converts
/// to/from canvas coordinates separately. Keeping this file pure (no
/// AppKit, no SwiftUI) makes it directly testable and reusable from the
/// MCP `crop_image` tool.
public enum CropMath {

    // MARK: - Initial selection

    /// Resolve the initial rect for a newly-opened crop tool. Centers a
    /// percentage of each axis (`docs/crop.mdx §3`). For `selectAll` the
    /// image bounds are returned; for `selectNone` nil. Custom/last
    /// selection are the caller's responsibility (they need session state).
    public static func initialRect(
        for policy: CropInitSelectionType,
        imageSize: CGSize,
        customRect: CGRect? = nil,
        autoCenter: Bool = true,
        lastSelection: CGRect? = nil
    ) -> CGRect? {
        switch policy {
        case .selectNone:
            return nil
        case .selectAll:
            return CGRect(origin: .zero, size: imageSize)
        case .customArea:
            guard let r = customRect else { return nil }
            if autoCenter {
                let x = ((imageSize.width  - r.width)  / 2).rounded()
                let y = ((imageSize.height - r.height) / 2).rounded()
                return clip(CGRect(x: x, y: y, width: r.width, height: r.height), to: imageSize)
            }
            return clip(r, to: imageSize)
        case .useLastSelection:
            guard let r = lastSelection else { return nil }
            return clip(r, to: imageSize)
        default:
            guard let f = policy.percentFraction else { return nil }
            let w = (imageSize.width  * CGFloat(f)).rounded()
            let h = (imageSize.height * CGFloat(f)).rounded()
            let x = ((imageSize.width  - w) / 2).rounded()
            let y = ((imageSize.height - h) / 2).rounded()
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: - Clip & snap

    /// Clip `rect` to fit inside `0..<size`. Negative origins are pushed
    /// to 0; size overflow is trimmed. Negative or zero sizes return nil.
    public static func clip(_ rect: CGRect, to size: CGSize) -> CGRect {
        let x = max(0, rect.origin.x)
        let y = max(0, rect.origin.y)
        let w = min(rect.maxX, size.width)  - x
        let h = min(rect.maxY, size.height) - y
        if w <= 0 || h <= 0 { return .zero }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Snap each edge to integer pixels. The spec's "snap to grid" toggle
    /// means "no subpixel selection" — clamp X/Y down, W/H up.
    public static func snapToIntegerPixels(_ rect: CGRect) -> CGRect {
        let x = floor(rect.origin.x)
        let y = floor(rect.origin.y)
        let w = ceil(rect.maxX) - x
        let h = ceil(rect.maxY) - y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Aspect ratio

    /// The effective (w, h) ratio components from a preset or custom value.
    /// `original` resolves against the active image size. Returns nil for
    /// `freeRatio`.
    public static func ratioComponents(
        for aspect: SelectionAspectRatio,
        imageSize: CGSize,
        customW: Int,
        customH: Int
    ) -> (w: CGFloat, h: CGFloat)? {
        if aspect == .freeRatio { return nil }
        if aspect == .original {
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            return (imageSize.width, imageSize.height)
        }
        if aspect == .custom {
            guard customW > 0, customH > 0 else { return nil }
            return (CGFloat(customW), CGFloat(customH))
        }
        if let c = aspect.components { return (CGFloat(c.w), CGFloat(c.h)) }
        return nil
    }

    /// Apply an aspect-ratio constraint to a candidate rect during a drag.
    /// `anchor` is the point on the rect that must remain fixed (the
    /// opposite corner/edge to whichever handle is being dragged, or the
    /// center for ⌥ centered-resize). When the user is freely drawing a
    /// new selection, pass the click-origin as the anchor.
    ///
    /// Returns the rect after coercion. If `aspect` is `nil` (free) the
    /// candidate is returned unchanged.
    public static func applyAspect(
        candidate: CGRect,
        anchor: CGPoint,
        aspect: (w: CGFloat, h: CGFloat)?
    ) -> CGRect {
        guard let aspect, aspect.w > 0, aspect.h > 0 else { return candidate }
        let ratio = aspect.w / aspect.h
        let w = abs(candidate.width)
        let h = abs(candidate.height)
        // Pick whichever dimension is "bigger relative to ratio" and let
        // the other follow. Matches upstream's behavior of growing the
        // larger axis.
        let coercedW: CGFloat
        let coercedH: CGFloat
        if w / max(h, 1) >= ratio {
            coercedW = w
            coercedH = w / ratio
        } else {
            coercedH = h
            coercedW = h * ratio
        }
        // Resolve origin relative to anchor. If anchor sits inside the
        // candidate rect, treat it as the center (centered-resize case).
        if candidate.contains(anchor) || candidate.insetBy(dx: -0.001, dy: -0.001).contains(anchor) {
            // Centered: anchor stays at the center.
            let isCenter = abs(anchor.x - candidate.midX) < 0.5 && abs(anchor.y - candidate.midY) < 0.5
            if isCenter {
                return CGRect(
                    x: anchor.x - coercedW / 2,
                    y: anchor.y - coercedH / 2,
                    width: coercedW,
                    height: coercedH
                )
            }
        }
        // Anchor sits at the opposite corner: re-derive origin so the
        // anchor stays put.
        let xOrigin: CGFloat
        let yOrigin: CGFloat
        if candidate.maxX >= anchor.x {
            xOrigin = anchor.x
        } else {
            xOrigin = anchor.x - coercedW
        }
        if candidate.maxY >= anchor.y {
            yOrigin = anchor.y
        } else {
            yOrigin = anchor.y - coercedH
        }
        return CGRect(x: xOrigin, y: yOrigin, width: coercedW, height: coercedH)
    }

    // MARK: - Hit-testing handles

    /// Returns the eight handle rectangles, in image-pixel coordinates,
    /// for a given selection rect. Each handle is `handleSize × handleSize`
    /// centered on its edge midpoint or corner. Pass the same number of
    /// pixels you would draw in the overlay.
    public static func handleRects(
        for rect: CGRect,
        handleSize: CGFloat
    ) -> [CropHandle: CGRect] {
        let s = handleSize
        let h = s / 2
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let midX = rect.midX
        let midY = rect.midY
        func sq(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
            CGRect(x: cx - h, y: cy - h, width: s, height: s)
        }
        return [
            .topLeft:     sq(minX, minY),
            .top:         sq(midX, minY),
            .topRight:    sq(maxX, minY),
            .left:        sq(minX, midY),
            .right:       sq(maxX, midY),
            .bottomLeft:  sq(minX, maxY),
            .bottom:      sq(midX, maxY),
            .bottomRight: sq(maxX, maxY),
        ]
    }

    /// Returns the handle hit by `point`, or nil. Spec §5.3.
    public static func hitHandle(
        at point: CGPoint,
        for rect: CGRect,
        handleSize: CGFloat
    ) -> CropHandle? {
        for (handle, hr) in handleRects(for: rect, handleSize: handleSize) {
            if hr.contains(point) { return handle }
        }
        return nil
    }

    // MARK: - Resize / move

    /// Resize `rect` by dragging the named `handle` to `point`.
    /// `centered` mirrors the drag around the rect's center (Option key);
    /// `aspect` constrains the ratio (Shift key, or the panel's Lock).
    public static func resize(
        rect: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        imageSize: CGSize,
        centered: Bool,
        aspect: (w: CGFloat, h: CGFloat)?
    ) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .left:        minX = point.x
        case .right:       maxX = point.x
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomRight: maxX = point.x; maxY = point.y
        }
        var candidate = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )

        // Centered: mirror the moving edge across the original center.
        if centered {
            let cx = rect.midX
            let cy = rect.midY
            let halfW = max(abs(point.x - cx), 1)
            let halfH = max(abs(point.y - cy), 1)
            switch handle {
            case .top, .bottom:
                candidate = CGRect(x: rect.minX, y: cy - halfH, width: rect.width, height: halfH * 2)
            case .left, .right:
                candidate = CGRect(x: cx - halfW, y: rect.minY, width: halfW * 2, height: rect.height)
            default:
                candidate = CGRect(x: cx - halfW, y: cy - halfH, width: halfW * 2, height: halfH * 2)
            }
        }

        if let aspect {
            let anchor = centered
                ? CGPoint(x: rect.midX, y: rect.midY)
                : anchorForHandle(handle, in: rect)
            candidate = applyAspect(candidate: candidate, anchor: anchor, aspect: aspect)
        }

        return clip(candidate, to: imageSize)
    }

    /// Translate `rect` by `delta`, clipped to `imageSize`. If the move
    /// would push the rect off the image, slide it back so it fits.
    public static func move(rect: CGRect, by delta: CGSize, imageSize: CGSize) -> CGRect {
        var x = rect.minX + delta.width
        var y = rect.minY + delta.height
        x = min(max(0, x), max(0, imageSize.width  - rect.width))
        y = min(max(0, y), max(0, imageSize.height - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The anchor that stays fixed when dragging `handle` (the opposite
    /// corner/edge midpoint). Used by `applyAspect` to know where to
    /// nail the rect down while reshaping.
    public static func anchorForHandle(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.maxX, y: rect.midY)
        case .right:       return CGPoint(x: rect.minX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    // MARK: - Keyboard nudges

    /// Nudge the entire selection by (dx, dy), clipped to the image.
    public static func nudge(rect: CGRect, dx: CGFloat, dy: CGFloat, imageSize: CGSize) -> CGRect {
        move(rect: rect, by: CGSize(width: dx, height: dy), imageSize: imageSize)
    }

    /// Grow the rect by extending the bottom-right corner by (dw, dh).
    /// Spec §2.4: ⌘+Arrow resizes the selection by growing the far edge.
    public static func grow(rect: CGRect, dw: CGFloat, dh: CGFloat, imageSize: CGSize) -> CGRect {
        let r = CGRect(
            x: rect.minX,
            y: rect.minY,
            width:  max(1, rect.width  + dw),
            height: max(1, rect.height + dh)
        )
        return clip(r, to: imageSize)
    }

    // MARK: - MCU rounding (lossless JPEG)

    /// Round `rect` outward to the nearest MCU boundary. JPEG MCUs are
    /// 8 px for grayscale / 4:4:4-chroma, 16 px for 4:2:0-chroma (most
    /// common). `mcu` is the MCU size in pixels. The result's edges align
    /// to multiples of `mcu` and the result fully contains `rect`. The
    /// result is also clipped to the image bounds (when the rounding
    /// would have pushed the right/bottom edge past the image, that
    /// edge is left at the image's right/bottom — JPEG decoders allow
    /// the last MCU row/column to be partial).
    public static func roundOutwardToMCU(
        _ rect: CGRect,
        mcu: Int,
        imageSize: CGSize
    ) -> CGRect {
        guard mcu > 0 else { return rect }
        let m = CGFloat(mcu)
        let x0 = floor(rect.minX / m) * m
        let y0 = floor(rect.minY / m) * m
        var x1 = ceil(rect.maxX / m) * m
        var y1 = ceil(rect.maxY / m) * m
        x1 = min(x1, imageSize.width)
        y1 = min(y1, imageSize.height)
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// `true` iff `rect` is already MCU-aligned on every edge. The right
    /// and bottom edges are allowed to coincide with the image edge even
    /// when they are not on an MCU boundary (the last MCU may be partial).
    public static func isMCUAligned(
        _ rect: CGRect,
        mcu: Int,
        imageSize: CGSize
    ) -> Bool {
        guard mcu > 0 else { return true }
        let m = CGFloat(mcu)
        func onGrid(_ v: CGFloat) -> Bool {
            let q = v / m
            return abs(q - q.rounded()) < 0.001
        }
        let leftOK   = onGrid(rect.minX)
        let topOK    = onGrid(rect.minY)
        let rightOK  = onGrid(rect.maxX) || abs(rect.maxX - imageSize.width)  < 0.001
        let bottomOK = onGrid(rect.maxY) || abs(rect.maxY - imageSize.height) < 0.001
        return leftOK && topOK && rightOK && bottomOK
    }
}
