import Foundation
import CoreGraphics

/// Pure-data description of a panel's identity and framework constraints.
/// Lives in `ImageGlassCore` so non-GUI callers (MCP tools, tests) can
/// reason about the panel catalog without importing SwiftUI. The SwiftUI
/// app target attaches a content view via `ImageGlassPanel`. Spec §3.1.
public struct PanelDescriptor: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let icon: String
    public let minSize: CGSize
    public let preferredSize: CGSize
    public let maxSize: CGSize
    public let supportsFloating: Bool
    /// Built-in default dock position used when the panel has never been
    /// shown and `Layout.hidden` carries no `last_position`.
    public let defaultPosition: DockPosition

    public init(
        id: String,
        title: String,
        icon: String,
        minSize: CGSize = .init(width: 160, height: 120),
        preferredSize: CGSize = .init(width: 280, height: 480),
        maxSize: CGSize = .init(width: CGFloat.infinity, height: CGFloat.infinity),
        supportsFloating: Bool = true,
        defaultPosition: DockPosition = .right
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.minSize = minSize
        self.preferredSize = preferredSize
        self.maxSize = maxSize
        self.supportsFloating = supportsFloating
        self.defaultPosition = defaultPosition
    }

    /// Spec-mandated id grammar: `^[a-z][a-z0-9_]{2,63}$`.
    /// Validated by ``PanelRegistry`` at registration time.
    public static func isValidId(_ id: String) -> Bool {
        guard id.count >= 3, id.count <= 64 else { return false }
        var iter = id.unicodeScalars.makeIterator()
        guard let first = iter.next(), ("a"..."z").contains(Character(first)) else {
            return false
        }
        while let s = iter.next() {
            let c = Character(s)
            let ok = ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "_"
            if !ok { return false }
        }
        return true
    }
}

/// Catalog of every panel the fork ships with. Spec §4.
///
/// The catalog is plain data: it can be queried by the MCP server's
/// `list_panels` tool, by the View menu, and by tests, all without
/// instantiating any SwiftUI views. The SwiftUI registry layers a
/// content-view factory on top.
public enum BuiltInPanelCatalog {

    // MARK: - Inherited from upstream behavior (spec §4.1)

    public static let toolbar = PanelDescriptor(
        id: "toolbar",
        title: "Toolbar",
        icon: "wrench.and.screwdriver",
        minSize: .init(width: 320, height: 36),
        preferredSize: .init(width: 800, height: 44),
        supportsFloating: false,
        defaultPosition: .top
    )

    public static let statusBar = PanelDescriptor(
        id: "status_bar",
        title: "Status bar",
        icon: "info.circle",
        minSize: .init(width: 200, height: 22),
        preferredSize: .init(width: 800, height: 28),
        supportsFloating: false,
        defaultPosition: .bottom
    )

    public static let galleryStrip = PanelDescriptor(
        id: "gallery_strip",
        title: "Thumbnail strip",
        icon: "photo.on.rectangle",
        minSize: .init(width: 200, height: 80),
        preferredSize: .init(width: 800, height: 140),
        supportsFloating: false,
        defaultPosition: .bottom
    )

    public static let colorPicker = PanelDescriptor(
        id: "color_picker",
        title: "Color picker",
        icon: "eyedropper",
        minSize: .init(width: 220, height: 200),
        preferredSize: .init(width: 280, height: 320),
        supportsFloating: true,
        defaultPosition: .floating
    )

    public static let frameNav = PanelDescriptor(
        id: "frame_nav",
        title: "Page / frame navigator",
        icon: "rectangle.stack",
        minSize: .init(width: 220, height: 120),
        preferredSize: .init(width: 280, height: 220),
        supportsFloating: true,
        defaultPosition: .floating
    )

    public static let crop = PanelDescriptor(
        id: "crop",
        title: "Crop",
        icon: "crop",
        minSize: .init(width: 220, height: 160),
        preferredSize: .init(width: 280, height: 220),
        supportsFloating: true,
        defaultPosition: .centerOverlay
    )

    public static let imageInfo = PanelDescriptor(
        id: "image_info",
        title: "Image info overlay",
        icon: "info.bubble",
        minSize: .init(width: 200, height: 80),
        preferredSize: .init(width: 280, height: 200),
        supportsFloating: false,
        defaultPosition: .centerOverlay
    )

    // MARK: - New to the fork (spec §4.2)

    public static let filePanel = PanelDescriptor(
        id: "file_panel",
        title: "Files",
        icon: "folder",
        minSize: .init(width: 200, height: 200),
        preferredSize: .init(width: 280, height: 600),
        supportsFloating: true,
        defaultPosition: .left
    )

    public static let scopeEditor = PanelDescriptor(
        id: "scope_editor",
        title: "Scopes",
        icon: "slider.horizontal.3",
        minSize: .init(width: 220, height: 200),
        preferredSize: .init(width: 280, height: 400),
        supportsFloating: true,
        defaultPosition: .left
    )

    public static let metadata = PanelDescriptor(
        id: "metadata",
        title: "Metadata",
        icon: "tag",
        minSize: .init(width: 220, height: 200),
        preferredSize: .init(width: 320, height: 600),
        supportsFloating: true,
        defaultPosition: .right
    )

    public static let histogram = PanelDescriptor(
        id: "histogram",
        title: "Histogram",
        icon: "chart.bar",
        minSize: .init(width: 220, height: 160),
        preferredSize: .init(width: 320, height: 240),
        supportsFloating: true,
        defaultPosition: .right
    )

    public static let mcpActivity = PanelDescriptor(
        id: "mcp_activity",
        title: "MCP activity",
        icon: "bolt.horizontal",
        minSize: .init(width: 240, height: 200),
        preferredSize: .init(width: 360, height: 480),
        supportsFloating: true,
        defaultPosition: .right
    )

    public static let localStorage = PanelDescriptor(
        id: "local_storage",
        title: "Local storage",
        icon: "externaldrive",
        minSize: .init(width: 240, height: 200),
        preferredSize: .init(width: 360, height: 480),
        supportsFloating: true,
        defaultPosition: .floating
    )

    public static let pluginsLog = PanelDescriptor(
        id: "plugins_log",
        title: "Plugins log",
        icon: "ladybug",
        minSize: .init(width: 240, height: 200),
        preferredSize: .init(width: 360, height: 320),
        supportsFloating: true,
        defaultPosition: .floating
    )

    // MARK: - Aggregate

    public static let all: [PanelDescriptor] = [
        toolbar, statusBar, galleryStrip,
        colorPicker, frameNav, crop, imageInfo,
        filePanel, scopeEditor,
        metadata, histogram, mcpActivity,
        localStorage, pluginsLog,
    ]

    public static func descriptor(for id: String) -> PanelDescriptor? {
        all.first { $0.id == id }
    }
}
