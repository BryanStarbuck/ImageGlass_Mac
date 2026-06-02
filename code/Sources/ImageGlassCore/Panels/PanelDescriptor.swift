import Foundation
import CoreGraphics

/// Static metadata about a panel. UI-free, Codable, Sendable.
///
/// This is the data-side of the `ImageGlassPanel` protocol described in
/// `docs/panels.mdx` §5.2. The view factory itself lives on the UI side
/// (`PanelViewRegistry` in the `ImageGlass` target) because SwiftUI types
/// cannot be imported in `ImageGlassCore`.
///
/// Keeping descriptors here lets MCP, layout persistence, and tests
/// reason about panels without dragging in SwiftUI.
public struct PanelDescriptor: Codable, Sendable, Equatable, Identifiable {

    /// Regex the spec mandates: `^[a-z][a-z0-9_]{2,63}$`.
    /// Stable, non-localized, used by MCP and `layout.json`.
    public let id: String

    /// User-visible English title (localization is the UI layer's problem).
    public let title: String

    /// SF Symbol name shown in panel header / menus.
    public let icon: String

    public let minSize: CGSize
    public let preferredSize: CGSize
    public let maxSize: CGSize

    /// Where this panel docks the first time the user shows it.
    public let defaultPosition: PanelPosition

    /// `toolbar`, `status_bar`, `viewer` are pinned. Everything else can float.
    public let supportsFloating: Bool

    /// True for panels that ship with the app (registered at launch).
    /// False for third-party / plugin panels (post-v1).
    public let builtin: Bool

    public init(
        id: String,
        title: String,
        icon: String,
        minSize: CGSize,
        preferredSize: CGSize,
        maxSize: CGSize,
        defaultPosition: PanelPosition,
        supportsFloating: Bool,
        builtin: Bool = true
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.minSize = minSize
        self.preferredSize = preferredSize
        self.maxSize = maxSize
        self.defaultPosition = defaultPosition
        self.supportsFloating = supportsFloating
        self.builtin = builtin
    }

    // MARK: - Validation

    /// Compiled once; the regex literal would be cleaner but a manual scan
    /// keeps this file Swift-5.10-portable and dependency-free.
    public static func isValidId(_ candidate: String) -> Bool {
        guard (3...64).contains(candidate.count) else { return false }
        let chars = Array(candidate)
        guard let first = chars.first, first.isLowercase, first.isLetter else { return false }
        for c in chars.dropFirst() {
            let ok = (c.isLowercase && c.isLetter)
                  || c.isNumber
                  || c == "_"
            if !ok { return false }
        }
        return true
    }
}
