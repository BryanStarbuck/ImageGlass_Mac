import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageGlassCore

/// Custom AppKit view that draws the current image with full control:
/// pan, zoom (mouse-wheel + pinch), rotation, flip, interpolation toggle,
/// color-channel isolation, and color-picker readout.
///
/// All state lives in `ViewerState`. The hosting SwiftUI representable wires
/// callbacks that read/write that observable.
final class ImageCanvasView: NSView {

    // Inputs
    private(set) var sourceImage: NSImage?
    private(set) var sourceCGImage: CGImage?
    private(set) var frameSource: FrameSource?
    private var filteredImage: CGImage?

    // Cached for color-picker readouts. May differ from `sourceCGImage` only
    // by colorspace conversion (Generic RGB so RGBA sampling is meaningful).
    private var samplingImage: CGImage?

    // Animation playback
    private var animationTimer: Timer?

    // Live tunables
    var zoomMode: ZoomMode = .auto    { didSet { needsDisplay = true } }
    var lockedZoom: CGFloat = 1.0     { didSet { needsDisplay = true } }
    var panOffset: CGSize = .zero     { didSet { needsDisplay = true } }
    var rotationQuarterTurns: Int = 0 { didSet { needsDisplay = true } }
    var flipHorizontal: Bool = false  { didSet { needsDisplay = true } }
    var flipVertical: Bool = false    { didSet { needsDisplay = true } }
    var smoothInterpolation: Bool = true { didSet { needsDisplay = true } }
    var colorChannel: ColorChannel = .all { didSet { rebuildFilteredImage(); needsDisplay = true } }
    var showColorPicker: Bool = false { didSet { needsDisplay = true } }
    var currentFrameIndex: Int = 0 {
        didSet {
            guard oldValue != currentFrameIndex else { return }
            applyFrame()
        }
    }
    var isAnimationPaused: Bool = false {
        didSet {
            guard oldValue != isAnimationPaused else { return }
            isAnimationPaused ? stopAnimationTimer() : startAnimationTimerIfNeeded()
        }
    }

    // Callbacks
    /// Called whenever pan, lockedZoom, or zoomMode changes from user input.
    var onUserTransform: ((CGSize, CGFloat, ZoomMode) -> Void)?
    /// Called when the cursor hovers a pixel inside the image while picker is on.
    var onHover: ((CGPoint?, RGBA?) -> Void)?
    /// Called after a new image is loaded so the host can read frame metadata.
    var onFrameSourceChanged: ((FrameSource?) -> Void)?
    /// Called when the animation timer advances the current frame on its own.
    var onFrameAdvanced: ((Int) -> Void)?

    // CIContext is heavyweight — cache it.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var trackingArea: NSTrackingArea?
    private var lastDragLocation: NSPoint = .zero

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func setImage(path: String?) {
        stopAnimationTimer()
        guard let path else {
            sourceImage = nil
            sourceCGImage = nil
            frameSource = nil
            samplingImage = nil
            filteredImage = nil
            needsDisplay = true
            onFrameSourceChanged?(nil)
            return
        }
        let url = URL(fileURLWithPath: path)
        let fs = FrameSource.load(url: url)
        frameSource = fs
        // Fallback: still render with NSImage for tooltip/sourceImage parity.
        sourceImage = NSImage(contentsOfFile: path)
        currentFrameIndex = 0
        applyFrame()
        panOffset = .zero
        onFrameSourceChanged?(fs)
        startAnimationTimerIfNeeded()
        needsDisplay = true
    }

    /// Pull the current frame's CGImage out of `frameSource` and refresh
    /// the sampling + filtered images. Called on load and on frame changes.
    private func applyFrame() {
        guard let fs = frameSource, !fs.frames.isEmpty else {
            sourceCGImage = nil
            samplingImage = nil
            filteredImage = nil
            needsDisplay = true
            return
        }
        let idx = max(0, min(currentFrameIndex, fs.frameCount - 1))
        sourceCGImage = fs.frames[idx].cgImage
        samplingImage = makeRGBA8(sourceCGImage)
        rebuildFilteredImage()
        needsDisplay = true
    }

