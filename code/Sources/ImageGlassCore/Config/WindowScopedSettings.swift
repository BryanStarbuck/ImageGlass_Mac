import Foundation

/// Per-window settings file (multi_window.mdx §3.2). One instance per
/// window, persisted as `settings_window_<windowID>.yaml`.
///
/// This is the v2 split of the v1 `settings.yaml`: the per-window
/// subset moves here, and the application-level subset stays in
/// `Settings` (Settings.swift). See multi_window.mdx §2 for the
/// per-window vs application-level decision rule.
public struct WindowScopedSettings: Codable, Equatable, Sendable {

    // MARK: - Schema identity

    /// Bumped to 2 on the multi-window split (multi_window.mdx §3.1).
    public var schemaVersion: Int = 2

    /// Stable monotonic window ID (multi_window.mdx §1.2). Never
    /// reused, even after retirement.
    public var windowID: Int

    /// Optional human-readable display name. When nil, the Window menu
    /// shows `Window <N>`; when set, the menu shows the name
    /// (multi_window.mdx §5.5, §5.6).
    public var windowName: String?

    // MARK: - Active scope

    /// Which scope from `directories_window_<N>.yaml` is currently
    /// active. When the multi-scope feature is off this is the single
    /// anonymous scope and the key may be absent.
    public var activeScope: String?

    // MARK: - UI overrides

    public var ui: WindowUIOverrides = .init()

    /// Per-window viewer prefs. Applied when this window is frontmost
    /// and read by the launch-restore logic on resurrection.
    public var viewer: WindowViewerSettings = .init()

    public var navigation: WindowNavigationSettings = .init()

    /// Per-window slideshow state. The interval, randomness, and
    /// hide-main-in-slideshow flags stay in the application-level
    /// `slideshow.*` block — those are preferences, not workspace
    /// state (multi_window.mdx §7).
    public var slideshow: WindowSlideshowState = .init()

    /// Save-on-quit / restore-on-launch block. Per-window equivalent
    /// of the v1 `session:` block (multi_window.mdx §3.2.2, §7).
    public var session: WindowSession = .init()

    public init(windowID: Int) {
        precondition(windowID >= 1, "window_id must be >= 1")
        self.windowID = windowID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case windowID = "window_id"
        case windowName = "window_name"
        case activeScope = "active_scope"
        case ui
        case viewer
        case navigation
        case slideshow
        case session
    }

    // Custom init to support partial YAML on round-trip: every block
    // is optional and defaults to its zero value. Mirrors the
    // multi_window.mdx §3.2.1 "required vs. optional" rule.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 2
        self.windowID = try c.decode(Int.self, forKey: .windowID)
        self.windowName = try c.decodeIfPresent(String.self, forKey: .windowName)
        self.activeScope = try c.decodeIfPresent(String.self, forKey: .activeScope)
        self.ui = (try? c.decode(WindowUIOverrides.self, forKey: .ui)) ?? .init()
        self.viewer = (try? c.decode(WindowViewerSettings.self, forKey: .viewer)) ?? .init()
        self.navigation = (try? c.decode(WindowNavigationSettings.self, forKey: .navigation)) ?? .init()
        self.slideshow = (try? c.decode(WindowSlideshowState.self, forKey: .slideshow)) ?? .init()
        self.session = (try? c.decode(WindowSession.self, forKey: .session)) ?? .init()
    }
}

// MARK: - Sub-structs

/// Per-window panel-visibility overrides. A key that is absent on
/// disk means "use the application-level default at read time"
/// (multi_window.mdx §3.2 "ui:" block).
public struct WindowUIOverrides: Codable, Equatable, Sendable {
    public var showDirectoryPanel: Bool?
    public var showPreviewPanel: Bool?
    public var showMetadataPanel: Bool?
    public var showToolbar: Bool?
    public var showStatusBar: Bool?
    public var showFileInfoOverlay: Bool?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showDirectoryPanel = "show_directory_panel"
        case showPreviewPanel = "show_preview_panel"
        case showMetadataPanel = "show_metadata_panel"
        case showToolbar = "show_toolbar"
        case showStatusBar = "show_status_bar"
        case showFileInfoOverlay = "show_file_info_overlay"
    }
}

public struct WindowViewerSettings: Codable, Equatable, Sendable {
    public var defaultZoomMode: String = "fit"        // fit | width | fill | actual | custom
    public var interpolation: String = "high"          // none | low | medium | high
    public var lockZoom: Bool = false
    public var framelessWindow: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultZoomMode = "default_zoom_mode"
        case interpolation
        case lockZoom = "lock_zoom"
        case framelessWindow = "frameless_window"
    }
}

