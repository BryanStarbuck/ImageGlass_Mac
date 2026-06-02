import Foundation

/// User-facing appearance setting that decides which side of a paired
/// light/dark theme is active.
///
/// `.system` follows the macOS appearance — when the user toggles the OS
/// between Light and Dark, ImageGlass auto-switches its theme to match.
///
/// `.light` / `.dark` lock the app to one side regardless of the OS
/// setting, so a user who prefers a dark viewer on a light-mode Mac (or
/// vice versa) can opt out of auto-switching.
public enum ThemeAppearanceMode: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system

    /// Persisted as a plain-text token on one line, matching the
    /// `current-theme.txt` convention.
    public var rawValue: String {
        switch self {
        case .light:  return "light"
        case .dark:   return "dark"
        case .system: return "system"
        }
    }

    public init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "light":  self = .light
        case "dark":   self = .dark
        case "system", "auto", "":
            self = .system
        default:
            return nil
        }
    }
}
