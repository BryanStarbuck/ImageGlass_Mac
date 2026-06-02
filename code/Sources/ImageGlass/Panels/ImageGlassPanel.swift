import SwiftUI
import ImageGlassCore

/// The single SwiftUI protocol every panel implements. Spec §3.1.
///
/// A panel is the smallest unit the user can show/hide/dock/float. The
/// `descriptor` carries identity (id, title, icon) and framework constraints
/// (min/preferred size, supportsFloating). `content(state:)` returns the
/// SwiftUI view the framework wraps in chrome and a drag-handle header.
@MainActor
public protocol ImageGlassPanel {
    /// Stable identifier. Used as the key in `layout.json` and as the MCP id.
    /// Must not change across releases without a migration.
    static var id: String { get }

    /// Pure-data description of identity + constraints. Lives in
    /// `ImageGlassCore` so non-GUI callers (MCP, tests) can reason about it.
    var descriptor: PanelDescriptor { get }

    /// SwiftUI content. The framework wraps this in chrome and a drag-handle
    /// header (`PanelChrome`).
    @ViewBuilder func content(state: AppState) -> AnyView
}

public extension ImageGlassPanel {
    var title: String     { descriptor.title }
    var icon: String      { descriptor.icon }
    var minSize: CGSize   { descriptor.minSize }
    var preferredSize: CGSize { descriptor.preferredSize }
    var supportsFloating: Bool { descriptor.supportsFloating }
}
