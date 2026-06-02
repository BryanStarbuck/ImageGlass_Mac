import SwiftUI
import AppKit
import ImageGlassCore

/// Hosts the active image plus the Crop overlay. Drawn in SwiftUI for
/// simplicity — the spec calls for a Metal pass inside the existing
/// `MTKView` (see `docs/crop.mdx` section 2.2), but until the
/// Metal-backed `ImageCanvasView` lands we use a SwiftUI `Canvas` overlay
/// on top of an `NSImageView`. The behavior is the same to the user; the
/// renderer can be swapped without touching `CropController`.
public struct CropOverlayHost: View {
    @Bindable public var controller: CropController

    public init(controller: CropController) {
        self.controller = controller
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                ImageBackground(path: controller.imagePath)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CropOverlayLayer(
                    controller: controller,
                    canvasSize: geo.size
                )
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Image background

private struct ImageBackground: NSViewRepresentable {
    let path: String?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.animates = false
        view.allowsCutCopyPaste = false
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if let path, !path.isEmpty {
            nsView.image = NSImage(contentsOfFile: AppPaths.expandTilde(path))
        } else {
            nsView.image = nil
        }
    }
}

// MARK: - Overlay layer

/// Draws the dim mask, selection rectangle, grid, handles, and W×H label.
/// Mouse drags are forwarded to the `CropController` state machine.
private struct CropOverlayLayer: View {
    @Bindable var controller: CropController
    let canvasSize: CGSize

    @State private var dragStartImage: CGPoint?
    @State private var dragStartSelection: CropRect?
    @State private var dragResizer: SelectionResizer.Kind?

