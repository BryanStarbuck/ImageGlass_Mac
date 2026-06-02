import Foundation
import CoreGraphics

/// Pure-logic helpers for the layout system. UI-independent so the same
/// math can be exercised by tests, by MCP, and by the SwiftUI host.
///
/// The spec gives this actor the name "LayoutDirector"; we keep the name
/// but expose only static functions because there is no mutable state — the
/// real mutable state lives in `PanelRegistry`.
public enum LayoutDirector {

    // MARK: - Preset → instance states

    /// Computes the `PanelInstanceState` map a registry should hold after a
    /// preset is applied. Panels not mentioned in the preset are returned
    /// with `visible: false, position: .hidden` so the renderer hides them.
    ///
    /// `registered` is the set of currently-registered panel ids. Slots in
    /// the preset that reference unknown panels are silently skipped — the
    /// spec calls this forward-compatibility: a layout written by a newer
    /// install with extra panels still loads on an older install.
    public static func instanceStates(
        for preset: LayoutPreset,
        registered: Set<String>
    ) -> [PanelInstanceState] {
        var out: [String: PanelInstanceState] = [:]

        // Seed every registered panel as hidden.
        for id in registered {
            out[id] = PanelInstanceState(
                id: id,
                visible: false,
                position: .hidden,
                lastDockedPosition: nil,
                size: 1.0,
                collapsed: false
            )
        }

        guard let window = preset.windows.first else {
            return Array(out.values)
        }

        func applyZone(_ zone: LayoutZone, position: PanelPosition) {
            for slot in zone.panels where registered.contains(slot.id) {
                out[slot.id] = PanelInstanceState(
                    id: slot.id,
                    visible: true,
                    position: position,
                    lastDockedPosition: position,
                    size: slot.size,
                    collapsed: slot.collapsed
                )
            }
        }

        applyZone(window.zones.left, position: .left)
        applyZone(window.zones.right, position: .right)
        applyZone(window.zones.top, position: .top)
        applyZone(window.zones.bottom, position: .bottom)

        if let floats = window.floating {
            for placement in floats where registered.contains(placement.id) {
                out[placement.id] = PanelInstanceState(
                    id: placement.id,
                    visible: true,
                    position: .floating,
                    lastDockedPosition: nil,
                    size: 1.0,
                    collapsed: false,
                    floatingFrame: placement.frame
                )
            }
        }

        return Array(out.values)
    }

    /// Diff between current registry state and the state the preset wants.
    /// Returns the *minimum* set of mutations the spec §7.1 calls for —
    /// `LayoutDirector.applySnapshot(_:)` only mutates differences.
    public static func diff(
        current: [PanelInstanceState],
        target: [PanelInstanceState]
    ) -> [PanelInstanceState] {
        var currentById: [String: PanelInstanceState] = [:]
        for s in current { currentById[s.id] = s }
        var changes: [PanelInstanceState] = []
        for t in target {
            if currentById[t.id] != t {
                changes.append(t)
            }
        }
        return changes
    }

    // MARK: - Snap math

    /// The default snap-trigger distance in pt. Spec §3.2: 24 pt for in-window
    /// dock edges. Bryan's keybindings file can override at runtime.
    public static let defaultSnapTriggerDistance: CGFloat = 24

    /// Edge-of-screen snap distance — see §3.2 last paragraph (16 pt).
    public static let edgeOfScreenSnapDistance: CGFloat = 16

    /// One candidate snap target — a dock zone in some window.
    public struct SnapTarget: Equatable, Sendable {
        public var windowId: String
        public var position: PanelPosition  // .left / .right / .top / .bottom
        public var edgeRect: CGRect
        public init(windowId: String, position: PanelPosition, edgeRect: CGRect) {
            self.windowId = windowId
            self.position = position
            self.edgeRect = edgeRect
        }
    }

    public struct SnapResult: Equatable, Sendable {
        public var target: SnapTarget
        public var distance: CGFloat
        public init(target: SnapTarget, distance: CGFloat) {
            self.target = target
            self.distance = distance
        }
    }

    /// Finds the nearest snap target to a cursor position.
    /// Returns nil if no edge is within `triggerDistance`.
    public static func nearestSnapTarget(
        for cursor: CGPoint,
        targets: [SnapTarget],
        triggerDistance: CGFloat = defaultSnapTriggerDistance
    ) -> SnapResult? {
        var best: SnapResult? = nil
        for target in targets {
            let d = perpendicularDistance(from: cursor, to: target.edgeRect)
            if d <= triggerDistance, (best == nil || d < best!.distance) {
                best = SnapResult(target: target, distance: d)
            }
        }
        return best
    }

    /// Perpendicular distance from a point to an axis-aligned rectangle's
    /// nearest edge. Used by the snap detector; exposed because tests want
    /// to assert exact values.
    public static func perpendicularDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Builds dock-edge rects for a window. The four edges are 24-pt-wide
    /// strips inset from the window frame, matching the visual we render
    /// in the snap preview (semi-transparent blue rectangle).
    public static func dockEdgeRects(
        for windowFrame: CGRect,
        edgeThickness: CGFloat = 24
    ) -> [PanelPosition: CGRect] {
        let t = edgeThickness
        return [
            .left:   CGRect(x: windowFrame.minX, y: windowFrame.minY,
                            width: t, height: windowFrame.height),
            .right:  CGRect(x: windowFrame.maxX - t, y: windowFrame.minY,
                            width: t, height: windowFrame.height),
            .top:    CGRect(x: windowFrame.minX, y: windowFrame.maxY - t,
                            width: windowFrame.width, height: t),
            .bottom: CGRect(x: windowFrame.minX, y: windowFrame.minY,
                            width: windowFrame.width, height: t),
        ]
    }
}