    private func startAnimationTimerIfNeeded() {
        stopAnimationTimer()
        guard let fs = frameSource, fs.isAnimated, !isAnimationPaused,
              fs.frames.count > 1 else { return }
        scheduleNextAnimationTick()
    }

    private func scheduleNextAnimationTick() {
        guard let fs = frameSource, fs.isAnimated else { return }
        let idx = max(0, min(currentFrameIndex, fs.frameCount - 1))
        let delay = max(0.02, fs.frames[idx].delay) // clamp absurdly fast GIFs
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let next = (self.currentFrameIndex + 1) % (self.frameSource?.frameCount ?? 1)
            self.currentFrameIndex = next
            self.onFrameAdvanced?(next)
            self.scheduleNextAnimationTick()
        }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func rebuildFilteredImage() {
        guard let cg = sourceCGImage else {
            filteredImage = nil
            return
        }
        if colorChannel == .all {
            filteredImage = cg
            return
        }
        let ci = CIImage(cgImage: cg)
        let m = ColorChannelMath.ciColorMatrix(colorChannel)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = ci
        filter.rVector = CIVector(x: m.rVec.0, y: m.rVec.1, z: m.rVec.2, w: m.rVec.3)
        filter.gVector = CIVector(x: m.gVec.0, y: m.gVec.1, z: m.gVec.2, w: m.gVec.3)
        filter.bVector = CIVector(x: m.bVec.0, y: m.bVec.1, z: m.bVec.2, w: m.bVec.3)
        filter.aVector = CIVector(x: m.aVec.0, y: m.aVec.1, z: m.aVec.2, w: m.aVec.3)
        filter.biasVector = CIVector(x: m.bias.0, y: m.bias.1, z: m.bias.2, w: m.bias.3)
        guard let out = filter.outputImage,
              let result = ciContext.createCGImage(out, from: out.extent)
        else {
            filteredImage = cg
            return
        }
        filteredImage = result
    }

    var imageSize: CGSize {
        sourceCGImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    /// Logical (post-rotation) image size — what gets fitted into the viewport.
    private var rotatedImageSize: CGSize {
        let s = imageSize
        return (rotationQuarterTurns % 2 == 0) ? s : CGSize(width: s.height, height: s.width)
    }

    private var currentScale: CGFloat {
        ZoomMath.scale(
            for: zoomMode,
            imageSize: rotatedImageSize,
            viewportSize: bounds.size,
            lockedZoom: lockedZoom
        )
    }

    private var displayRect: CGRect {
        ZoomMath.displayRect(
            imageSize: rotatedImageSize,
            viewportSize: bounds.size,
            scale: currentScale,
            panOffset: panOffset
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        guard let cg = filteredImage else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.interpolationQuality = smoothInterpolation ? .high : .none

        let rect = displayRect
        let cx = rect.midX
        let cy = rect.midY
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: -CGFloat(rotationQuarterTurns) * (.pi / 2))
        ctx.scaleBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)

        let drawWidth: CGFloat
        let drawHeight: CGFloat
        if rotationQuarterTurns % 2 == 0 {
            drawWidth = rect.width
            drawHeight = rect.height
        } else {
            drawWidth = rect.height
            drawHeight = rect.width
        }
        let drawRect = CGRect(
            x: -drawWidth / 2,
            y: -drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )
        ctx.draw(cg, in: drawRect)
        ctx.restoreGState()
    }

