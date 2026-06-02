import Foundation

/// Canonical list of toolbar icon slots. Used for fallback resolution and
/// validation. Mirrors the `ToolbarIcons` typed properties on
/// ``ThemeManifest``.
public enum ThemeIconSlot: String, CaseIterable, Sendable {
    // Zoom controls
    case zoomIn = "ZoomIn"
    case zoomOut = "ZoomOut"
    case resetZoom = "ResetZoom"
    case autoZoom = "AutoZoom"
    case lockZoom = "LockZoom"
    case scaleToFit = "ScaleToFit"
    case scaleToFill = "ScaleToFill"
    case scaleToWidth = "ScaleToWidth"
    case scaleToHeight = "ScaleToHeight"

    // Navigation
    case viewPrevious = "ViewPrevious"
    case viewNext = "ViewNext"
    case viewFirst = "ViewFirst"
    case viewLast = "ViewLast"
    case framePrevious = "FramePrevious"
    case frameNext = "FrameNext"

    // Image manipulation
    case rotateLeft = "RotateLeft"
    case rotateRight = "RotateRight"
    case flipHorizontal = "FlipHorizontal"
    case flipVertical = "FlipVertical"
    case crop = "Crop"

    // View modes
    case fullScreen = "FullScreen"
    case frameless = "Frameless"
    case windowFit = "WindowFit"
    case slideshow = "Slideshow"

    // Utility
    case colorPicker = "ColorPicker"
    case colorChannels = "ColorChannels"
    case gallery = "Gallery"
    case toolbar = "Toolbar"
    case settings = "Settings"
    case about = "About"

    // File operations
    case openFile = "OpenFile"
    case refresh = "Refresh"
    case delete = "Delete"
    case save = "Save"
    case saveAs = "SaveAs"
    case print = "Print"
    case share = "Share"
    case copy = "Copy"
    case cut = "Cut"
    case paste = "Paste"
    case edit = "Edit"
}

/// Resolves an icon-slot lookup to a concrete file URL on disk.
///
/// Resolution order, per spec §"Required Icons":
///   1. The current theme's mapping for that slot, if both the manifest
///      entry and the file exist inside the theme folder.
///   2. The default-theme fallback, if a default theme is installed and
///      it provides this slot.
///   3. `nil` — caller renders an SF Symbol or a built-in resource.
public struct ThemeIconResolver: Sendable {

    /// Directory containing the active theme's files (`igtheme.json`,
    /// SVGs, preview image).
    public let activeThemeFolder: URL

    public let activeManifest: ThemeManifest

    /// Optional default-theme folder used when the active theme is missing
    /// a slot. Typically the theme named "Default" in the install dir.
    public let defaultThemeFolder: URL?

    public let defaultManifest: ThemeManifest?

    public init(
        activeThemeFolder: URL,
        activeManifest: ThemeManifest,
        defaultThemeFolder: URL? = nil,
        defaultManifest: ThemeManifest? = nil
    ) {
        self.activeThemeFolder = activeThemeFolder
        self.activeManifest = activeManifest
        self.defaultThemeFolder = defaultThemeFolder
        self.defaultManifest = defaultManifest
    }

    /// Resolve a single slot. Returns `nil` if neither the active nor the
    /// default theme provides a usable file for it.
    public func iconURL(for slot: ThemeIconSlot) -> URL? {
        if let url = resolve(slot: slot, manifest: activeManifest, folder: activeThemeFolder) {
            return url
        }
        if let defaultFolder = defaultThemeFolder,
           let defaultManifest = defaultManifest,
           let url = resolve(slot: slot, manifest: defaultManifest, folder: defaultFolder) {
            return url
        }
        return nil
    }

    /// Returns `true` if the active theme provides this slot AND the file
    /// exists on disk. Useful for tests and the Settings UI which want to
    /// surface missing-icon warnings.
    public func activeThemeHas(slot: ThemeIconSlot) -> Bool {
        resolve(slot: slot, manifest: activeManifest, folder: activeThemeFolder) != nil
    }

    /// `true` if the resolver had to fall back to the default theme for this
    /// slot. Returns `false` if the active theme covers it OR if even the
    /// default doesn't have it (i.e. the call returned `nil`).
    public func usedFallback(for slot: ThemeIconSlot) -> Bool {
        if activeThemeHas(slot: slot) { return false }
        return iconURL(for: slot) != nil
    }

    private func resolve(slot: ThemeIconSlot, manifest: ThemeManifest, folder: URL) -> URL? {
        guard let filename = manifest.toolbarIcons.filename(forSlot: slot.rawValue),
              !filename.isEmpty else {
            return nil
        }
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
