import Foundation
import CoreGraphics

/// Built-in preset identifiers and the layouts they materialize. Spec §7.
///
/// Built-in presets are re-rendered from code each launch so a schema upgrade
/// improves them automatically. User presets live on disk under
/// `layout/presets/<name>.json` (see `LayoutStore`).
public enum BuiltInPreset: String, CaseIterable, Sendable {
    case viewerOnly   = "Viewer only"
    case browser      = "Browser"
    case photographer = "Photographer"
    case powerUser    = "Power user"
    case slideshow    = "Slideshow"

    /// Keyboard shortcut index (⌃⌘1 … ⌃⌘5). Spec §7.
    public var shortcutIndex: Int {
        switch self {
        case .viewerOnly:   return 1
        case .browser:      return 2
        case .photographer: return 3
        case .powerUser:    return 4
        case .slideshow:    return 5
        }
    }

    /// Materialize the preset into a fresh `PanelLayout` value.
    public func layout() -> PanelLayout {
        switch self {
        case .viewerOnly:   return Self.viewerOnlyLayout()
        case .browser:      return Self.browserLayout()
        case .photographer: return Self.photographerLayout()
        case .powerUser:    return Self.powerUserLayout()
        case .slideshow:    return Self.viewerOnlyLayout(activePreset: Self.slideshow.rawValue)
        }
    }

    // MARK: - Layouts

    private static func viewerOnlyLayout(activePreset: String = BuiltInPreset.viewerOnly.rawValue) -> PanelLayout {
        PanelLayout(
            groups: [],
            floating: [],
            hidden: defaultHidden(),
            activePreset: activePreset
        )
    }

    private static func browserLayout() -> PanelLayout {
        PanelLayout(
            groups: [
                TabGroup(position: .top,    panelIDs: ["toolbar"],                       size: 44),
                TabGroup(position: .left,   panelIDs: ["file_panel", "scope_editor"],    size: 280),
                TabGroup(position: .bottom, panelIDs: ["gallery_strip", "status_bar"],   size: 140),
            ],
            floating: [],
            hidden: [
                "metadata":     HiddenPanelState(lastPosition: .right, lastSize: .init(width: 320, height: 600)),
                "histogram":    HiddenPanelState(lastPosition: .right, lastSize: .init(width: 320, height: 240)),
                "mcp_activity": HiddenPanelState(lastPosition: .right, lastSize: .init(width: 360, height: 480)),
            ],
            activePreset: BuiltInPreset.browser.rawValue
        )
    }

    private static func photographerLayout() -> PanelLayout {
        PanelLayout(
            groups: [
                TabGroup(position: .top,    panelIDs: ["toolbar"],                  size: 44),
                TabGroup(position: .left,   panelIDs: ["file_panel"],               size: 260),
                TabGroup(position: .right,  panelIDs: ["metadata", "histogram"],    size: 320),
                TabGroup(position: .bottom, panelIDs: ["status_bar"],               size: 28),
            ],
            floating: [],
            hidden: [
                "scope_editor":  HiddenPanelState(lastPosition: .left,   lastSize: .init(width: 280, height: 400)),
                "gallery_strip": HiddenPanelState(lastPosition: .bottom, lastSize: .init(width: 800, height: 120)),
                "mcp_activity":  HiddenPanelState(lastPosition: .right,  lastSize: .init(width: 360, height: 480)),
            ],
            activePreset: BuiltInPreset.photographer.rawValue
        )
    }

    private static func powerUserLayout() -> PanelLayout {
        PanelLayout(
            groups: [
                TabGroup(position: .top,    panelIDs: ["toolbar"],                        size: 44),
                TabGroup(position: .left,   panelIDs: ["scope_editor", "file_panel"],     size: 280),
                TabGroup(position: .right,  panelIDs: ["metadata", "mcp_activity", "histogram"], size: 360),
                TabGroup(position: .bottom, panelIDs: ["status_bar"],                     size: 28),
            ],
            floating: [],
            hidden: [
                "gallery_strip": HiddenPanelState(lastPosition: .bottom, lastSize: .init(width: 800, height: 120)),
            ],
            activePreset: BuiltInPreset.powerUser.rawValue
        )
    }

    private static func defaultHidden() -> [String: HiddenPanelState] {
        [
            "file_panel":     HiddenPanelState(lastPosition: .left,   lastSize: .init(width: 280, height: 600)),
            "scope_editor":   HiddenPanelState(lastPosition: .left,   lastSize: .init(width: 280, height: 400)),
            "gallery_strip":  HiddenPanelState(lastPosition: .bottom, lastSize: .init(width: 800, height: 120)),
            "status_bar":     HiddenPanelState(lastPosition: .bottom, lastSize: .init(width: 800, height: 28)),
            "toolbar":        HiddenPanelState(lastPosition: .top,    lastSize: .init(width: 800, height: 44)),
            "metadata":       HiddenPanelState(lastPosition: .right,  lastSize: .init(width: 320, height: 600)),
            "histogram":      HiddenPanelState(lastPosition: .right,  lastSize: .init(width: 320, height: 240)),
            "mcp_activity":   HiddenPanelState(lastPosition: .right,  lastSize: .init(width: 360, height: 480)),
        ]
    }
}

/// Catalog of all known built-in preset names, used by `LayoutStore` to
/// distinguish built-in presets (protected from overwrite/delete) from user
/// presets stored on disk.
public enum PresetCatalog {
    public static let builtInNames: Set<String> = Set(BuiltInPreset.allCases.map { $0.rawValue })

    public static func isBuiltIn(_ name: String) -> Bool {
        builtInNames.contains(name)
    }

    public static func builtIn(named name: String) -> BuiltInPreset? {
        BuiltInPreset.allCases.first { $0.rawValue == name }
    }

    /// The default preset materialized when no layout.json exists.
    public static var defaultLayout: PanelLayout {
        BuiltInPreset.browser.layout()
    }
}
