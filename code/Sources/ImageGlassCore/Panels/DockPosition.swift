import Foundation
import CoreGraphics

/// A panel that is part of the window's layout (as opposed to floating)
/// occupies one of these positions. See docs/panels.mdx §3.2.
public enum DockPosition: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
    case centerOverlay
    case floating

    /// JSON wire form — snake_case to match docs/panels.mdx §6.1.
    public var wireValue: String {
        switch self {
        case .left:          return "left"
        case .right:         return "right"
        case .top:           return "top"
        case .bottom:        return "bottom"
        case .centerOverlay: return "center_overlay"
        case .floating:      return "floating"
        }
    }

    public static func fromWire(_ s: String) -> DockPosition? {
        switch s {
        case "left":           return .left
        case "right":          return .right
        case "top":            return .top
        case "bottom":         return .bottom
        case "center_overlay": return .centerOverlay
        case "floating":       return .floating
        default:               return nil
        }
    }

    /// Positions that are valid for a `TabGroup` (everything except floating).
    public static var dockedCases: [DockPosition] {
        [.left, .right, .top, .bottom, .centerOverlay]
    }
}

/// `Layout.groups[]` element: one or more panels sharing a dock position,
/// shown as a tab strip when there is more than one. Spec §3.3.
public struct TabGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var position: DockPosition
    public var panelIDs: [String]
    public var activeIndex: Int
    /// The *across* dimension in points (width for left/right, height for top/bottom).
    /// `nil` means the framework's default for that position.
    public var size: CGFloat?
    public var collapsed: Bool

    public init(
        id: UUID = UUID(),
        position: DockPosition,
        panelIDs: [String],
        activeIndex: Int = 0,
        size: CGFloat? = nil,
        collapsed: Bool = false
    ) {
        self.id = id
        self.position = position
        self.panelIDs = panelIDs
        self.activeIndex = min(max(activeIndex, 0), max(panelIDs.count - 1, 0))
        self.size = size
        self.collapsed = collapsed
    }
}

/// Spec §3.4.
public struct FloatingPanel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// `[x, y, w, h]` in screen coordinates.
    public var frame: CGRect
    /// `CGDirectDisplayID` stringified.
    public var screenID: String

    public init(id: String, frame: CGRect, screenID: String = "") {
        self.id = id
        self.frame = frame
        self.screenID = screenID
    }
}

/// Spec §3.4.
public struct HiddenPanelState: Codable, Sendable, Equatable {
    public var lastPosition: DockPosition
    public var lastSize: CGSize

    public init(lastPosition: DockPosition, lastSize: CGSize) {
        self.lastPosition = lastPosition
        self.lastSize = lastSize
    }
}