    override func scrollWheel(with event: NSEvent) {
        // Pinch-zoom on trackpads delivers magnification events instead, but
        // Option+scroll and traditional mouse-wheel come through here.
        if event.modifierFlags.contains(.option) || event.subtype == .mouseEvent {
            let focal = convert(event.locationInWindow, from: nil)
            let multiplier: CGFloat = event.deltaY > 0 ? 1.08 : (event.deltaY < 0 ? 1/1.08 : 1.0)
            applyZoom(multiplier: multiplier, focal: focal)
        } else {
            panOffset = CGSize(
                width: panOffset.width + event.scrollingDeltaX,
                height: panOffset.height - event.scrollingDeltaY
            )
            onUserTransform?(panOffset, lockedZoom, zoomMode)
        }
    }

    override func magnify(with event: NSEvent) {
        let focal = convert(event.locationInWindow, from: nil)
        applyZoom(multiplier: 1 + event.magnification, focal: focal)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - lastDragLocation.x
        let dy = p.y - lastDragLocation.y
        lastDragLocation = p
        panOffset = CGSize(width: panOffset.width + dx, height: panOffset.height + dy)
        onUserTransform?(panOffset, lockedZoom, zoomMode)
    }

    override func mouseMoved(with event: NSEvent) {
        guard showColorPicker else {
            onHover?(nil, nil)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let pixel = imagePixel(at: p), let color = readColor(at: pixel) {
            onHover?(pixel, color)
        } else {
            onHover?(nil, nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil, nil)
    }

    private func applyZoom(multiplier: CGFloat, focal: CGPoint) {
        let result = ZoomMath.zoom(
            currentScale: currentScale,
            currentPan: panOffset,
            viewportSize: bounds.size,
            focal: focal,
            multiplier: multiplier
        )
        // Switching to Lock so the user's zoom is preserved across redraws.
        zoomMode = .lock
        lockedZoom = result.scale
        panOffset = result.pan
        onUserTransform?(panOffset, lockedZoom, zoomMode)
    }

    /// Convert a viewport point to a (logical, pre-rotation) image pixel.
    private func imagePixel(at viewportPoint: CGPoint) -> CGPoint? {
        let rect = displayRect
        guard rect.contains(viewportPoint), currentScale > 0 else { return nil }

        // Point within the displayed (rotated) rect, normalized 0..1.
        var u = (viewportPoint.x - rect.minX) / rect.width
        var v = 1 - (viewportPoint.y - rect.minY) / rect.height  // flip Y to image-space

        if flipHorizontal { u = 1 - u }
        if flipVertical   { v = 1 - v }

        let img = imageSize
        let (px, py): (CGFloat, CGFloat)
        switch rotationQuarterTurns & 3 {
        case 0: (px, py) = (u * img.width,       v * img.height)
        case 1: (px, py) = (v * img.width,       (1 - u) * img.height)
        case 2: (px, py) = ((1 - u) * img.width, (1 - v) * img.height)
        case 3: (px, py) = ((1 - v) * img.width, u * img.height)
        default: (px, py) = (0, 0)
        }
        return CGPoint(x: floor(px), y: floor(py))
    }

    private func readColor(at imagePixel: CGPoint) -> RGBA? {
        guard let s = samplingImage else { return nil }
        let w = s.width, h = s.height
        let x = Int(imagePixel.x), y = Int(imagePixel.y)
        guard x >= 0, y >= 0, x < w, y < h,
              let provider = s.dataProvider,
              let data = provider.data,
              let ptr = CFDataGetBytePtr(data)
        else { return nil }
        let bpr = s.bytesPerRow
        let bpp = s.bitsPerPixel / 8     // 4 for RGBA8
        let offset = y * bpr + x * bpp
        return RGBA(
            r: ptr[offset],
            g: ptr[offset + 1],
            b: ptr[offset + 2],
            a: bpp >= 4 ? ptr[offset + 3] : 255
        )
    }

    /// Re-render the source image into a deterministic RGBA8 buffer so we can
    /// sample pixel values regardless of the original colorspace / bit depth.
    private func makeRGBA8(_ cg: CGImage?) -> CGImage? {
        guard let cg else { return nil }
        let w = cg.width, h = cg.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: info
        ) else { return cg }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
