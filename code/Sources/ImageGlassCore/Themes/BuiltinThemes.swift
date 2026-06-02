import Foundation

/// Themes that ship in code so first-launch always has something usable
/// even before any `.igtheme` packs are installed.
public enum BuiltinThemes {

    public static let dark: Theme = Theme(
        name: Theme.Builtin.darkName,
        info: .init(
            name: "Default Dark",
            version: "1.0",
            description: "Built-in dark theme that ships with ImageGlass for Mac.",
            author: "ImageGlass",
            contact: "https://imageglass.org"
        ),
        settings: .init(
            isDarkMode: true,
            showNavArrows: true,
            appLogo: nil,
            previewImage: nil
        ),
        colors: .init(
            accent: "system",
            viewerBackground: "#1E1E1E",
            toolbarBackground: "#252525",
            galleryBackground: "#1A1A1A",
            menuBackground: "#252525",
            foreground: "#F0F0F0"
        ),
        toolbarIcons: [:],
        folderURL: nil
    )

    public static let light: Theme = Theme(
        name: Theme.Builtin.lightName,
        info: .init(
            name: "Default Light",
            version: "1.0",
            description: "Built-in light theme that ships with ImageGlass for Mac.",
            author: "ImageGlass",
            contact: "https://imageglass.org"
        ),
        settings: .init(
            isDarkMode: false,
            showNavArrows: true,
            appLogo: nil,
            previewImage: nil
        ),
        colors: .init(
            accent: "system",
            viewerBackground: "#F5F5F5",
            toolbarBackground: "#FFFFFF",
            galleryBackground: "#F0F0F0",
            menuBackground: "#FFFFFF",
            foreground: "#1A1A1A"
        ),
        toolbarIcons: [:],
        folderURL: nil
    )

    /// Returned in catalog listings so the user always sees the built-ins
    /// alongside any installed packs.
    public static var all: [Theme] { [dark, light] }

    /// Default theme picked on first launch when no selection has been made.
    public static var defaultTheme: Theme { dark }

    /// Look up a built-in by stable name.
    public static func named(_ name: String) -> Theme? {
        switch name {
        case Theme.Builtin.darkName: return dark
        case Theme.Builtin.lightName: return light
        default: return nil
        }
    }
}
