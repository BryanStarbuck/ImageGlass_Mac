import Foundation
import Observation
import CoreGraphics
import ImageGlassCore

/// All per-window viewer state. Held by `AppState` for the main window;
/// the slideshow / full-screen windows get their own instance.
@MainActor
@Observable
public final class ViewerState {
    // Zoom & pan
    public var zoomMode: ZoomMode = .auto
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

    // Window modes
    public var isFullScreen: Bool = false
    public var isFrameless: Bool = false
    public var windowFitMode: Bool = false

    // Slideshow
    public var slideshowSeconds: Double = 4.0
    public var isSlideshowRunning: Bool = false

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
}
