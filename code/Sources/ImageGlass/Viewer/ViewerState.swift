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
    /// transparent_bk_checkers.mdx §2.5 / §8 — when true, the canvas
    /// paints a two-tone gray checker grid behind the image so that
    /// alpha-channel transparency and aspect-fit margins are
    /// visually distinguishable from a flat painted backdrop.
    public var showTransparencyChecker: Bool = true

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

    // Zoom to Width: set true to request the next display pass to snap
    // panOffset so the top of the image is at the top of the viewport.
    // The canvas (which knows the viewport size) consumes and clears it.
    // hotkeys.mdx §6.1.
    public var pendingScrollToTop: Bool = false

    /// Per-key pan request. The canvas reads & clears this on the next
    /// display pass. Units are *fractions of the viewport on the
    /// requested axis* (so `.height = 0.15` means "pan down by 15% of the
    /// viewport height"). Multiple presses arriving in the same frame
    /// accumulate. hotkeys.mdx §4.3.
    public var pendingPanFraction: CGSize = .zero

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
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "resetView")])
        defer { _trace.finish() }
        panOffset = .zero
        lockedZoom = 1.0
        rotationQuarterTurns = 0
        flipHorizontal = false
        flipVertical = false
    }

    public func rotateClockwise() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "rotateClockwise")])
        defer { _trace.finish() }
        rotationQuarterTurns = (rotationQuarterTurns + 1) & 3
    }

    public func rotateCounterClockwise() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "rotateCounterClockwise")])
        defer { _trace.finish() }
        rotationQuarterTurns = (rotationQuarterTurns + 3) & 3
    }

    public func toggleFlipHorizontal() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "toggleFlipHorizontal")])
        defer { _trace.finish() }
        flipHorizontal.toggle()
    }
    public func toggleFlipVertical() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "toggleFlipVertical")])
        defer { _trace.finish() }
        flipVertical.toggle()
    }

    /// Multiplicative zoom step for ⌘+/⌘- and the bare `+` / `-` keys.
    /// hotkeys.mdx §5 — "by about 20%". The actual percent is read from
    /// `Settings.viewer.zoom_step_percent` at the call site; this constant
    /// is just the spec default used when nothing supplies one.
    /// `nonisolated` so the default-argument expression on `zoomIn` /
    /// `zoomOut` doesn't trip Swift 6 actor isolation.
    public nonisolated static let defaultZoomStepPercent: Double = 20

    /// UserDefaults key — hotkeys.mdx §6.5. Updated on every zoomMode
    /// helper call so a Settings ▸ Viewer ▸ *Default zoom on open* =
    /// *Restore last mode* can pick up where the user left off.
    public nonisolated static let lastZoomModeKey = "ig.viewer.last_zoom_mode"

    private func persistMode(_ mode: ZoomMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastZoomModeKey)
    }

    public func zoomIn(stepPercent: Double = ViewerState.defaultZoomStepPercent) {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "zoomIn")])
        defer { _trace.finish() }
        let mul = 1.0 + max(stepPercent, 1) / 100
        lockedZoom = ZoomMath.clamp(lockedZoom * CGFloat(mul))
        zoomMode = .lock
        persistMode(.lock)
    }
    public func zoomOut(stepPercent: Double = ViewerState.defaultZoomStepPercent) {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "zoomOut")])
        defer { _trace.finish() }
        let mul = 1.0 + max(stepPercent, 1) / 100
        lockedZoom = ZoomMath.clamp(lockedZoom / CGFloat(mul))
        zoomMode = .lock
        persistMode(.lock)
    }
    public func zoomToActual() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "zoomToActual")])
        defer { _trace.finish() }
        lockedZoom = 1.0; zoomMode = .lock; panOffset = .zero
        persistMode(.lock)
    }

    /// `Z` — fit the whole image, recentered.
    public func zoomToFit() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "zoomToFit")])
        defer { _trace.finish() }
        zoomMode = .fit
        panOffset = .zero
        pendingScrollToTop = false
        persistMode(.fit)
    }

    /// `W` — Zoom to Width: image width fills viewport width, scrolled to top.
    /// The actual top-align happens in the canvas on the next display pass
    /// (it owns viewport size). hotkeys.mdx §6.1.
    public func zoomToWidth() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "zoomToWidth")])
        defer { _trace.finish() }
        zoomMode = .width
        panOffset = .zero
        pendingScrollToTop = true
        persistMode(.width)
    }

    /// `C` — recenter the image without changing the zoom factor. Pan offset
    /// = .zero is the centered position; zoomMode is preserved. hotkeys.mdx §5.
    public func centerImage() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "centerImage")])
        defer { _trace.finish() }
        panOffset = .zero
        pendingScrollToTop = false
    }

    /// `N` — normalize to the user's preferred default. The caller supplies
    /// which mode to snap to from `Settings.viewer.default_zoom_on_open`;
    /// `.restoreLast` reads the persisted last mode. hotkeys.mdx §5 / §9.
    public func normalizeZoom(
        mode: DefaultZoomOnOpen = .fit,
        lastMode: ZoomMode? = nil
    ) {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "normalizeZoom")])
        defer { _trace.finish() }
        switch mode {
        case .fit:    zoomToFit()
        case .actual: zoomToActual()
        case .restoreLast:
            switch lastMode {
            case .width:  zoomToWidth()
            case .lock:   zoomToActual()  // `lock` carries the user's manual factor; snap to 100%.
            case .height: zoomMode = .height; panOffset = .zero; persistMode(.height)
            case .auto:   zoomMode = .auto;   panOffset = .zero; persistMode(.auto)
            case .fill:   zoomMode = .fill;   panOffset = .zero; persistMode(.fill)
            case .fit, .none:
                zoomToFit()
            }
        }
    }

    /// Request a viewport pan by `dx` / `dy` *fractions* of the viewport.
    /// The canvas converts the fraction into points using its own bounds
    /// on the next display pass. hotkeys.mdx §4.3.
    public func requestPan(dx: CGFloat, dy: CGFloat) {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "requestPan")])
        defer { _trace.finish() }
        pendingPanFraction = CGSize(
            width:  pendingPanFraction.width  + dx,
            height: pendingPanFraction.height + dy
        )
    }

    // Frame navigation (multi-frame stills + paused animations).
    public func nextFrame() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "nextFrame")])
        defer { _trace.finish() }
        guard frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex + 1) % frameCount
    }
    public func previousFrame() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "previousFrame")])
        defer { _trace.finish() }
        guard frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex - 1 + frameCount) % frameCount
    }
    public func toggleAnimationPaused() {
        let _trace = PerformanceLog.shared.start("Viewer.StateUpdate", extra: [("op", "toggleAnimationPaused")])
        defer { _trace.finish() }
        isAnimationPaused.toggle()
    }
}
