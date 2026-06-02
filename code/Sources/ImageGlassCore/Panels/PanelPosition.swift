import Foundation

/// Where a panel currently lives within (or outside) the main window.
///
/// `left`, `right`, `top`, `bottom` are the four dock zones described in
/// `docs/panels.mdx` §3.1. `floating` means the panel has been torn off into an
/// `NSPanel`. `hidden` means the panel is registered but not on screen — its
/// last-known dock position is preserved by `PanelInstanceState`.
public enum PanelPosition: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
    case floating
    case hidden

    /// True if the position lives inside one of the four dock zones.
    public var isDocked: Bool {
        switch self {
        case .left, .right, .top, .bottom: return true
        case .floating, .hidden: return false
        }
    }

    /// For docked positions, the axis along which child panels stack
    /// inside the zone (matches the nested `NSSplitView` orientation in the
    /// spec §5.1). Returns `nil` for non-docked positions.
    public var stackAxis: StackAxis? {
        switch self {
        case .left, .right: return .vertical   // panels stack top-to-bottom
        case .top, .bottom: return .horizontal // panels stack left-to-right
        case .floating, .hidden: return nil
        }
    }

    public enum StackAxis: String, Codable, Sendable {
        case vertical
        case horizontal
    }
}
