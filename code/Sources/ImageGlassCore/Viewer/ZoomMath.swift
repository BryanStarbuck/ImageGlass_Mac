import Foundation
import CoreGraphics

/// Pure-Swift geometry helpers for the six zoom modes.
/// Lives in ImageGlassCore so XCTest can exercise it without an AppKit window.
public enum ZoomMode: String, CaseIterable, Sendable, Codable {
    /// "Auto Zoom": fit the image into the viewport when the image is larger
    /// than the viewport; show at 100% otherwise. Never upscales above 1.0.
    case auto
    /// "Lock Zoom": keep the user's manual zoom factor across image changes.
    case lock
    /// "Scale to Width": fit width, allow vertical scroll/clip.
    case width
    /// "Scale to Height": fit height, allow horizontal scroll/clip.
    case height
    /// "Scale to Fit": fit the whole image (letterboxed if needed).
    case fit
    /// "Scale to Fill": fill the viewport (crop overflow).
    case fill

    public var label: String {
        switch self {
        case .auto:   return "Auto Zoom"
        case .lock:   return "Lock Zoom"
        case .width:  return "Scale to Width"
        case .height: return "Scale to Height"
        case .fit:    return "Scale to Fit"
        case .fill:   return "Scale to Fill"
        }
    }
}

/// Hard limits for the user-driven zoom factor (mouse-wheel / pinch).
public enum ZoomLimits {
    public static let min: CGFloat = 0.05
    public static let max: CGFloat = 40.0
}

public enum ZoomMath {

    /// Returns the scale factor (image-pixel -> view-point) for a given mode.
    /// `lockedZoom` is used when `mode == .lock`.
    public static func scale(
        for mode: ZoomMode,
        imageSize: CGSize,
        viewportSize: CGSize,
        lockedZoom: CGFloat
    ) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0
        else { return 1.0 }

        let widthRatio  = viewportSize.width  / imageSize.width
        let heightRatio = viewportSize.height / imageSize.height

        switch mode {
        case .lock:
            return clamp(lockedZoom)
        case .width:
            return clamp(widthRatio)
        case .height:
            return clamp(heightRatio)
        case .fit:
            return clamp(min(widthRatio, heightRatio))
        case .fill:
            return clamp(max(widthRatio, heightRatio))
        case .auto:
            // 100% unless the image overflows the viewport in either axis.
            if imageSize.width <= viewportSize.width &&
               imageSize.height <= viewportSize.height {
                return 1.0
            }
            return clamp(min(widthRatio, heightRatio))
        }
    }

    /// Centered rect for `imageSize` rendered at `scale` inside `viewportSize`,
    /// then translated by `panOffset`. Pure geometry — no AppKit.
    public static func displayRect(
        imageSize: CGSize,
        viewportSize: CGSize,
        scale: CGFloat,
        panOffset: CGSize
    ) -> CGRect {
        let drawnWidth  = imageSize.width  * scale
        let drawnHeight = imageSize.height * scale
        let originX = (viewportSize.width  - drawnWidth)  / 2 + panOffset.width
        let originY = (viewportSize.height - drawnHeight) / 2 + panOffset.height
        return CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight)
    }

    /// Apply a zoom delta around a focal point in viewport coordinates,
    /// returning the new zoom factor and the adjusted pan offset so the
    /// pixel under the cursor stays under the cursor.
    public static func zoom(
        currentScale: CGFloat,
        currentPan: CGSize,
        viewportSize: CGSize,
        focal: CGPoint,
        multiplier: CGFloat
    ) -> (scale: CGFloat, pan: CGSize) {
        let newScale = clamp(currentScale * multiplier)
        guard newScale != currentScale else { return (currentScale, currentPan) }
        let ratio = newScale / currentScale
        // Translate pan so the focal viewport-point maps to the same image-point.
        let cx = viewportSize.width  / 2 + currentPan.width
        let cy = viewportSize.height / 2 + currentPan.height
        let dx = (focal.x - cx) * (1 - ratio)
        let dy = (focal.y - cy) * (1 - ratio)
        return (newScale, CGSize(width: currentPan.width + dx,
                                 height: currentPan.height + dy))
    }

    @inline(__always)
    public static func clamp(_ s: CGFloat) -> CGFloat {
        min(max(s, ZoomLimits.min), ZoomLimits.max)
    }
}
