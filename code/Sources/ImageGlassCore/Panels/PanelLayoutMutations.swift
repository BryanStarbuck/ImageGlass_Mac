import Foundation
import CoreGraphics

/// Pure functions that mutate a `PanelLayout`. The MCP server and the
/// GUI's `LayoutCoordinator` both call into these so the rules are in
/// exactly one place. Spec §9 (move_panel, show_panel, hide_panel,
/// set_panel_size, tab_panels, untab_panel).
public enum PanelLayoutMutations {

    // MARK: - Show / Hide

    /// Show a hidden panel at its `last_position` and `last_size` (spec §9).
    /// If the panel has never been shown, place it at `defaultPosition` with
    /// `defaultSize`. Returns the mutated layout.
    public static func showPanel(
        _ layout: PanelLayout,
        id: String,
        defaultPosition: DockPosition = .right,
        defaultSize: CGSize = .init(width: 280, height: 600)
    ) -> PanelLayout {
        showPanel(layout, id: id,
                  defaultPosition: defaultPosition,
                  defaultSize: defaultSize,
                  asPrimary: false)
    }

    /// Same as `showPanel` but the restored panel is inserted at the front
    /// of its destination tab group (or floating list) and becomes the
    /// active tab. Used by the bootstrap reconciliation (panels.mdx §6.5)
    /// to put `file_panel` back as the prominent left-dock tab rather than
    /// the last tab behind whatever else happens to share the left.
    public static func showPanelAsPrimary(
        _ layout: PanelLayout,
        id: String,
        defaultPosition: DockPosition = .left,
        defaultSize: CGSize = .init(width: 280, height: 600)
    ) -> PanelLayout {
        showPanel(layout, id: id,
                  defaultPosition: defaultPosition,
                  defaultSize: defaultSize,
                  asPrimary: true)
    }

    private static func showPanel(
        _ layout: PanelLayout,
        id: String,
        defaultPosition: DockPosition,
        defaultSize: CGSize,
        asPrimary: Bool
    ) -> PanelLayout {
        var l = layout
        if l.isVisible(id) {
            if asPrimary,
               let gIdx = l.groups.firstIndex(where: { $0.panelIDs.contains(id) }),
               let pIdx = l.groups[gIdx].panelIDs.firstIndex(of: id),
               pIdx != 0 {
                // Already visible but not primary — promote to first tab
                // so the title-bar toggle / bootstrap reconciliation can
                // hand the user the prominent file panel they expect.
                l.groups[gIdx].panelIDs.remove(at: pIdx)
                l.groups[gIdx].panelIDs.insert(id, at: 0)
                l.groups[gIdx].activeIndex = 0
            }
            return l
        }

        let position: DockPosition
        let size: CGFloat
        if let last = l.hidden[id] {
            position = last.lastPosition
            size = (last.lastPosition == .top || last.lastPosition == .bottom)
                ? last.lastSize.height : last.lastSize.width
            l.hidden.removeValue(forKey: id)
        } else {
            position = defaultPosition
            size = (defaultPosition == .top || defaultPosition == .bottom)
                ? defaultSize.height : defaultSize.width
        }

        if position == .floating {
            let f = FloatingPanel(
                id: id,
                frame: CGRect(x: 200, y: 200,
                              width: defaultSize.width,
                              height: defaultSize.height)
            )
            if asPrimary {
                l.floating.insert(f, at: 0)
            } else {
                l.floating.append(f)
            }
        } else if let idx = l.groups.firstIndex(where: { $0.position == position }) {
            if asPrimary {
                l.groups[idx].panelIDs.insert(id, at: 0)
                l.groups[idx].activeIndex = 0
            } else {
                l.groups[idx].panelIDs.append(id)
                l.groups[idx].activeIndex = l.groups[idx].panelIDs.count - 1
            }
        } else {
            l.groups.append(TabGroup(position: position, panelIDs: [id], activeIndex: 0, size: size))
        }
        return l
    }

    /// Hide a panel. Refuses to hide the last visible panel (spec §5.7).
    /// Records current size/position to `Layout.hidden[id]` (spec §9).
    public static func hidePanel(
        _ layout: PanelLayout,
        id: String
    ) throws -> PanelLayout {
        var l = layout
        guard l.isVisible(id) else { return l }

        let totalVisible = l.visiblePanelIDs.count
        if totalVisible <= 1 {
            throw PanelMutationError.cannotHideLastVisible
        }

        // Floating?
        if let fIdx = l.floating.firstIndex(where: { $0.id == id }) {
            let f = l.floating.remove(at: fIdx)
            l.hidden[id] = HiddenPanelState(
                lastPosition: .floating,
                lastSize: CGSize(width: f.frame.width, height: f.frame.height)
            )
            return l
        }

        // Docked?
        for gIdx in l.groups.indices {
            if let pIdx = l.groups[gIdx].panelIDs.firstIndex(of: id) {
                let pos = l.groups[gIdx].position
                let across = l.groups[gIdx].size ?? 280
                let size: CGSize = (pos == .top || pos == .bottom)
                    ? .init(width: 800, height: across)
                    : .init(width: across, height: 600)
                l.groups[gIdx].panelIDs.remove(at: pIdx)
                if l.groups[gIdx].panelIDs.isEmpty {
                    l.groups.remove(at: gIdx)
                } else if l.groups[gIdx].activeIndex >= l.groups[gIdx].panelIDs.count {
                    l.groups[gIdx].activeIndex = l.groups[gIdx].panelIDs.count - 1
                }
                l.hidden[id] = HiddenPanelState(lastPosition: pos, lastSize: size)
                return l
            }
        }
        return l
    }

