import Foundation

/// `igtheme.json` manifest — the canonical schema for a `.igtheme` pack.
///
/// Mirrors the spec in `docs/theme-pack.mdx`. Five top-level sections:
///   `_Metadata`, `Info`, `Settings`, `Colors`, `ToolbarIcons`.
///
/// Decoder is lenient: any unknown icon slot is preserved in
/// `ToolbarIcons.extra` and any unknown color in `Colors.extra` so we can
/// round-trip themes authored by third parties without losing fields.
public struct ThemeManifest: Codable, Equatable, Sendable {

    public var metadata: Metadata
    public var info: Info
    public var settings: Settings
    public var colors: Colors
    public var toolbarIcons: ToolbarIcons

    // The on-disk JSON uses underscored / PascalCase keys per upstream
    // ImageGlass. We map them explicitly so Swift property names stay idiomatic.
    private enum CodingKeys: String, CodingKey {
        case metadata = "_Metadata"
        case info = "Info"
        case settings = "Settings"
        case colors = "Colors"
        case toolbarIcons = "ToolbarIcons"
    }

    public init(
        metadata: Metadata,
        info: Info,
        settings: Settings,
        colors: Colors,
        toolbarIcons: ToolbarIcons
    ) {
        self.metadata = metadata
        self.info = info
        self.settings = settings
        self.colors = colors
        self.toolbarIcons = toolbarIcons
    }

    // MARK: - _Metadata

    public struct Metadata: Codable, Equatable, Sendable {
        /// Currently `"9.0"`.
        public var version: String
        public var description: String?

        private enum CodingKeys: String, CodingKey {
            case version = "Version"
            case description = "Description"
        }

        public init(version: String = "9.0", description: String? = nil) {
            self.version = version
            self.description = description
        }

