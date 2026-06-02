import Foundation

/// Single source of truth for the Mac fork's version metadata.
///
/// Every surface that needs a version string (About window, Releases view,
/// MCP `initialize` handshake, update-check user agent, log lines) MUST read
/// from `AppVersion` rather than embedding a literal — keeping the version
/// in one place is the whole point of this type.
///
/// At bundle time, the `CFBundleShortVersionString` and `CFBundleVersion`
/// keys in `Info.plist` should be set from these constants by the build
/// system. When the executable is run from `swift run` (no bundle), the
/// constants here are what's surfaced.
public enum AppVersion {

    // MARK: - Marketing version (semver)

    /// Marketing version of the Mac fork — semver MAJOR.MINOR.PATCH.
    ///
    /// Bump this for any user-visible release. The first public preview is
    /// "0.1.0" per the catalog entry.
    public static let major: Int = 0
    public static let minor: Int = 1
    public static let patch: Int = 0

    /// `"0.1.0"` — the dotted semver triple, no channel suffix.
    public static var marketingVersion: String {
        "\(major).\(minor).\(patch)"
    }

    // MARK: - Build number

    /// Monotonic build number. Increments per CI build; never resets when
    /// the marketing version bumps. Used in crash reports and the About
    /// surface to disambiguate two builds with the same marketing version.
    ///
    /// Surfaced as `CFBundleVersion` in the bundled app.
    public static let buildNumber: Int = 1

    // MARK: - Release channel

    /// Channel this build was cut on. Affects which update feed (stable /
    /// beta) the update checker consults.
    public static let channel: ReleaseChannel = .beta

    // MARK: - Combined display strings

    /// `"0.1.0 (1) beta"` — what About shows.
    public static var displayVersion: String {
        "\(marketingVersion) (\(buildNumber)) \(channel.rawValue)"
    }

    /// `"0.1.0-beta+1"` — semver pre-release + build metadata, suitable for
    /// User-Agent strings and machine-readable surfaces.
    public static var semverString: String {
        switch channel {
        case .stable:
            return "\(marketingVersion)+\(buildNumber)"
        case .beta, .dev:
            return "\(marketingVersion)-\(channel.rawValue)+\(buildNumber)"
        }
    }

    /// User-Agent used by the in-app update checker. Identifies this fork
    /// distinctly from upstream so server logs can tell them apart.
    public static var userAgent: String {
        "ImageGlass_Mac/\(semverString) (macOS; Swift)"
    }

    // MARK: - Catalog identity

    /// Catalog `version` field for this build, e.g. `"ImageGlass_Mac 0.1.0"`.
    /// `ReleasesCatalog` uses this to label the Mac fork entry so the catalog
    /// and AppVersion can never drift apart.
    public static var catalogVersionLabel: String {
        "ImageGlass_Mac \(marketingVersion)"
    }
}
