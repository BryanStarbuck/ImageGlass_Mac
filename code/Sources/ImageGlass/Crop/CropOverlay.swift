import SwiftUI
import AppKit
import CoreGraphics
import ImageGlassCore

/// SwiftUI overlay drawn over the viewer canvas. Renders the dim mask,
/// grid, border, and the eight resize handles (`docs/crop.mdx §2.1`).
///
/// Mouse handling: the overlay receives mouseDown/Dragged/Up by being
/// a focused, hit-tested SwiftUI view. Handle hit-testing is done in
/// image-pixel coordinates via `CropMath.hitHandle(at:for:handleSize:)`.
///
/// Coordinate spaces: this view lives in view-coordinate space (the
/// SwiftUI rectangle of the canvas). All math runs in image pixels;
/// `imageSize` is the source-pixel size, which we map onto the view's
/// `geometry.size`. This is correct as long as the canvas is showing
/// the full image; when zoomed/panned, the host should pass a
/// transform via `imageToView` / `viewToImage` (kept simple for v1).
struct CropOverlay: View {
    @Bindable var controller: CropController

    /// Block-color tint for the dim mask. Default 60 % black per spec.
    var dimOpacity: Double = 0.60

    var body: some View {
        GeometryReader { geom in
            let imageSize = controller.activeImageSize
            let viewSize = geom.size
            let scale = displayScale(view: viewSize, image: imageSize)

            ZStack {
                if controller.isActive {
                    if let rect = controller.rect {
                        dimMask(rect: rect, scale: scale, viewSize: viewSize)
                        grid(rect: rect, scale: scale)
                        border(rect: rect, scale: scale)
                        handles(rect: rect, scale: scale)
                    } else {
                        Color.black.opacity(dimOpacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(scale: scale, viewSize: viewSize))
            .onAppear { controller.consumePendingFromMCP() }
        }
    }

    // MARK: - Coordinate mapping

    /// Uniform scale that fits `imageSize` into `viewSize` with letterboxing.
    /// Returns 1.0 when either dimension is zero (overlay is unused then).
    private func displayScale(view: CGSize, image: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(view.width / image.width, view.height / image.height)
    }

    private func imagePoint(from viewPoint: CGPoint, scale: CGFloat, viewSize: CGSize) -> CGPoint {
        let img = controller.activeImageSize
        let dx = (viewSize.width  - img.width  * scale) / 2
        let dy = (viewSize.height - img.height * scale) / 2
        return CGPoint(
            x: (viewPoint.x - dx) / scale,
            y: (viewPoint.y - dy) / scale
        )
    }

    private func viewRect(from imageRect: CGRect, scale: CGFloat) -> CGRect {
        let img = controller.activeImageSize
        let dx = max(0, (overlayViewSize.width  - img.width  * scale) / 2)
        let dy = max(0, (overlayViewSize.height - img.height * scale) / 2)
        return CGRect(
            x: dx + imageRect.minX * scale,
            y: dy + imageRect.minY * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
    }

    /// SwiftUI doesn't pass geom into computed helpers easily; we stash
    /// the latest size here via `onPreferenceChange` of GeometryReader.
    /// For simplicity we capture in the GeometryReader closure directly
    /// (callers pass scale + viewSize) — `viewRect(from:scale:)` uses
    /// the controller-bound image size and assumes centered fit.
    private var overlayViewSize: CGSize { .zero }

    // MARK: - Layers

    private func dimMask(rect: CGRect, scale: CGFloat, viewSize: CGSize) -> some View {
        let img = controller.activeImageSize
        let dx = (viewSize.width  - img.width  * scale) / 2
        let dy = (viewSize.height - img.height * scale) / 2
        let r = CGRect(
            x: dx + rect.minX * scale,
            y: dy + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        return Color.black.opacity(dimOpacity)
            .mask(
                ZStack {
                    Color.white
                    Color.black.frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .allowsHitTesting(false)
    }

    private func grid(rect: CGRect, scale: CGFloat) -> some View {
        Canvas { ctx, size in
            let img = controller.activeImageSize
            let dx = (size.width  - img.width  * scale) / 2
            let dy = (size.height - img.height * scale) / 2
            let r = CGRect(
                x: dx + rect.minX * scale,
                y: dy + rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            drawGrid(in: ctx, rect: r, mode: controller.gridMode)
        }
        .allowsHitTesting(false)
    }

    private func border(rect: CGRect, scale: CGFloat) -> some View {
        Canvas { ctx, size in
            let img = controller.activeImageSize
            let dx = (size.width  - img.width  * scale) / 2
            let dy = (size.height - img.height * scale) / 2
            let r = CGRect(
                x: dx + rect.minX * scale,
                y: dy + rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            var stroke = Path()
            stroke.addRect(r)
            ctx.stroke(stroke, with: .color(.accentColor), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func handles(rect: CGRect, scale: CGFloat) -> some View {
        Canvas { ctx, size in
            let img = controller.activeImageSize
            let dx = (size.width  - img.width  * scale) / 2
            let dy = (size.height - img.height * scale) / 2
            let handlesViewSize: CGFloat = 10
            let cornerSize: CGFloat = 12

            let handleRectsInImage = CropMath.handleRects(
                for: rect,
                handleSize: max(handlesViewSize, cornerSize) / scale
            )
            for (handle, hr) in handleRectsInImage {
                let isCorner: Bool
                switch handle {
                case .topLeft, .topRight, .bottomLeft, .bottomRight: isCorner = true
                default: isCorner = false
                }
                let s: CGFloat = isCorner ? cornerSize : handlesViewSize
                let cx = dx + hr.midX * scale
                let cy = dy + hr.midY * scale
                let view = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
                var p = Path()
                p.addRoundedRect(in: view, cornerSize: CGSize(width: 2, height: 2))
                ctx.fill(p, with: .color(.accentColor))
                ctx.stroke(p, with: .color(.white), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(in ctx: GraphicsContext, rect: CGRect, mode: CropGridMode) {
        guard rect.width > 1, rect.height > 1 else { return }
        let color = Color.white.opacity(0.55)
        switch mode {
        case .none:
            return
        case .thirds:
            for f in [1.0/3.0, 2.0/3.0] {
                var p = Path()
                p.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                ctx.stroke(p, with: .color(color), lineWidth: 0.5)
                var q = Path()
                q.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                q.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
                ctx.stroke(q, with: .color(color), lineWidth: 0.5)
            }
        case .goldenRatio:
            for f in [0.382, 0.618] {
                var p = Path()
                p.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                ctx.stroke(p, with: .color(color), lineWidth: 0.5)
                var q = Path()
                q.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                q.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
                ctx.stroke(q, with: .color(color), lineWidth: 0.5)
            }
        case .goldenSpiralDiagonals:
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.stroke(p, with: .color(color), lineWidth: 0.5)
            var q = Path()
            q.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            q.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            ctx.stroke(q, with: .color(color), lineWidth: 0.5)
        case .grid8:
            for i in 1..<8 {
                let f = Double(i) / 8.0
                var p = Path()
                p.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                ctx.stroke(p, with: .color(color), lineWidth: 0.5)
                var q = Path()
                q.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                q.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
                ctx.stroke(q, with: .color(color), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Drag

    private func dragGesture(scale: CGFloat, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = imagePoint(from: value.startLocation, scale: scale, viewSize: viewSize)
                let now   = imagePoint(from: value.location,      scale: scale, viewSize: viewSize)
                let mods = NSEvent.modifierFlags
                let shift = mods.contains(.shift)
                let option = mods.contains(.option)
                let aspect = controller.dragAspect(shift: shift)

                let existing = controller.rect

                if controller.dragState == .idle {
                    if let r = existing,
                       let handle = CropMath.hitHandle(at: start, for: r, handleSize: 14 / scale) {
                        controller.dragState = .resizing
                        controller.activeHandle = handle
                    } else if let r = existing, r.contains(start) {
                        controller.dragState = .moving
                        controller.moveAnchor = CGPoint(x: start.x - r.minX, y: start.y - r.minY)
                    } else {
                        controller.dragState = .drawing
                        controller.drawAnchor = start
                    }
                }

                switch controller.dragState {
                case .drawing:
                    let anchor = controller.drawAnchor ?? start
                    let cand = CGRect(
                        x: min(anchor.x, now.x),
                        y: min(anchor.y, now.y),
                        width: abs(now.x - anchor.x),
                        height: abs(now.y - anchor.y)
                    )
                    let aspectedRect: CGRect
                    if let a = aspect {
                        aspectedRect = CropMath.applyAspect(candidate: cand, anchor: anchor, aspect: a)
                    } else {
                        aspectedRect = cand
                    }
                    controller.setRect(CropMath.clip(snap(aspectedRect), to: controller.activeImageSize))
                case .moving:
                    if let r = existing, let off = controller.moveAnchor {
                        let dx = now.x - off.x - r.minX
                        let dy = now.y - off.y - r.minY
                        controller.setRect(CropMath.move(rect: r, by: CGSize(width: dx, height: dy), imageSize: controller.activeImageSize))
                    }
                case .resizing:
                    if let r = existing, let h = controller.activeHandle {
                        let next = CropMath.resize(
                            rect: r,
                            handle: h,
                            to: now,
                            imageSize: controller.activeImageSize,
                            centered: option,
                            aspect: aspect
                        )
                        controller.setRect(snap(next))
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                controller.dragState = .idle
                controller.activeHandle = nil
                controller.drawAnchor = nil
                controller.moveAnchor = nil
            }
    }

    private func snap(_ r: CGRect) -> CGRect {
        controller.snapToGrid ? CropMath.snapToIntegerPixels(r) : r
    }
}