public struct WindowNavigationSettings: Codable, Equatable, Sendable {
    public var sortPanelBy: String = "name"           // name | date_modified | date_created | size | type
    public var sortAscending: Bool = true
    public var loopAtEnds: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sortPanelBy = "sort_panel_by"
        case sortAscending = "sort_ascending"
        case loopAtEnds = "loop_at_ends"
    }
}

/// Per-window slideshow record. `wasRunningOnQuit` and `currentIndex`
/// are written on clean quit; on launch the registry replays
/// `currentIndex` to position the viewer but always sets the live
/// running flag to false (multi_window.mdx §7.4).
public struct WindowSlideshowState: Codable, Equatable, Sendable {
    public var wasRunningOnQuit: Bool = false
    public var currentIndex: Int = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case wasRunningOnQuit = "was_running_on_quit"
        case currentIndex = "current_index"
    }
}

/// Per-window save-on-quit block (multi_window.mdx §3.2.2). The
/// `wasOpenOnQuit` flag is the only field consulted at launch to
/// decide whether to draw this window.
public struct WindowSession: Codable, Equatable, Sendable {
    public var wasOpenOnQuit: Bool = true
    public var window: SessionWindowGeometry = .init()
    public var panels: SessionPanels = .init()
    public var viewer: SessionViewer = .init()
    public var selection: SessionSelection = .init()
    public var directoryPanel: SessionDirectoryPanel = .init()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case wasOpenOnQuit = "was_open_on_quit"
        case window
        case panels
        case viewer
        case selection
        case directoryPanel = "directory_panel"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.wasOpenOnQuit = (try? c.decode(Bool.self, forKey: .wasOpenOnQuit)) ?? true
        self.window = (try? c.decode(SessionWindowGeometry.self, forKey: .window)) ?? .init()
        self.panels = (try? c.decode(SessionPanels.self, forKey: .panels)) ?? .init()
        self.viewer = (try? c.decode(SessionViewer.self, forKey: .viewer)) ?? .init()
        self.selection = (try? c.decode(SessionSelection.self, forKey: .selection)) ?? .init()
        self.directoryPanel = (try? c.decode(SessionDirectoryPanel.self, forKey: .directoryPanel)) ?? .init()
    }
}

public struct SessionWindowGeometry: Codable, Equatable, Sendable {
    public var frame: [Double] = [120, 140, 1440, 900]
    public var screenID: String = "primary"
    public var fullScreen: Bool = false
    public var frameless: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case frame
        case screenID = "screen_id"
        case fullScreen = "full_screen"
        case frameless
    }
}

public struct SessionPanels: Codable, Equatable, Sendable {
    public var filePanel: PanelPlacement = .init(dock: "left", visible: true)
    public var scopeEditor: PanelPlacement = .init(dock: "left", visible: false)
    public var metadata: PanelPlacement = .init(dock: "right", visible: false)
    public var histogram: PanelPlacement = .init(dock: "right", visible: false)
    public var mcpActivity: PanelPlacement = .init(dock: "right", visible: false)
    public var galleryStrip: PanelPlacement = .init(dock: "bottom", visible: false)

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case filePanel = "file_panel"
        case scopeEditor = "scope_editor"
        case metadata
        case histogram
        case mcpActivity = "mcp_activity"
        case galleryStrip = "gallery_strip"
    }
}

public struct PanelPlacement: Codable, Equatable, Sendable {
    public var dock: String        // left | right | top | bottom | floating
    public var visible: Bool
    public var collapsed: Bool = false

    public init(dock: String, visible: Bool, collapsed: Bool = false) {
        self.dock = dock
        self.visible = visible
        self.collapsed = collapsed
    }
}

public struct SessionViewer: Codable, Equatable, Sendable {
    public var zoomMode: String = "fit"             // fit | width | fill | actual | custom
    public var customZoomPercent: Double? = nil
    public var panOffset: [Double] = [0, 0]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case zoomMode = "zoom_mode"
        case customZoomPercent = "custom_zoom_percent"
        case panOffset = "pan_offset"
    }
}

public struct SessionSelection: Codable, Equatable, Sendable {
    public var currentFile: String? = nil
    public var panelFocus: String = "viewer"        // directory_panel | viewer | none

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case currentFile = "current_file"
        case panelFocus = "panel_focus"
    }
}

public struct SessionDirectoryPanel: Codable, Equatable, Sendable {
    public var expandedPaths: [String: Bool] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case expandedPaths = "expanded_paths"
    }
}
