import Foundation

/// A loaded `.igtheme` — manifest plus the on-disk folder containing the
/// SVG icons and preview image.
///
/// `ThemePack` is the value type the rest of the app passes around. It is
/// stable across the running app's lifetime; rebuilds happen on
/// install / uninstall / external file changes.
///
/// The higher-level Themes API (catalog, currentTheme, switching) is
/// owned by the themes.mdx agent — this type only describes the loaded
/// pack format.
public struct ThemePack: Equatable, Sendable {

    /// Folder on disk holding `igtheme.json`, icons, preview image.
    /// Use this when resolving relative filenames from the manifest.
    public let folder: URL

    /// Convention: `<theme-name>.<author-name>`. Used as the install dir
    /// name under `~/Library/Application Support/ImageGlass/themes/`.
    public let folderName: String

    public let manifest: ThemeManifest

    public init(folder: URL, manifest: ThemeManifest) {
        self.folder = folder
        self.folderName = folder.lastPathComponent
        self.manifest = manifest
    }

    // MARK: - Convenience accessors

    public var displayName: String { manifest.info.name }

    public var author: String? { manifest.info.author }

    public var version: String { manifest.info.version }

    public var isDarkMode: Bool { manifest.settings.isDarkMode }

    /// URL of the preview image (webp/jpg/png) for this theme, or `nil`
    /// when the manifest doesn't reference one or the file is missing.
    public var previewImageURL: URL? {
        guard let name = manifest.settings.previewImage, !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// URL of the app-logo image for this theme, or `nil` when missing.
    public var appLogoURL: URL? {
        guard let name = manifest.settings.appLogo, !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Filename of the SVG mapped to `slot`, or `nil` if the manifest
    /// has no mapping. Existence on disk is NOT checked here — use
    /// ``iconURL(for:)`` for that.
    public func iconFilename(for slot: ThemeIconSlot) -> String? {
        manifest.toolbarIcons.filename(forSlot: slot.rawValue)
    }

    /// URL of the SVG mapped to `slot` if both the manifest references it
    /// and the file exists in the theme folder. Returns `nil` otherwise —
    /// the caller is responsible for any fallback strategy.
    public func iconURL(for slot: ThemeIconSlot) -> URL? {
        guard let name = iconFilename(for: slot), !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the slots the manifest references but whose files are
    /// missing in the theme folder. Useful for Settings UI warnings.
    public func missingIconFiles() -> [ThemeIconSlot] {
        ThemeIconSlot.allCases.filter { slot in
            guard let name = iconFilename(for: slot), !name.isEmpty else { return false }
            let url = folder.appendingPathComponent(name)
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Slots the manifest has no entry for at all.
    public func unmappedIconSlots() -> [ThemeIconSlot] {
        ThemeIconSlot.allCases.filter { iconFilename(for: $0) == nil }
    }

    // MARK: - Loading

    /// Load a theme pack from an unpacked theme folder containing
    /// `igtheme.json`. Use ``ThemeInstaller`` to handle `.igtheme` archives.
    public static func load(fromFolder folder: URL) throws -> ThemePack {
        let manifestURL = folder.appendingPathComponent("igtheme.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ThemePackError.manifestMissing(folder: folder)
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        do {
            let manifest = try decoder.decode(ThemeManifest.self, from: data)
            return ThemePack(folder: folder, manifest: manifest)
        } catch {
            throw ThemePackError.manifestInvalid(folder: folder, underlying: error)
        }
    }
}

// MARK: - Errors

public enum ThemePackError: Error, CustomStringConvertible, Equatable {
    case manifestMissing(folder: URL)
    case manifestInvalid(folder: URL, underlying: Error)
    case archiveExtractionFailed(archive: URL, exitCode: Int32, stderr: String)
    case archiveContainsNoThemeFolder(archive: URL)
    case archiveContainsMultipleThemeFolders(archive: URL, found: [String])
    case unzipUnavailable
    case themeNotInstalled(folderName: String)

    public var description: String {
        switch self {
        case .manifestMissing(let folder):
            return "igtheme.json missing in folder: \(folder.path)"
        case .manifestInvalid(let folder, let underlying):
            return "igtheme.json invalid in folder \(folder.path): \(underlying)"
        case .archiveExtractionFailed(let archive, let code, let stderr):
            return "Failed to extract \(archive.lastPathComponent) (exit \(code)): \(stderr)"
        case .archiveContainsNoThemeFolder(let archive):
            return "Archive \(archive.lastPathComponent) does not contain a theme folder with igtheme.json"
        case .archiveContainsMultipleThemeFolders(let archive, let found):
            return "Archive \(archive.lastPathComponent) contains multiple theme folders: \(found)"
        case .unzipUnavailable:
            return "/usr/bin/unzip is not available on this system"
        case .themeNotInstalled(let folderName):
            return "No installed theme found with folder name: \(folderName)"
        }
    }

    public static func == (lhs: ThemePackError, rhs: ThemePackError) -> Bool {
        // Equatable required for tests; underlying Error isn't Equatable so
        // we compare on the case + identifying associated values only.
        switch (lhs, rhs) {
        case (.manifestMissing(let a), .manifestMissing(let b)):
            return a == b
        case (.manifestInvalid(let a, _), .manifestInvalid(let b, _)):
            return a == b
        case (.archiveExtractionFailed(let a1, let c1, _), .archiveExtractionFailed(let a2, let c2, _)):
            return a1 == a2 && c1 == c2
        case (.archiveContainsNoThemeFolder(let a), .archiveContainsNoThemeFolder(let b)):
            return a == b
        case (.archiveContainsMultipleThemeFolders(let a1, let f1), .archiveContainsMultipleThemeFolders(let a2, let f2)):
            return a1 == a2 && f1 == f2
        case (.unzipUnavailable, .unzipUnavailable):
            return true
        case (.themeNotInstalled(let a), .themeNotInstalled(let b)):
            return a == b
        default:
            return false
        }
    }
}

// Install location (`AppPaths.themesDir`) is declared in ThemeCatalog.swift.
// Both subsystems agree on the same install root.
