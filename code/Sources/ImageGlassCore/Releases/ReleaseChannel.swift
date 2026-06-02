import Foundation

/// Distribution channel of an ImageGlass_Mac build.
///
/// Surfaced in the About window, the Releases view, and the MCP `app_version`
/// tool. Determines which update feed `UpdateChecker` consults.
///
/// Names map to the spec's wording — upstream ImageGlass uses "stable" for
/// 9.x and "beta" for the v10 preview line. We add `.dev` for unreleased
/// local builds so a developer running `swift run ImageGlass` is never
/// mistaken for a real shipping build.
public enum ReleaseChannel: String, Codable, CaseIterable, Sendable, Hashable {
    case stable
    case beta
    case dev

    /// Human-readable label suitable for badges in the UI.
    public var displayLabel: String {
        switch self {
        case .stable: return "Stable"
        case .beta:   return "Beta"
        case .dev:    return "Dev"
        }
    }

    /// GitHub Releases API path fragment used by `UpdateChecker`. Stable
    /// builds want the `/latest` endpoint (skips pre-releases); beta and
    /// dev want the full list so pre-releases are visible.
    public var githubReleasesPath: String {
        switch self {
        case .stable: return "releases/latest"
        case .beta, .dev: return "releases"
        }
    }
}