        // Lenient: older themes sometimes omit Version.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "9.0"
            self.description = try c.decodeIfPresent(String.self, forKey: .description)
        }
    }

    // MARK: - Info

    public struct Info: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var description: String?
        public var author: String?
        public var email: String?
        public var website: String?

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case version = "Version"
            case description = "Description"
            case author = "Author"
            case email = "Email"
            case website = "Website"
        }

        public init(
            name: String,
            version: String = "1.0",
            description: String? = nil,
            author: String? = nil,
            email: String? = nil,
            website: String? = nil
        ) {
            self.name = name
            self.version = version
            self.description = description
            self.author = author
            self.email = email
            self.website = website
        }

        // Lenient: third-party themes sometimes omit Version. `Name` stays
        // required — a theme with no name is meaningless.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
            self.description = try c.decodeIfPresent(String.self, forKey: .description)
            self.author = try c.decodeIfPresent(String.self, forKey: .author)
            self.email = try c.decodeIfPresent(String.self, forKey: .email)
            self.website = try c.decodeIfPresent(String.self, forKey: .website)
        }
    }

    // MARK: - Settings

    public struct Settings: Codable, Equatable, Sendable {
        public var isDarkMode: Bool
        public var isShowTitlebar: Bool
        public var isShowToolbar: Bool
        public var isShowGallery: Bool
        public var isShowNavButtons: Bool
        /// Relative filename of the in-app logo SVG/PNG.
        public var appLogo: String?
        /// Relative filename of the preview image (webp/jpg/png).
        public var previewImage: String?

        private enum CodingKeys: String, CodingKey {
            case isDarkMode = "IsDarkMode"
            case isShowTitlebar = "IsShowTitlebar"
            case isShowToolbar = "IsShowToolbar"
            case isShowGallery = "IsShowGallery"
            case isShowNavButtons = "IsShowNavButtons"
            case appLogo = "AppLogo"
            case previewImage = "PreviewImage"
        }

        public init(
            isDarkMode: Bool = false,
            isShowTitlebar: Bool = true,
            isShowToolbar: Bool = true,
            isShowGallery: Bool = true,
            isShowNavButtons: Bool = true,
            appLogo: String? = nil,
            previewImage: String? = nil
        ) {
            self.isDarkMode = isDarkMode
            self.isShowTitlebar = isShowTitlebar
            self.isShowToolbar = isShowToolbar
            self.isShowGallery = isShowGallery
            self.isShowNavButtons = isShowNavButtons
            self.appLogo = appLogo
            self.previewImage = previewImage
        }

        // Lenient decoder: third-party themes commonly omit visibility flags.
        // Missing → app default; only `IsDarkMode` is treated as required-ish
        // (defaults to false).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.isDarkMode = try c.decodeIfPresent(Bool.self, forKey: .isDarkMode) ?? false
            self.isShowTitlebar = try c.decodeIfPresent(Bool.self, forKey: .isShowTitlebar) ?? true
            self.isShowToolbar = try c.decodeIfPresent(Bool.self, forKey: .isShowToolbar) ?? true
            self.isShowGallery = try c.decodeIfPresent(Bool.self, forKey: .isShowGallery) ?? true
            self.isShowNavButtons = try c.decodeIfPresent(Bool.self, forKey: .isShowNavButtons) ?? true
            self.appLogo = try c.decodeIfPresent(String.self, forKey: .appLogo)
            self.previewImage = try c.decodeIfPresent(String.self, forKey: .previewImage)
        }
    }

    // MARK: - Colors

    /// All color values may be either a 6/8-digit HEX string (`#RRGGBB` /
    /// `#RRGGBBAA`) or the special token `"system"` to follow the OS
    /// accent color. Decoded values are normalized via ``ThemeColor``.
    public struct Colors: Codable, Equatable, Sendable {
        public var backColor: ThemeColor?
        public var titleBarColor: ThemeColor?
        public var toolbarBackground: ThemeColor?
        public var toolbarItemActive: ThemeColor?
        public var toolbarItemHover: ThemeColor?
        public var toolbarItemSelected: ThemeColor?
        public var toolbarTextColor: ThemeColor?
        public var menuBackground: ThemeColor?
        public var menuTextColor: ThemeColor?
        public var galleryBackground: ThemeColor?
        public var galleryItemActive: ThemeColor?
        public var galleryItemHover: ThemeColor?
        public var galleryItemSelected: ThemeColor?
        public var galleryTextColor: ThemeColor?
        public var accentColor: ThemeColor?

        /// Any unknown color keys round-trip through here so we don't lose
        /// fields from future spec versions.
        public var extra: [String: ThemeColor]

        nonisolated(unsafe) private static let knownKeys: [String: WritableKeyPath<Colors, ThemeColor?>] = [
            "BackColor": \Colors.backColor,
            "TitleBarColor": \Colors.titleBarColor,
            "ToolbarBackground": \Colors.toolbarBackground,
            "ToolbarItemActive": \Colors.toolbarItemActive,
            "ToolbarItemHover": \Colors.toolbarItemHover,
            "ToolbarItemSelected": \Colors.toolbarItemSelected,
            "ToolbarTextColor": \Colors.toolbarTextColor,
            "MenuBackground": \Colors.menuBackground,
            "MenuTextColor": \Colors.menuTextColor,
            "GalleryBackground": \Colors.galleryBackground,
            "GalleryItemActive": \Colors.galleryItemActive,
            "GalleryItemHover": \Colors.galleryItemHover,
            "GalleryItemSelected": \Colors.galleryItemSelected,
            "GalleryTextColor": \Colors.galleryTextColor,
            "AccentColor": \Colors.accentColor,
        ]

        public init(
            backColor: ThemeColor? = nil,
            titleBarColor: ThemeColor? = nil,
            toolbarBackground: ThemeColor? = nil,
            toolbarItemActive: ThemeColor? = nil,
            toolbarItemHover: ThemeColor? = nil,
            toolbarItemSelected: ThemeColor? = nil,
            toolbarTextColor: ThemeColor? = nil,
            menuBackground: ThemeColor? = nil,
            menuTextColor: ThemeColor? = nil,
            galleryBackground: ThemeColor? = nil,
            galleryItemActive: ThemeColor? = nil,
            galleryItemHover: ThemeColor? = nil,
            galleryItemSelected: ThemeColor? = nil,
            galleryTextColor: ThemeColor? = nil,
            accentColor: ThemeColor? = nil,
            extra: [String: ThemeColor] = [:]
        ) {
            self.backColor = backColor
            self.titleBarColor = titleBarColor
            self.toolbarBackground = toolbarBackground
            self.toolbarItemActive = toolbarItemActive
            self.toolbarItemHover = toolbarItemHover
            self.toolbarItemSelected = toolbarItemSelected
            self.toolbarTextColor = toolbarTextColor
            self.menuBackground = menuBackground
            self.menuTextColor = menuTextColor
            self.galleryBackground = galleryBackground
            self.galleryItemActive = galleryItemActive
            self.galleryItemHover = galleryItemHover
            self.galleryItemSelected = galleryItemSelected
            self.galleryTextColor = galleryTextColor
            self.accentColor = accentColor
            self.extra = extra
        }

        // Custom Codable so unknown keys land in `extra`.

        private struct DynKey: CodingKey {
            var stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        public init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: DynKey.self)
            for key in container.allKeys {
                let value = try container.decode(ThemeColor.self, forKey: key)
                if let kp = Self.knownKeys[key.stringValue] {
                    self[keyPath: kp] = value
                } else {
                    self.extra[key.stringValue] = value
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynKey.self)
            for (name, kp) in Self.knownKeys {
                if let value = self[keyPath: kp] {
                    try container.encode(value, forKey: DynKey(stringValue: name))
                }
            }
            for (name, value) in extra {
                try container.encode(value, forKey: DynKey(stringValue: name))
            }
        }
    }

    // MARK: - ToolbarIcons

    /// 40+ icon slots per the spec. Values are bare filenames relative to the
    /// theme folder (e.g. `"zoom_in.svg"`).
    ///
    /// Unknown slots are preserved in `extra` so we round-trip cleanly.
    public struct ToolbarIcons: Codable, Equatable, Sendable {
        // Zoom controls
        public var zoomIn: String?
        public var zoomOut: String?
        public var resetZoom: String?
        public var autoZoom: String?
        public var lockZoom: String?
        public var scaleToFit: String?
        public var scaleToFill: String?
        public var scaleToWidth: String?
        public var scaleToHeight: String?

        // Navigation
        public var viewPrevious: String?
        public var viewNext: String?
        public var viewFirst: String?
        public var viewLast: String?
        public var framePrevious: String?
        public var frameNext: String?

        // Image manipulation
        public var rotateLeft: String?
        public var rotateRight: String?
        public var flipHorizontal: String?
        public var flipVertical: String?
        public var crop: String?

        // View modes
        public var fullScreen: String?
        public var frameless: String?
        public var windowFit: String?
        public var slideshow: String?

        // Utility
        public var colorPicker: String?
        public var colorChannels: String?
        public var gallery: String?
        public var toolbar: String?
        public var settings: String?
        public var about: String?

        // File operations
        public var openFile: String?
        public var refresh: String?
        public var delete: String?
        public var save: String?
        public var saveAs: String?
        public var print: String?
        public var share: String?
        public var copy: String?
        public var cut: String?
        public var paste: String?
        public var edit: String?

        // Extras we don't have a typed slot for yet.
        public var extra: [String: String]

        nonisolated(unsafe) private static let knownKeys: [String: WritableKeyPath<ToolbarIcons, String?>] = [
            "ZoomIn": \ToolbarIcons.zoomIn,
            "ZoomOut": \ToolbarIcons.zoomOut,
            "ResetZoom": \ToolbarIcons.resetZoom,
            "AutoZoom": \ToolbarIcons.autoZoom,
            "LockZoom": \ToolbarIcons.lockZoom,
            "ScaleToFit": \ToolbarIcons.scaleToFit,
            "ScaleToFill": \ToolbarIcons.scaleToFill,
            "ScaleToWidth": \ToolbarIcons.scaleToWidth,
            "ScaleToHeight": \ToolbarIcons.scaleToHeight,
            "ViewPrevious": \ToolbarIcons.viewPrevious,
            "ViewNext": \ToolbarIcons.viewNext,
            "ViewFirst": \ToolbarIcons.viewFirst,
            "ViewLast": \ToolbarIcons.viewLast,
            "FramePrevious": \ToolbarIcons.framePrevious,
            "FrameNext": \ToolbarIcons.frameNext,
            "RotateLeft": \ToolbarIcons.rotateLeft,
            "RotateRight": \ToolbarIcons.rotateRight,
            "FlipHorizontal": \ToolbarIcons.flipHorizontal,
            "FlipVertical": \ToolbarIcons.flipVertical,
            "Crop": \ToolbarIcons.crop,
            "FullScreen": \ToolbarIcons.fullScreen,
            "Frameless": \ToolbarIcons.frameless,
            "WindowFit": \ToolbarIcons.windowFit,
            "Slideshow": \ToolbarIcons.slideshow,
            "ColorPicker": \ToolbarIcons.colorPicker,
            "ColorChannels": \ToolbarIcons.colorChannels,
            "Gallery": \ToolbarIcons.gallery,
            "Toolbar": \ToolbarIcons.toolbar,
            "Settings": \ToolbarIcons.settings,
            "About": \ToolbarIcons.about,
            "OpenFile": \ToolbarIcons.openFile,
            "Refresh": \ToolbarIcons.refresh,
            "Delete": \ToolbarIcons.delete,
            "Save": \ToolbarIcons.save,
            "SaveAs": \ToolbarIcons.saveAs,
            "Print": \ToolbarIcons.print,
            "Share": \ToolbarIcons.share,
            "Copy": \ToolbarIcons.copy,
            "Cut": \ToolbarIcons.cut,
            "Paste": \ToolbarIcons.paste,
            "Edit": \ToolbarIcons.edit,
        ]

        public init(
            zoomIn: String? = nil, zoomOut: String? = nil, resetZoom: String? = nil,
            autoZoom: String? = nil, lockZoom: String? = nil,
            scaleToFit: String? = nil, scaleToFill: String? = nil,
            scaleToWidth: String? = nil, scaleToHeight: String? = nil,
            viewPrevious: String? = nil, viewNext: String? = nil,
            viewFirst: String? = nil, viewLast: String? = nil,
            framePrevious: String? = nil, frameNext: String? = nil,
            rotateLeft: String? = nil, rotateRight: String? = nil,
            flipHorizontal: String? = nil, flipVertical: String? = nil, crop: String? = nil,
            fullScreen: String? = nil, frameless: String? = nil,
            windowFit: String? = nil, slideshow: String? = nil,
            colorPicker: String? = nil, colorChannels: String? = nil,
            gallery: String? = nil, toolbar: String? = nil,
            settings: String? = nil, about: String? = nil,
            openFile: String? = nil, refresh: String? = nil, delete: String? = nil,
            save: String? = nil, saveAs: String? = nil, print: String? = nil,
            share: String? = nil, copy: String? = nil, cut: String? = nil,
            paste: String? = nil, edit: String? = nil,
            extra: [String: String] = [:]
        ) {
            self.zoomIn = zoomIn; self.zoomOut = zoomOut; self.resetZoom = resetZoom
            self.autoZoom = autoZoom; self.lockZoom = lockZoom
            self.scaleToFit = scaleToFit; self.scaleToFill = scaleToFill
            self.scaleToWidth = scaleToWidth; self.scaleToHeight = scaleToHeight
            self.viewPrevious = viewPrevious; self.viewNext = viewNext
            self.viewFirst = viewFirst; self.viewLast = viewLast
            self.framePrevious = framePrevious; self.frameNext = frameNext
            self.rotateLeft = rotateLeft; self.rotateRight = rotateRight
            self.flipHorizontal = flipHorizontal; self.flipVertical = flipVertical
            self.crop = crop
            self.fullScreen = fullScreen; self.frameless = frameless
            self.windowFit = windowFit; self.slideshow = slideshow
            self.colorPicker = colorPicker; self.colorChannels = colorChannels
            self.gallery = gallery; self.toolbar = toolbar
            self.settings = settings; self.about = about
            self.openFile = openFile; self.refresh = refresh; self.delete = delete
            self.save = save; self.saveAs = saveAs; self.print = print
            self.share = share; self.copy = copy; self.cut = cut
            self.paste = paste; self.edit = edit
            self.extra = extra
        }

        private struct DynKey: CodingKey {
            var stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        public init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: DynKey.self)
            for key in container.allKeys {
                let value = try container.decode(String.self, forKey: key)
                if let kp = Self.knownKeys[key.stringValue] {
                    self[keyPath: kp] = value
                } else {
                    self.extra[key.stringValue] = value
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynKey.self)
            for (name, kp) in Self.knownKeys {
                if let value = self[keyPath: kp] {
                    try container.encode(value, forKey: DynKey(stringValue: name))
                }
            }
            for (name, value) in extra {
                try container.encode(value, forKey: DynKey(stringValue: name))
            }
        }

        /// Lookup by canonical slot name (e.g. `"ZoomIn"`), checking both
        /// the typed properties and the `extra` dictionary.
        public func filename(forSlot slot: String) -> String? {
            if let kp = Self.knownKeys[slot] {
                return self[keyPath: kp]
            }
            return extra[slot]
        }
    }
}

