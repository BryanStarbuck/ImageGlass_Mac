import Foundation
import Observation
import CoreGraphics
import ImageGlassCore

/// All per-window viewer state. Held by `AppState` for the main window;
/// the slideshow / full-screen windows get their own instance.
@MainActor
@Observable
public final class ViewerState {
    // Zoom & pan.
    // Default is `.fit` (not `.auto`): every newly loaded image is
    // scaled along its most-constraining axis to fill the viewport
    // while preserving aspect ratio and staying centered. `.auto`
    // would leave small images at 100%, which presents as "cyan
    // letterbox bars with a tiny image lost in the middle." See
    // `ImageCanvasView.resetTransformForNewImage`.
    public var zoomMode: ZoomMode = .fit
    /// User-driven zoom factor — only consulted when `zoomMode == .lock`,
    /// but kept up-to-date for all modes so toggling into Lock is seamless.
    public var lockedZoom: CGFloat = 1.0
    public var panOffset: CGSize = .zero

    // Edits (non-destructive — view-only)
    public var rotationQuarterTurns: Int = 0   // 0,1,2,3
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false

    // Display options
    public var smoothInterpolation: Bool = true
    public var colorChannel: ColorChannel = .all

    // Overlays
    public var showInfoOverlay: Bool = false
    public var showColorPicker: Bool = false
    /// Display format for the color picker overlay (HEX, RGBA, HSL ...).
    public var colorFormat: ColorFormat = .hex

    // Window modes
    public var isFullScreen: Bool = false
    public var isFrameless: Bool = false
    public var windowFitMode: Bool = false

    // Slideshow
    public var slideshowSeconds: Double = 4.0
    public var isSlideshowRunning: Bool = false
    /// Seconds remaining until the next slide. Driven by the slideshow
    /// controller; observed by the countdown overlay.
    public var slideshowRemaining: Double = 0

    // Multi-frame / animation state. The canvas owns the actual frame
    // buffer; these fields drive the UI controls (Pause, Prev/Next Frame).
    public var frameCount: Int = 1
    public var currentFrameIndex: Int = 0
    public var isAnimated: Bool = false
    public var isAnimationPaused: Bool = false

    /// Non-nil when the selected file is set but couldn't be displayed
    /// (Git LFS placeholder, unreadable, corrupt/unsupported encoding).
    /// Drives the on-canvas error card so the user sees *why* instead of a
    /// blank gray canvas.
    public var loadError: String? = nil

    // Hover state for the color picker overlay (image-pixel coordinates).
    public var hoverPixel: CGPoint? = nil
    public var hoverColor: RGBA? = nil

    public init() {}

    public func resetView() {
        panOffset = .zero
        lockedZoom = 1.0
        rotationQuarterTurns = 0
        flipHorizontal = false
        flipVertical = false
    }

    public func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) & 3
    }

    public func rotateCounterClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 3) & 3
    }

    public func toggleFlipHorizontal() { flipHorizontal.toggle() }
    public func toggleFlipVertical()   { flipVertical.toggle() }

    public func zoomIn()  { lockedZoom = ZoomMath.clamp(lockedZoom * 1.25); zoomMode = .lock }
    public func zoomOut() { lockedZoom = ZoomMath.clamp(lockedZoom / 1.25); zoomMode = .lock }
    public func zoomToActual() { lockedZoom = 1.0; zoomMode = .lock; panOffset = .zero }

    // Frame navigation (multi-frame stills + paused animations).
    public func nextFrame() {
        guard frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex + 1) % frameCount
    }
    public func previousFrame() {
        guard frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex - 1 + frameCount) % frameCount
    }
    public func toggleAnimationPaused() { isAnimationPaused.toggle() }
}