    // MARK: - Move

    /// Move a panel to a docked position or `floating`. Spec §9.
    public static func movePanel(
        _ layout: PanelLayout,
        id: String,
        to position: DockPosition,
        preferredSize: CGSize = .init(width: 320, height: 600)
    ) throws -> PanelLayout {
        // Remove from current location (without writing to hidden).
        var l = layout
        l = removePanelFromVisibleSlots(l, id: id)

        if position == .floating {
            let frame = CGRect(x: 240, y: 240, width: preferredSize.width, height: preferredSize.height)
            l.floating.append(FloatingPanel(id: id, frame: frame))
        } else {
            if let idx = l.groups.firstIndex(where: { $0.position == position }) {
                l.groups[idx].panelIDs.append(id)
                l.groups[idx].activeIndex = l.groups[idx].panelIDs.count - 1
            } else {
                let across: CGFloat = (position == .top || position == .bottom)
                    ? preferredSize.height : preferredSize.width
                l.groups.append(TabGroup(position: position, panelIDs: [id], activeIndex: 0, size: across))
            }
        }
        if let reason = PanelLayoutValidator.validate(l) {
            throw PanelMutationError.invalid(reason)
        }
        return l
    }

    // MARK: - Resize

    /// Resize a panel's tab group. `size` is the *across* dimension.
    public static func setPanelSize(
        _ layout: PanelLayout,
        id: String,
        size: CGFloat,
        minSize: CGFloat = 64
    ) throws -> PanelLayout {
        var l = layout
        let clamped = max(size, minSize)
        for gIdx in l.groups.indices {
            if l.groups[gIdx].panelIDs.contains(id) {
                l.groups[gIdx].size = clamped
                return l
            }
        }
        if let fIdx = l.floating.firstIndex(where: { $0.id == id }) {
            var f = l.floating[fIdx]
            f.frame.size = CGSize(width: max(size, minSize), height: max(size, minSize))
            l.floating[fIdx] = f
            return l
        }
        throw PanelMutationError.notVisible(id)
    }

    // MARK: - Tab / Untab

    /// Make `sourceID` a tab in the same group as `targetID`. Spec §5.5, §9.
    public static func tabPanels(
        _ layout: PanelLayout,
        targetID: String,
        sourceID: String
    ) throws -> PanelLayout {
        guard targetID != sourceID else { return layout }
        var l = layout
        guard let targetGroupIdx = l.groups.firstIndex(where: { $0.panelIDs.contains(targetID) }) else {
            throw PanelMutationError.notVisible(targetID)
        }
        l = removePanelFromVisibleSlots(l, id: sourceID)
        // group index may have changed if the source was in an earlier group;
        // re-locate.
        guard let reIdx = l.groups.firstIndex(where: { $0.panelIDs.contains(targetID) }) else {
            throw PanelMutationError.notVisible(targetID)
        }
        l.groups[reIdx].panelIDs.append(sourceID)
        l.groups[reIdx].activeIndex = l.groups[reIdx].panelIDs.count - 1
        _ = targetGroupIdx
        return l
    }

    /// Break a panel out of its tab group into its own group at the same
    /// position. Spec §9.
    public static func untabPanel(
        _ layout: PanelLayout,
        id: String
    ) throws -> PanelLayout {
        var l = layout
        for gIdx in l.groups.indices {
            if let pIdx = l.groups[gIdx].panelIDs.firstIndex(of: id) {
                if l.groups[gIdx].panelIDs.count == 1 {
                    // Already alone.
                    return l
                }
                let position = l.groups[gIdx].position
                let size = l.groups[gIdx].size
                l.groups[gIdx].panelIDs.remove(at: pIdx)
                if l.groups[gIdx].activeIndex >= l.groups[gIdx].panelIDs.count {
                    l.groups[gIdx].activeIndex = l.groups[gIdx].panelIDs.count - 1
                }
                l.groups.append(TabGroup(position: position, panelIDs: [id], activeIndex: 0, size: size))
                return l
            }
        }
        throw PanelMutationError.notVisible(id)
    }

    // MARK: - Helpers

    private static func removePanelFromVisibleSlots(_ layout: PanelLayout, id: String) -> PanelLayout {
        var l = layout
        if let fIdx = l.floating.firstIndex(where: { $0.id == id }) {
            l.floating.remove(at: fIdx)
        }
        for gIdx in l.groups.indices.reversed() {
            if let pIdx = l.groups[gIdx].panelIDs.firstIndex(of: id) {
                l.groups[gIdx].panelIDs.remove(at: pIdx)
                if l.groups[gIdx].panelIDs.isEmpty {
                    l.groups.remove(at: gIdx)
                } else if l.groups[gIdx].activeIndex >= l.groups[gIdx].panelIDs.count {
                    l.groups[gIdx].activeIndex = l.groups[gIdx].panelIDs.count - 1
                }
            }
        }
        return l
    }
}

public enum PanelMutationError: Error, CustomStringConvertible {
    case cannotHideLastVisible
    case notVisible(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .cannotHideLastVisible:
            return "Cannot hide the last visible panel (spec §5.7)."
        case .notVisible(let id):
            return "Panel '\(id)' is not currently visible."
        case .invalid(let reason):
            return "Resulting layout is invalid: \(reason)"
        }
    }
}
