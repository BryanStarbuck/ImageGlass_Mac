import Foundation

/// Multi-monitor window state persisted in `settings.json` under `window`.
/// Spec: `docs/multi_monitor.mdx` §3.
///
/// Every field is optional/falsey by default so a fresh install writes
/// nothing into the section until the first quit. The display is
/// identified by its CoreGraphics UUID (stable across reboots, unplug,
/// and display rearrangement) and the frame is recorded in coordinates
/// *local* to that display so the saved record stays valid when the
/// user rearranges monitors in System Settings.
public struct WindowSettings: Codable, Equatable, Sendable {
    public var display_id: String?
    public var display_name: String?
    public var frame: WindowFrame?
    public var fullscreen: Bool
    public var zoomed: Bool
    public var minimized: Bool
    public var last_selected_file: String?
    public var saved_at: String?

    public init(
        display_id: String? = nil,
        display_name: String? = nil,
        frame: WindowFrame? = nil,
        fullscreen: Bool = false,
        zoomed: Bool = false,
        minimized: Bool = false,
        last_selected_file: String? = nil,
        saved_at: String? = nil
    ) {
        self.display_id = display_id
        self.display_name = display_name
        self.frame = frame
        self.fullscreen = fullscreen
        self.zoomed = zoomed
        self.minimized = minimized
        self.last_selected_file = last_selected_file
        self.saved_at = saved_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowSettings()
        display_id         = try c.decodeIfPresent(String.self,        forKey: .display_id)         ?? d.display_id
        display_name       = try c.decodeIfPresent(String.self,        forKey: .display_name)       ?? d.display_name
        frame              = try c.decodeIfPresent(WindowFrame.self,   forKey: .frame)              ?? d.frame
        fullscreen         = try c.decodeIfPresent(Bool.self,          forKey: .fullscreen)         ?? d.fullscreen
        zoomed             = try c.decodeIfPresent(Bool.self,          forKey: .zoomed)             ?? d.zoomed
        minimized          = try c.decodeIfPresent(Bool.self,          forKey: .minimized)          ?? d.minimized
        last_selected_file = try c.decodeIfPresent(String.self,        forKey: .last_selected_file) ?? d.last_selected_file
        saved_at           = try c.decodeIfPresent(String.self,        forKey: .saved_at)           ?? d.saved_at
    }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - Pure math helpers (no AppKit dependency)
//
// Kept in Core so they can be unit-tested without an AppKit screen and so
// the MCP layer can reason about frames without dragging AppKit into its
// dependency graph.

public enum WindowGeometry {

    /// Local frame = global frame − display origin. Spec §4.2.
    public static func displayLocal(globalX: Double, globalY: Double,
                                    displayOriginX: Double, displayOriginY: Double,
                                    width: Double, height: Double) -> WindowFrame {
        WindowFrame(
            x: globalX - displayOriginX,
            y: globalY - displayOriginY,
            width: width, height: height
        )
    }

    /// Inverse of `displayLocal`. Spec §4.2.
    public static func absolute(local: WindowFrame,
                                displayOriginX: Double, displayOriginY: Double)
    -> (x: Double, y: Double, width: Double, height: Double) {
        (
            x: displayOriginX + local.x,
            y: displayOriginY + local.y,
            width: local.width, height: local.height
        )
    }

    /// Clamp a candidate frame into the visible rect of its display.
    /// Spec §4.4. Pure function; takes the visible rect as four scalars
    /// so it can run without AppKit.
    public static func clamp(x: Double, y: Double, width: Double, height: Double,
                             visibleMinX: Double, visibleMinY: Double,
                             visibleMaxX: Double, visibleMaxY: Double)
    -> (x: Double, y: Double, width: Double, height: Double) {
        let visibleW = max(0, visibleMaxX - visibleMinX)
        let visibleH = max(0, visibleMaxY - visibleMinY)
        let w = min(width,  visibleW)
        let h = min(height, visibleH)
        let cx = min(max(x, visibleMinX), max(visibleMinX, visibleMaxX - w))
        let cy = min(max(y, visibleMinY), max(visibleMinY, visibleMaxY - h))
        return (cx, cy, w, h)
    }
}
