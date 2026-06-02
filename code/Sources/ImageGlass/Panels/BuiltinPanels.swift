import Foundation
import SwiftUI
import ImageGlassCore

/// The descriptors the panel framework registers at launch.
///
/// Only the initial panel — `directory_filename` (the existing
/// DirectoryFilenamePanel) — gets a real view factory here. Other panels
/// in the inventory are claimed by sibling agents; they will plug their
/// own factories into `PanelViewRegistry.shared` as they land.
///
/// We still declare descriptors for the headline panels so `list_panels`
/// over MCP returns the canonical inventory even before any other agent
/// has shipped. Each descriptor mirrors the row in `docs/panels.mdx` §2.
public enum BuiltinPanels {

    // MARK: - Initial panel

    /// The Directory / Filename panel — the one the user sees on first run.
    /// Spec §2.2 calls this `file_panel` (and a tree-mode sibling
    /// `file_tree`). The existing implementation does both in one view; we
    /// expose it under a stable id that other agents can replace later.
    public static let directoryFilename = PanelDescriptor(
        id: "directory_filename",
        title: "Files",
        icon: "list.bullet.rectangle",
        minSize: CGSize(width: 200, height: 240),
        preferredSize: CGSize(width: 280, height: 600),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .left,
        supportsFloating: true
    )

    // MARK: - Re-implemented upstream panels (§2.1)

    public static let toolbar = PanelDescriptor(
        id: "toolbar",
        title: "Toolbar",
        icon: "rectangle.topthird.inset.filled",
        minSize: CGSize(width: 320, height: 28),
        preferredSize: CGSize(width: 800, height: 36),
        maxSize: CGSize(width: CGFloat.infinity, height: 56),
        defaultPosition: .top,
        supportsFloating: false
    )

    public static let thumbnailStrip = PanelDescriptor(
        id: "thumbnail_strip",
        title: "Thumbnails",
        icon: "rectangle.grid.3x2",
        minSize: CGSize(width: 320, height: 90),
        preferredSize: CGSize(width: 800, height: 120),
        maxSize: CGSize(width: CGFloat.infinity, height: 240),
        defaultPosition: .bottom,
        supportsFloating: true
    )

    public static let thumbnailGrid = PanelDescriptor(
        id: "thumbnail_grid",
        title: "Thumbnail Grid",
        icon: "square.grid.2x2",
        minSize: CGSize(width: 180, height: 360),
        preferredSize: CGSize(width: 260, height: 600),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .left,
        supportsFloating: true
    )

    public static let statusBar = PanelDescriptor(
        id: "status_bar",
        title: "Status Bar",
        icon: "info.circle",
        minSize: CGSize(width: 320, height: 22),
        preferredSize: CGSize(width: 800, height: 26),
        maxSize: CGSize(width: CGFloat.infinity, height: 32),
        defaultPosition: .bottom,
        supportsFloating: false
    )

    public static let colorPicker = PanelDescriptor(
        id: "color_picker",
        title: "Color Picker",
        icon: "eyedropper",
        minSize: CGSize(width: 240, height: 200),
        preferredSize: CGSize(width: 280, height: 240),
        maxSize: CGSize(width: 480, height: 480),
        defaultPosition: .floating,
        supportsFloating: true
    )

    public static let pageNav = PanelDescriptor(
        id: "page_nav",
        title: "Page Navigator",
        icon: "rectangle.stack",
        minSize: CGSize(width: 320, height: 36),
        preferredSize: CGSize(width: 800, height: 40),
        maxSize: CGSize(width: CGFloat.infinity, height: 56),
        defaultPosition: .bottom,
        supportsFloating: true
    )

    public static let crop = PanelDescriptor(
        id: "crop",
        title: "Crop",
        icon: "crop",
        minSize: CGSize(width: 280, height: 180),
        preferredSize: CGSize(width: 320, height: 220),
        maxSize: CGSize(width: 480, height: 380),
        defaultPosition: .floating,
        supportsFloating: true
    )