    var body: some View {
        Canvas { ctx, _ in
            guard let mapping = imageToClient(), controller.sourceWidth > 0 else { return }
            drawDim(ctx: ctx, mapping: mapping)
            drawSelectionFrame(ctx: ctx, mapping: mapping)
            drawMCURounded(ctx: ctx, mapping: mapping)
            drawGrid(ctx: ctx, mapping: mapping)
            drawHandles(ctx: ctx, mapping: mapping)
            drawSizeLabel(ctx: ctx, mapping: mapping)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onAppear { controller.publishLiveSelection() }
    }

    // MARK: Drag handling

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let mapping = imageToClient(), controller.sourceWidth > 0 else { return }
                let imagePoint = clientToImage(value.location, mapping: mapping)
                if dragStartImage == nil {
                    let startImage = clientToImage(value.startLocation, mapping: mapping)
                    dragStartImage = startImage
                    dragStartSelection = controller.selection
                    // Decide drag mode based on the start location.
                    if let resizer = hitResizer(at: value.startLocation, mapping: mapping) {
                        controller.action = .resizing(resizer)
                        dragResizer = resizer
                    } else if let sel = controller.selection,
                              clientRect(for: sel, mapping: mapping).contains(value.startLocation) {
                        controller.action = .moving
                    } else {
                        controller.beginDraw(at: startImage)
                    }
                }
                switch controller.action {
                case .drawing:
                    if let start = dragStartImage {
                        controller.updateDraw(from: start, to: imagePoint)
                    }
                case .moving:
                    if let baseline = dragStartSelection, let start = dragStartImage {
                        var moved = baseline
                        moved.x = baseline.x + Int(imagePoint.x - start.x)
                        moved.y = baseline.y + Int(imagePoint.y - start.y)
                        controller.setSelection(moved)
                    }
                case .resizing(let kind):
                    if let baseline = dragStartSelection, let start = dragStartImage {
                        let dx = Int(imagePoint.x - start.x)
                        let dy = Int(imagePoint.y - start.y)
                        var r = baseline
                        switch kind {
                        case .topLeft:
                            r.x += dx; r.y += dy
                            r.width -= dx; r.height -= dy
                        case .top:
                            r.y += dy; r.height -= dy
                        case .topRight:
                            r.y += dy; r.width += dx; r.height -= dy
                        case .right:
                            r.width += dx
                        case .bottomRight:
                            r.width += dx; r.height += dy
                        case .bottom:
                            r.height += dy
                        case .bottomLeft:
                            r.x += dx; r.width -= dx; r.height += dy
                        case .left:
                            r.x += dx; r.width -= dx
                        }
                        if r.width < 1 { r.width = 1 }
                        if r.height < 1 { r.height = 1 }
                        if controller.lockAspect, let ratio = controller.effectiveRatio() {
                            let locked = CropMath.lockRatio(width: r.width, height: r.height, ratioW: ratio.w, ratioH: ratio.h)
                            r.width = locked.w
                            r.height = locked.h
                        }
                        controller.setSelection(r)
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                controller.endDrag()
                dragStartImage = nil
                dragStartSelection = nil
                dragResizer = nil
            }
    }

    // MARK: Coordinate mapping

    /// Mapping between source-image coords and client (canvas) coords.
    private struct Mapping {
        let scale: CGFloat
        let imageRectInClient: CGRect   // the actual displayed image rect
    }

    private func imageToClient() -> Mapping? {
        guard controller.sourceWidth > 0, controller.sourceHeight > 0 else { return nil }
        let iw = CGFloat(controller.sourceWidth)
        let ih = CGFloat(controller.sourceHeight)
        let cw = canvasSize.width
        let ch = canvasSize.height
        if cw <= 0 || ch <= 0 { return nil }
        let scale = min(cw / iw, ch / ih)
        let drawnW = iw * scale
        let drawnH = ih * scale
        let originX = (cw - drawnW) / 2
        let originY = (ch - drawnH) / 2
        return Mapping(
            scale: scale,
            imageRectInClient: CGRect(x: originX, y: originY, width: drawnW, height: drawnH)
        )
    }

    private func clientToImage(_ point: CGPoint, mapping: Mapping) -> CGPoint {
        let local = CGPoint(
            x: point.x - mapping.imageRectInClient.origin.x,
            y: point.y - mapping.imageRectInClient.origin.y
        )
        return CGPoint(x: local.x / mapping.scale, y: local.y / mapping.scale)
    }

    private func clientRect(for rect: CropRect, mapping: Mapping) -> CGRect {
        let s = mapping.scale
        return CGRect(
            x: mapping.imageRectInClient.origin.x + CGFloat(rect.x) * s,
            y: mapping.imageRectInClient.origin.y + CGFloat(rect.y) * s,
            width: CGFloat(rect.width) * s,
            height: CGFloat(rect.height) * s
        )
    }

    private func hitResizer(at point: CGPoint, mapping: Mapping) -> SelectionResizer.Kind? {
        guard let sel = controller.selection else { return nil }
        let rect = clientRect(for: sel, mapping: mapping)
        let resizers = SelectionResizer.eight(around: rect)
        return SelectionResizer.hitTest(resizers, at: point)?.kind
    }

    // MARK: Drawing

    private func drawDim(ctx: GraphicsContext, mapping: Mapping) {
        let alpha = controller.action == .none ? 0.45 : 0.25
        let outer = mapping.imageRectInClient
        guard let sel = controller.selection else {
            ctx.fill(Path(outer), with: .color(.black.opacity(alpha)))
            return
        }
        let inner = clientRect(for: sel, mapping: mapping).intersection(outer)
        // Use even-odd fill to punch out the inner rect.
        var p = Path()
        p.addRect(outer)
        p.addRect(inner)
        ctx.fill(p, with: .color(.black.opacity(alpha)), style: FillStyle(eoFill: true))
    }

    private func drawSelectionFrame(ctx: GraphicsContext, mapping: Mapping) {
        guard let sel = controller.selection else { return }
        let rect = clientRect(for: sel, mapping: mapping)
        // 1pt white underlay for contrast, 1pt accent overlay.
        ctx.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
        ctx.stroke(Path(rect), with: .color(Color(NSColor.controlAccentColor)), lineWidth: 1.0)
    }

    private func drawMCURounded(ctx: GraphicsContext, mapping: Mapping) {
        guard let r = controller.mcuRoundedOutline else { return }
        let rect = clientRect(for: r, mapping: mapping)
        let dashStyle = StrokeStyle(lineWidth: 1.0, dash: [4, 3])
        ctx.stroke(Path(rect), with: .color(Color(NSColor.systemYellow)), style: dashStyle)
    }

    private func drawGrid(ctx: GraphicsContext, mapping: Mapping) {
        guard let sel = controller.selection else { return }
        let rect = clientRect(for: sel, mapping: mapping)
        let stroke = StrokeStyle(lineWidth: 0.75)
        switch controller.gridMode {
        case .none:
            return
        case .thirds:
            drawDividers(ctx: ctx, in: rect, vFractions: [1.0/3, 2.0/3], hFractions: [1.0/3, 2.0/3], style: stroke)
        case .goldenRatio:
            drawDividers(ctx: ctx, in: rect, vFractions: [0.382, 0.618], hFractions: [0.382, 0.618], style: stroke)
        case .diagonals:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            ctx.stroke(path, with: .color(.white.opacity(0.6)), style: stroke)
        case .grid8:
            let v = stride(from: 1, to: 8, by: 1).map { CGFloat($0) / 8.0 }
            drawDividers(ctx: ctx, in: rect, vFractions: v, hFractions: v, style: stroke)
        }
    }

    private func drawDividers(ctx: GraphicsContext, in rect: CGRect, vFractions: [CGFloat], hFractions: [CGFloat], style: StrokeStyle) {
        var p = Path()
        for vf in vFractions {
            let x = rect.minX + rect.width * vf
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for hf in hFractions {
            let y = rect.minY + rect.height * hf
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.stroke(p, with: .color(.white.opacity(0.55)), style: style)
    }

    private func drawHandles(ctx: GraphicsContext, mapping: Mapping) {
        guard let sel = controller.selection else { return }
        let rect = clientRect(for: sel, mapping: mapping)
        let resizers = SelectionResizer.eight(around: rect)
        for r in resizers {
            ctx.fill(Path(ellipseIn: r.indicatorRect), with: .color(.white))
            ctx.stroke(Path(ellipseIn: r.indicatorRect),
                       with: .color(Color(NSColor.controlAccentColor)),
                       lineWidth: 1.0)
        }
    }

    private func drawSizeLabel(ctx: GraphicsContext, mapping: Mapping) {
        guard let sel = controller.selection else { return }
        let rect = clientRect(for: sel, mapping: mapping)
        let text = "\(sel.width) × \(sel.height)"
        let textView = Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
        let resolved = ctx.resolve(textView)
        let size = resolved.measure(in: rect.size)
        // Upstream room-check: only draw when the label fits comfortably.
        guard size.width + 10 < rect.width, size.height + 10 < rect.height else { return }
        let bg = CGRect(
            x: rect.midX - size.width / 2 - 6,
            y: rect.midY - size.height / 2 - 3,
            width: size.width + 12,
            height: size.height + 6
        )
        ctx.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(.black.opacity(0.6)))
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}