// MARK: - ThemeColor

/// A color value from a theme manifest. Either a HEX string or the special
/// token `system`. Strings round-trip through Codable as plain strings.
public enum ThemeColor: Equatable, Sendable, Codable {
    /// Follow the OS accent color (`AppKit.NSColor.controlAccentColor`).
    case system
    /// Hex value, normalized to lowercase with leading `#`.
    /// Six digits (`#rrggbb`) or eight digits (`#rrggbbaa`).
    case hex(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.lowercased() == "system" {
            self = .system
            return
        }
        let normalized = Self.normalizeHex(raw)
        guard Self.isValidHex(normalized) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid theme color value: \(raw)"
            )
        }
        self = .hex(normalized)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .system:
            try container.encode("system")
        case .hex(let value):
            try container.encode(value)
        }
    }

    public var rawValue: String {
        switch self {
        case .system: return "system"
        case .hex(let v): return v
        }
    }

    /// True if this resolves through the OS accent color (no fixed RGB).
    public var followsSystemAccent: Bool {
        if case .system = self { return true }
        return false
    }

    private static func normalizeHex(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if !s.hasPrefix("#") { s = "#" + s }
        return s
    }

    private static func isValidHex(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let body = s.dropFirst()
        guard body.count == 6 || body.count == 8 else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }
}
