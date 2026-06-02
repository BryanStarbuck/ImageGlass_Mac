import Foundation

/// Diagnostic issues reported when validating a theme pack against the
/// `docs/theme-pack.mdx` spec. Validation is non-fatal: a pack with
/// warnings still loads and runs (the icon resolver falls back to defaults),
/// but the Settings UI surfaces these to authors so they can clean up
/// their pack before distribution.
public struct ThemePackIssue: Equatable, Sendable {

    public enum Severity: String, Sendable {
        /// A spec-required field is missing or malformed; the pack may
        /// still partially load via lenient decoding + icon fallbacks.
        case warning
        /// A purely advisory note — naming convention, optional metadata.
        case info
    }

    public enum Code: String, Sendable {
        /// Folder name does not follow `<theme-name>.<author-name>`.
        case folderNameConvention
        /// `_Metadata.Version` is not `"9.0"` (the current spec config version).
        case metadataVersionMismatch
        /// `Info.Name` is empty.
        case infoNameMissing
        /// `Info.Author` is missing — spec lists author name as part of `Info`.
        case infoAuthorMissing
        /// `Settings.PreviewImage` is set but the file doesn't exist in the
        /// theme folder.
        case previewImageMissing
        /// `Settings.PreviewImage` filename has an extension the spec
        /// does not document (spec says `.webp` or `.jpg`; we also accept
        /// `.jpeg` and `.png` to be lenient).
        case previewImageExtensionUnknown
        /// `Settings.AppLogo` is set but the file doesn't exist.
        case appLogoMissing
        /// A `ToolbarIcons` slot is mapped to a filename that doesn't
        /// resolve to a file in the theme folder. ImageGlass will fall
        /// back to the default icon at runtime.
        case toolbarIconFileMissing
        /// A `ToolbarIcons` slot filename does not end in `.svg`. The
        /// spec mandates SVG icons.
        case toolbarIconNotSVG
    }

    public let severity: Severity
    public let code: Code
    public let message: String

    public init(severity: Severity, code: Code, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

/// Static validator for `.igtheme` packs. Pure functions over a
/// ``ThemePack`` value — no I/O beyond existence checks the pack itself
/// already performs.
public enum ThemePackValidator {

    /// Current `_Metadata.Version` documented in `docs/theme-pack.mdx`.
    public static let currentConfigVersion = "9.0"

    /// Preview image extensions the spec calls out, plus the lenient set
    /// the loader actually accepts. Lowercase, no leading dot.
    public static let acceptedPreviewExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]

    /// Returns the list of issues found in `pack`. Empty array means the
    /// pack passes every check.
    public static func validate(_ pack: ThemePack) -> [ThemePackIssue] {
        var issues: [ThemePackIssue] = []

        // 1. Folder-name convention `<theme-name>.<author-name>`.
        if !isValidFolderName(pack.folderName) {
            issues.append(.init(
                severity: .info,
                code: .folderNameConvention,
                message: "Folder name '\(pack.folderName)' does not follow the spec's '<theme-name>.<author-name>' convention."
            ))
        }

        // 2. Metadata version.
        if pack.manifest.metadata.version != currentConfigVersion {
            issues.append(.init(
                severity: .warning,
                code: .metadataVersionMismatch,
                message: "_Metadata.Version is '\(pack.manifest.metadata.version)' — expected '\(currentConfigVersion)'."
            ))
        }

        // 3. Info.Name.
        if pack.manifest.info.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(
                severity: .warning,
                code: .infoNameMissing,
                message: "Info.Name is empty."
            ))
        }

        // 4. Info.Author (the spec lists "author name" as part of Info).
        if pack.manifest.info.author?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            issues.append(.init(
                severity: .info,
                code: .infoAuthorMissing,
                message: "Info.Author is missing — the spec recommends declaring an author name."
            ))
        }

        // 5. Preview image.
        if let preview = pack.manifest.settings.previewImage, !preview.isEmpty {
            let url = pack.folder.appendingPathComponent(preview)
            if !FileManager.default.fileExists(atPath: url.path) {
                issues.append(.init(
                    severity: .warning,
                    code: .previewImageMissing,
                    message: "Settings.PreviewImage '\(preview)' does not exist in the theme folder."
                ))
            }
            let ext = (preview as NSString).pathExtension.lowercased()
            if !ext.isEmpty, !acceptedPreviewExtensions.contains(ext) {
                issues.append(.init(
                    severity: .info,
                    code: .previewImageExtensionUnknown,
                    message: "Settings.PreviewImage extension '.\(ext)' is not in the documented set (\(acceptedPreviewExtensions.sorted().joined(separator: ", )")))."
                ))
            }
        }

        // 6. App logo.
        if let logo = pack.manifest.settings.appLogo, !logo.isEmpty {
            let url = pack.folder.appendingPathComponent(logo)
            if !FileManager.default.fileExists(atPath: url.path) {
                issues.append(.init(
                    severity: .warning,
                    code: .appLogoMissing,
                    message: "Settings.AppLogo '\(logo)' does not exist in the theme folder."
                ))
            }
        }

        // 7. Toolbar icons — missing files + non-SVG filenames.
        for slot in ThemeIconSlot.allCases {
            guard let filename = pack.iconFilename(for: slot), !filename.isEmpty else { continue }
            let url = pack.folder.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                issues.append(.init(
                    severity: .warning,
                    code: .toolbarIconFileMissing,
                    message: "ToolbarIcons.\(slot.rawValue) references '\(filename)' which does not exist (ImageGlass will fall back to the default)."
                ))
            }
            let ext = (filename as NSString).pathExtension.lowercased()
            if ext != "svg" {
                issues.append(.init(
                    severity: .info,
                    code: .toolbarIconNotSVG,
                    message: "ToolbarIcons.\(slot.rawValue) references '\(filename)' — the spec mandates SVG icons."
                ))
            }
        }

        return issues
    }

    /// Returns `true` if the folder name follows `<theme-name>.<author-name>`
    /// (one dot separator, both halves non-empty).
    public static func isValidFolderName(_ name: String) -> Bool {
        // Exactly one `.` separator — the spec's example is `Kobe.Duong-Dieu-Phap`.
        // Author names may contain hyphens; theme names rarely do; neither
        // contains a `.` so a single dot is the right cut.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && !parts[1].isEmpty
    }
}

public extension ThemePack {
    /// Validate this pack against the `docs/theme-pack.mdx` spec.
    /// Returns an empty array when the pack is fully spec-compliant.
    func validate() -> [ThemePackIssue] {
        ThemePackValidator.validate(self)
    }
}