    public static let resize = PanelDescriptor(
        id: "resize",
        title: "Resize",
        icon: "arrow.up.left.and.arrow.down.right",
        minSize: CGSize(width: 320, height: 180),
        preferredSize: CGSize(width: 360, height: 220),
        maxSize: CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
        defaultPosition: .floating,
        supportsFloating: true
    )

    public static let metadataExif = PanelDescriptor(
        id: "metadata_exif",
        title: "Metadata",
        icon: "info.square",
        minSize: CGSize(width: 260, height: 320),
        preferredSize: CGSize(width: 300, height: 600),
        maxSize: CGSize(width: 520, height: CGFloat.infinity),
        defaultPosition: .right,
        supportsFloating: true
    )

    // MARK: - New fork panels (§2.2)

    public static let filePanel = PanelDescriptor(
        id: "file_panel",
        title: "Files",
        icon: "list.bullet.rectangle",
        minSize: CGSize(width: 200, height: 240),
        preferredSize: CGSize(width: 280, height: 600),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .left,
        supportsFloating: true
    )

    public static let fileTree = PanelDescriptor(
        id: "file_tree",
        title: "File Tree",
        icon: "folder",
        minSize: CGSize(width: 220, height: 240),
        preferredSize: CGSize(width: 300, height: 600),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .left,
        supportsFloating: true
    )

    public static let scopePanel = PanelDescriptor(
        id: "scope_panel",
        title: "Scopes",
        icon: "scope",
        minSize: CGSize(width: 220, height: 200),
        preferredSize: CGSize(width: 280, height: 280),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .left,
        supportsFloating: true
    )

    public static let localStorageBrowser = PanelDescriptor(
        id: "local_storage_browser",
        title: "Local Storage",
        icon: "externaldrive",
        minSize: CGSize(width: 260, height: 320),
        preferredSize: CGSize(width: 320, height: 600),
        maxSize: CGSize(width: 600, height: CGFloat.infinity),
        defaultPosition: .right,
        supportsFloating: true
    )

    public static let mcpPanel = PanelDescriptor(
        id: "mcp_panel",
        title: "MCP",
        icon: "antenna.radiowaves.left.and.right",
        minSize: CGSize(width: 240, height: 200),
        preferredSize: CGSize(width: 280, height: 240),
        maxSize: CGSize(width: 520, height: CGFloat.infinity),
        defaultPosition: .right,
        supportsFloating: true
    )

    public static let histogram = PanelDescriptor(
        id: "histogram",
        title: "Histogram",
        icon: "chart.bar",
        minSize: CGSize(width: 240, height: 140),
        preferredSize: CGSize(width: 280, height: 200),
        maxSize: CGSize(width: 520, height: 320),
        defaultPosition: .right,
        supportsFloating: true
    )

    public static let taggedCollections = PanelDescriptor(
        id: "tagged_collections",
        title: "Collections",
        icon: "tag",
        minSize: CGSize(width: 280, height: 240),
        preferredSize: CGSize(width: 320, height: 360),
        maxSize: CGSize(width: 520, height: CGFloat.infinity),
        defaultPosition: .floating,
        supportsFloating: true
    )

    public static let notes = PanelDescriptor(
        id: "notes",
        title: "Notes",
        icon: "note.text",
        minSize: CGSize(width: 280, height: 200),
        preferredSize: CGSize(width: 320, height: 320),
        maxSize: CGSize(width: 520, height: CGFloat.infinity),
        defaultPosition: .floating,
        supportsFloating: true
    )

    /// Every descriptor the framework ships with. Registration order
    /// matters because it drives default UI ordering inside zones.
    public static let all: [PanelDescriptor] = [
        directoryFilename,
        toolbar,
        statusBar,
        filePanel,
        fileTree,
        scopePanel,
        thumbnailStrip,
        thumbnailGrid,
        metadataExif,
        histogram,
        mcpPanel,
        localStorageBrowser,
        colorPicker,
        pageNav,
        crop,
        resize,
        taggedCollections,
        notes,
    ]
}
