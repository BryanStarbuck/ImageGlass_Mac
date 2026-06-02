import Foundation

/// Catalog of every `igcmd` subcommand defined in `docs/command-line.mdx`.
///
/// The spec is the binding contract. Each case maps 1:1 to a row in the
/// `igcmd.exe` table. Synonyms / aliases are surfaced via ``allNames``.
public enum IgCmdSubcommand: String, CaseIterable, Sendable {
    case setWallpaper          = "set-wallpaper"
    case setLockScreen         = "set-lock-screen"
    case setDefaultViewer      = "set-default-viewer"
    case removeDefaultViewer   = "remove-default-viewer"
    case exportFrames          = "export-frames"
    case quickSetup            = "quick-setup"
    case checkForUpdate        = "check-for-update"
    case installLanguages      = "install-languages"
    case installThemes         = "install-themes"
    case uninstallTheme        = "uninstall-theme"
    case setStartupBoost       = "set-startup-boost"
    case removeStartupBoost    = "remove-startup-boost"

    /// Human-readable one-liner pulled straight from the spec table.
    public var summary: String {
        switch self {
        case .setWallpaper:
            return "Set the desktop background image. `style` controls fill mode (fit, fill, stretch, tile, center)."
        case .setLockScreen:
            return "Set the lock-screen background."
        case .setDefaultViewer:
            return "Register ImageGlass as the default viewer for the given extensions."
        case .removeDefaultViewer:
            return "Unregister ImageGlass as the default viewer."
        case .exportFrames:
            return "Extract every frame from an animated or multi-frame image to separate files."
        case .quickSetup:
            return "Launch the first-run configuration wizard."
        case .checkForUpdate:
            return "Check for a newer release."
        case .installLanguages:
            return "Install one or more .iglang language packs."
        case .installThemes:
            return "Install one or more .igtheme theme packs."
        case .uninstallTheme:
            return "Remove an installed theme pack."
        case .setStartupBoost:
            return "Enable Startup Boost."
        case .removeStartupBoost:
            return "Disable Startup Boost."
        }
    }

    /// Usage line (argument signature) per the spec.
    public var usage: String {
        switch self {
        case .setWallpaper:        return "set-wallpaper <imgPath> [style]"
        case .setLockScreen:       return "set-lock-screen <imgPath>"
        case .setDefaultViewer:    return "set-default-viewer [exts] [--per-machine]"
        case .removeDefaultViewer: return "remove-default-viewer [exts] [--per-machine]"
        case .exportFrames:        return "export-frames <filePath>"
        case .quickSetup:          return "quick-setup"
        case .checkForUpdate:      return "check-for-update"
        case .installLanguages:    return "install-languages [filePaths]"
        case .installThemes:       return "install-themes [filePaths]"
        case .uninstallTheme:      return "uninstall-theme <filePath>"
        case .setStartupBoost:     return "set-startup-boost"
        case .removeStartupBoost:  return "remove-startup-boost"
        }
    }

    /// Resolve a subcommand from the verb the user typed. Case-insensitive.
    /// Underscored variants (`set_wallpaper`) and the canonical hyphenated
    /// form both resolve so users from different shells aren't tripped up.
    public static func resolve(_ verb: String) -> IgCmdSubcommand? {
        let normalized = verb.lowercased().replacingOccurrences(of: "_", with: "-")
        return IgCmdSubcommand(rawValue: normalized)
    }

    /// One-line entry for the top-level `--help` table.
    public var helpTableRow: String {
        let pad = usage.padding(toLength: 50, withPad: " ", startingAt: 0)
        return "  \(pad)\(summary)"
    }
}

/// Standard exit codes used by every igcmd subcommand.
///
/// Bash-friendly small integers. We avoid colliding with shell reserved
/// codes (1, 2 are kept for "usage" and "general"; 126/127 are shell
/// runtime errors and are off-limits).
public enum IgCmdExit: Int32, Sendable {
    case success           = 0
    case usage             = 64   // EX_USAGE — bad invocation
    case ioError           = 66   // EX_NOINPUT — file missing / unreadable
    case unavailable       = 69   // EX_UNAVAILABLE — feature not supported on this platform
    case softwareError     = 70   // EX_SOFTWARE — internal failure (decode, install error)
    case permissionDenied  = 77   // EX_NOPERM — sandbox / privileges
}
