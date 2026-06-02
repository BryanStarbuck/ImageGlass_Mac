import Foundation
import CoreGraphics

/// One row inside `zones[*].panels` in the schema. The size value can be
/// proportional `(0,1]` or absolute (`> 1`) — same rule as
/// `PanelInstanceState.size` and §3.4.1 of the spec.
public struct PanelSlot: Codable, Sendable, Equatable {
    public var id: String
    public var size: Double
    public var collapsed: Bool

    public init(id: String, size: Double = 1.0, collapsed: Bool = false) {
        self.id = id
        self.size = size
        self.collapsed = collapsed
    }
}

/// One of the four dock zones for a window in a preset.
public struct LayoutZone: Codable, Sendable, Equatable {
    /// Width (for left/right) or height (for top/bottom) of the zone in pt.
    /// `0` means the zone is collapsed.
    public var size: Double
    public var panels: [PanelSlot]

    public init(size: Double = 0, panels: [PanelSlot] = []) {
        self.size = size
        self.panels = panels
    }

    /// True if the zone contributes nothing to layout (renderer should not
    /// allocate a track at all).
    public var isEmpty: Bool { size <= 0 || panels.isEmpty }
}

/// A single floating panel placement inside a window preset.
public struct FloatingPanelPlacement: Codable, Sendable, Equatable {
    public var id: String
    public var frame: CGRect

    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// The set of zones and floating panels for one window in a preset.
public struct LayoutWindow: Codable, Sendable, Equatable {
    public var id: String
    public var frame: CGRect?
    public var fullScreen: Bool?
    public var zones: Zones
    public var floating: [FloatingPanelPlacement]?

    public init(
        id: String = "main",
        frame: CGRect? = nil,
        fullScreen: Bool? = nil,
        zones: Zones = Zones(),
        floating: [FloatingPanelPlacement]? = nil
    ) {
        self.id = id
        self.frame = frame
        self.fullScreen = fullScreen
        self.zones = zones
        self.floating = floating
    }

    public struct Zones: Codable, Sendable, Equatable {
        public var left: LayoutZone
        public var right: LayoutZone
        public var top: LayoutZone
        public var bottom: LayoutZone

        public init(
            left: LayoutZone = LayoutZone(),
            right: LayoutZone = LayoutZone(),
            top: LayoutZone = LayoutZone(),
            bottom: LayoutZone = LayoutZone()
        ) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }

        public func zone(at position: PanelPosition) -> LayoutZone? {
            switch position {
            case .left: return left
            case .right: return right
            case .top: return top
            case .bottom: return bottom
            case .floating, .hidden: return nil
            }
        }
    }
}

/// A named workspace layout (one of the five built-ins or a user preset).
public struct LayoutPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var builtin: Bool
    public var windows: [LayoutWindow]

    public init(id: String, name: String, builtin: Bool, windows: [LayoutWindow]) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.windows = windows
    }
}

// MARK: - Built-in presets
//
// These mirror exactly the JSON examples in `docs/panels.mdx` §3.4.1.

public extension LayoutPreset {

    static let viewerOnly = LayoutPreset(
        id: "viewer_only",
        name: "Viewer only",
        builtin: true,
        windows: [
            LayoutWindow(
                id: "main",
                frame: CGRect(x: 80, y: 80, width: 1200, height: 800),
                zones: LayoutWindow.Zones(
                    top: LayoutZone(size: 36, panels: [PanelSlot(id: "toolbar")]),
                    bottom: LayoutZone(size: 26, panels: [PanelSlot(id: "status_bar")])
                )
            )
        ]
    )

    static let browser = LayoutPreset(
        id: "browser",
        name: "Browser",
        builtin: true,
        windows: [
            LayoutWindow(
                id: "main",
                frame: CGRect(x: 80, y: 80, width: 1400, height: 900),
                zones: LayoutWindow.Zones(
                    left: LayoutZone(size: 280, panels: [PanelSlot(id: "file_panel", size: 1.0)]),
                    top: LayoutZone(size: 36, panels: [PanelSlot(id: "toolbar")]),
                    bottom: LayoutZone(size: 146, panels: [
                        PanelSlot(id: "thumbnail_strip", size: 120),
                        PanelSlot(id: "status_bar", size: 26),
                    ])
                )
            )
        ]
    )

    static let photographer = LayoutPreset(
        id: "photographer",
        name: "Photographer",
        builtin: true,
        windows: [
            LayoutWindow(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1680, height: 1050),
                zones: LayoutWindow.Zones(
                    left: LayoutZone(size: 300, panels: [PanelSlot(id: "file_tree", size: 1.0)]),
                    right: LayoutZone(size: 340, panels: [
                        PanelSlot(id: "metadata_exif", size: 0.55),
                        PanelSlot(id: "histogram", size: 0.25),
                        PanelSlot(id: "mcp_panel", size: 0.20, collapsed: true),
                    ]),
                    top: LayoutZone(size: 36, panels: [PanelSlot(id: "toolbar")]),
                    bottom: LayoutZone(size: 146, panels: [
                        PanelSlot(id: "thumbnail_strip", size: 120),
                        PanelSlot(id: "status_bar", size: 26),
                    ])
                )
            )
        ]
    )

    static let powerUser = LayoutPreset(
        id: "power_user",
        name: "Power user",
        builtin: true,
        windows: [
            LayoutWindow(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1800, height: 1100),
                zones: LayoutWindow.Zones(
                    left: LayoutZone(size: 360, panels: [
                        PanelSlot(id: "scope_panel", size: 0.35),
                        PanelSlot(id: "file_panel", size: 0.65),
                    ]),
                    right: LayoutZone(size: 360, panels: [
                        PanelSlot(id: "mcp_panel", size: 0.45),
                        PanelSlot(id: "local_storage_browser", size: 0.55),
                    ]),
                    top: LayoutZone(size: 36, panels: [PanelSlot(id: "toolbar")]),
                    bottom: LayoutZone(size: 26, panels: [PanelSlot(id: "status_bar")])
                ),
                floating: [
                    FloatingPanelPlacement(
                        id: "color_picker",
                        frame: CGRect(x: 1500, y: 700, width: 280, height: 240)
                    )
                ]
            )
        ]
    )

    static let slideshow = LayoutPreset(
        id: "slideshow",
        name: "Slideshow",
        builtin: true,
        windows: [
            LayoutWindow(
                id: "main",
                fullScreen: true,
                zones: LayoutWindow.Zones()
            )
        ]
    )

    /// Every built-in preset in the order the spec lists them.
    static let builtinPresets: [LayoutPreset] = [
        .viewerOnly, .browser, .photographer, .powerUser, .slideshow
    ]
}
