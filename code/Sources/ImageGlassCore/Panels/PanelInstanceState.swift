import Foundation
import CoreGraphics

/// Runtime state for one panel inside the workspace.
///
/// Matches the struct sketched in `docs/panels.mdx` §5.3. Codable so the
/// registry can be serialized straight to `layout.json`.
public struct PanelInstanceState: Codable, Sendable, Equatable {

    /// The descriptor `id` this state row binds to. Kept in the struct so
    /// the JSON form is self-describing (does not depend on dictionary key
    /// ordering).
    public var id: String

    /// True if the panel is currently on screen anywhere (docked or floating).
    public var visible: Bool

    /// Current home of the panel. `hidden` is allowed even when `visible == false`
    /// — the spec keeps the panel's *last* dock position separately to support
    /// re-show with the same layout.
    public var position: PanelPosition

    /// Last-known dock position for `position == .hidden | .floating`.
    /// Used by `show_panel` when no explicit position is provided.
    public var lastDockedPosition: PanelPosition?

    /// Size of the panel inside its zone:
    /// - If the value is in `(0, 1]` it is a proportion of the zone.
    /// - If `> 1` it is an absolute size in points.
    ///
    /// The convention here matches the `zones[*].panels[*].size` rule in
    /// the spec §3.4.1.
    public var size: Double

    public var collapsed: Bool

    /// Frame in screen coordinates when `position == .floating`. nil otherwise.
    public var floatingFrame: CGRect?

    /// If the panel is part of a tab group, the id of that group. nil otherwise.
    public var tabGroupId: UUID?

    public init(
        id: String,
        visible: Bool,
        position: PanelPosition,
        lastDockedPosition: PanelPosition? = nil,
        size: Double = 1.0,
        collapsed: Bool = false,
        floatingFrame: CGRect? = nil,
        tabGroupId: UUID? = nil
    ) {
        self.id = id
        self.visible = visible
        self.position = position
        self.lastDockedPosition = lastDockedPosition
        self.size = size
        self.collapsed = collapsed
        self.floatingFrame = floatingFrame
        self.tabGroupId = tabGroupId
    }

    /// Initial state for a freshly-registered panel that the user has never
    /// touched. Hidden by default; the layout director decides what to show.
    public static func initial(for descriptor: PanelDescriptor) -> PanelInstanceState {
        PanelInstanceState(
            id: descriptor.id,
            visible: false,
            position: .hidden,
            lastDockedPosition: descriptor.defaultPosition.isDocked
                ? descriptor.defaultPosition
                : nil,
            size: 1.0,
            collapsed: false,
            floatingFrame: nil,
            tabGroupId: nil
        )
    }
}
