import Foundation

/// Plain-data representation of a theme installed on disk.
/// Mirrors the on-disk `igtheme.json` manifest sections from `theme-pack.mdx`:
/// `Info`, `Settings`, `Colors`, `ToolbarIcons`.
///
/// This type intentionally does NOT know how to parse a `.igtheme` archive —
/// the theme-pack loader (separate agent) owns that. We expose a clean Codable
/// surface so the pack loader can populate a `Theme` and hand it off.
public struct Theme: Codable, Equatable, Sendable, Identifiable {

    /// Unique name (folder-style `<theme-name>.<author-name>` for installed
    /// packs, or a short tag like `default-dark` for built-ins).
    public var name: String

    public var info: Info
    public var settings: Settings
    public var colors: Colors

    /// Maps a logical toolbar function (e.g. `zoom_in`, `rotate_left`) to a
    /// filename inside the theme folder. Empty for built-ins that use SF Symbols.
    public var toolbarIcons: [String: String]

    /// Absolute path to the theme's on-disk folder (`nil` for built-ins).
    /// Not encoded — recomputed on load.
    public var folderURL: URL?

    public var id: String { name }

    public init(
        name: String,
        info: Info,
        settings: Settings,
        colors: Colors,
        toolbarIcons: [String: String] = [:],
        folderURL: URL? = nil
    ) {
        self.name = name
        self.info = info
        self.settings = settings
        self.colors = colors
        self.toolbarIcons = toolbarIcons
        self.folderURL = folderURL
    }

    private enum CodingKeys: String, CodingKey {
        case name, info, settings, colors, toolbarIcons
    }

    // MARK: - Sub-types

    public struct Info: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var description: String
        public var author: String
        public var contact: String

        public init(
            name: String,
            version: String = "1.0",
            description: String = "",
            author: String = "",
            contact: String = ""
        ) {
            self.name = name
            self.version = version
            self.description = description
            self.author = author
            self.contact = contact
        }
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// `true` if this theme is meant for dark appearance.
        public var isDarkMode: Bool
        public var showNavArrows: Bool
        /// Filename of the in-UI logo (relative to the theme folder), or `nil`.
        public var appLogo: String?
        /// Filename of the preview image shown in the Settings UI.
        public var previewImage: String?

        public init(
            isDarkMode: Bool = false,
            showNavArrows: Bool = true,
            appLogo: String? = nil,
            previewImage: String? = nil
        ) {
            self.isDarkMode = isDarkMode
            self.showNavArrows = showNavArrows
            self.appLogo = appLogo
            self.previewImage = previewImage
        }
    }

    /// HEX color codes — stored as `#RRGGBB` or `#RRGGBBAA` strings. The
    /// special value `"system"` means "use the OS accent color".
    public struct Colors: Codable, Equatable, Sendable {
        public var accent: String
        public var viewerBackground: String
        public var toolbarBackground: String
        public var galleryBackground: String
        public var menuBackground: String
        public var foreground: String

        public init(
            accent: String = "system",
            viewerBackground: String = "#1E1E1E",
            toolbarBackground: String = "#252525",
            galleryBackground: String = "#1A1A1A",
            menuBackground: String = "#252525",
            foreground: String = "#F0F0F0"
        ) {
            self.accent = accent
            self.viewerBackground = viewerBackground
            self.toolbarBackground = toolbarBackground
            self.galleryBackground = galleryBackground
            self.menuBackground = menuBackground
            self.foreground = foreground
        }
    }
}

// MARK: - Identifiers used by built-in themes

public extension Theme {
    /// Stable names for the two built-in themes shipped in code.
    enum Builtin {
        public static let darkName = "default-dark"
        public static let lightName = "default-light"
    }
}
