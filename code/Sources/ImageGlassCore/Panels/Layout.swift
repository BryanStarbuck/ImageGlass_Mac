import Foundation
import CoreGraphics

/// Complete arrangement of panels in the window. Spec §3.4 and §6.
public struct PanelLayout: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var groups: [TabGroup]
    public var floating: [FloatingPanel]
    public var hidden: [String: HiddenPanelState]
    /// Empty string for "Unnamed / custom".
    public var activePreset: String

    public static let currentSchemaVersion: Int = 1

    public init(
        schemaVersion: Int = PanelLayout.currentSchemaVersion,
        groups: [TabGroup] = [],
        floating: [FloatingPanel] = [],
        hidden: [String: HiddenPanelState] = [:],
        activePreset: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.floating = floating
        self.hidden = hidden
        self.activePreset = activePreset
    }

    // MARK: - Wire form (snake_case)

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case groups
        case floating
        case hidden
        case activePreset = "active_preset"
    }

    // MARK: - Convenience

    /// Find the group containing the given panel id, if any. Returns the
    /// group and the panel's index inside `panelIDs`.
    public func locate(panelID: String) -> (group: TabGroup, indexInGroup: Int)? {
        for g in groups {
            if let idx = g.panelIDs.firstIndex(of: panelID) {
                return (g, idx)
            }
        }
        return nil
    }

    /// All currently-visible (docked or floating) panel ids in iteration order.
    public var visiblePanelIDs: [String] {
        var ids: [String] = []
        ids.reserveCapacity(groups.reduce(0) { $0 + $1.panelIDs.count } + floating.count)
        for g in groups {
            ids.append(contentsOf: g.panelIDs)
        }
        for f in floating {
            ids.append(f.id)
        }
        return ids
    }

    public func isVisible(_ panelID: String) -> Bool {
        if floating.contains(where: { $0.id == panelID }) { return true }
        for g in groups where g.panelIDs.contains(panelID) { return true }
        return false
    }

    public func isHidden(_ panelID: String) -> Bool {
        hidden[panelID] != nil && !isVisible(panelID)
    }

    /// Returns the dock position the panel is *currently* in. `floating`
    /// for floating panels; `nil` if the panel is hidden / unknown.
    public func position(of panelID: String) -> DockPosition? {
        if floating.contains(where: { $0.id == panelID }) { return .floating }
        for g in groups where g.panelIDs.contains(panelID) { return g.position }
        return nil
    }
}

/// Validation: returns the first reason the layout is malformed, or `nil` if
/// it is well-formed. Used by `LayoutStore.load` and by MCP `set_layout_state`.
public enum PanelLayoutValidator {
    public static func validate(_ layout: PanelLayout) -> String? {
        if layout.schemaVersion != PanelLayout.currentSchemaVersion {
            return "schema_version must be \(PanelLayout.currentSchemaVersion)"
        }
        var seenIDs: Set<String> = []
        for g in layout.groups {
            if g.panelIDs.isEmpty {
                return "tab group \(g.id) has no panel_ids"
            }
            if g.activeIndex < 0 || g.activeIndex >= g.panelIDs.count {
                return "tab group \(g.id) has active_index out of range"
            }
            for pid in g.panelIDs {
                if !seenIDs.insert(pid).inserted {
                    return "panel '\(pid)' appears in more than one place"
                }
            }
        }
        for f in layout.floating {
            if !seenIDs.insert(f.id).inserted {
                return "panel '\(f.id)' appears in more than one place"
            }
        }
        return nil
    }
}
