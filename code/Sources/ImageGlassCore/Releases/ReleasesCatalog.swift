import Foundation

/// Static, in-code catalog of all release notes and project milestones surfaced
/// in the "Releases & News" window.
///
/// Source of truth: `docs/releases.mdx`. Keep entries here in sync with that
/// spec when new upstream releases or milestones are added.
public enum ReleasesCatalog {

    // MARK: - Date helpers

    /// Build a UTC date from year/month/day. Uses Gregorian calendar so the
    /// catalog is locale-independent.
    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = DateComponents(
            calendar: cal,
            timeZone: cal.timeZone,
            year: year, month: month, day: day,
            hour: 12, minute: 0, second: 0
        )
        // Force-unwrap is safe: components are valid by construction and the
        // calendar is fixed Gregorian/UTC. A nil here means programmer error.
        return cal.date(from: comps)!
    }

    // MARK: - Releases

    /// All releases — both upstream ImageGlass and this Mac fork — in the
    /// order they appear in the spec. Use `sortedReverseChronological` for
    /// display.
    public static let releases: [ReleaseNote] = [
        // -----------------------------------------------------------------
        // This Mac-native fork. We ship this. Listed first so it's at the
        // top of the reverse-chronological view.
        // -----------------------------------------------------------------
        ReleaseNote(
            id: "macfork-0.1",
            version: AppVersion.catalogVersionLabel,
            date: date(2026, 6, 1),
            kind: AppVersion.channel == .stable ? .stable : .beta,
            origin: .macFork,
            title: "\(AppVersion.catalogVersionLabel) — early preview",
            highlights: [
                "First public preview of the Mac-native ImageGlass rebuild.",
                "SwiftUI + AppKit interop on macOS 14+.",
                "Native viewer, file list, scopes, and configuration surface.",
                "Bundled MCP server (imageglass-mcp) for AI-assisted workflows."
            ],
            milestones: []
        ),

        // -----------------------------------------------------------------
        // Upstream ImageGlass (Windows / cross-platform). We report on
        // these; we do not ship them from this repo.
        // -----------------------------------------------------------------
        ReleaseNote(
            id: "upstream-9.5",
            version: "9.5.0.515",
            date: date(2026, 5, 1),
            kind: .stable,
            origin: .upstream,
            title: "ImageGlass 9.5 — community features & bugfixes",
            highlights: [
                "Community-requested features and bugfixes.",
                "Continues the v9 maintenance line.",
                "Current recommended stable release on Windows."
            ]
        ),

        ReleaseNote(
            id: "upstream-10-beta-1",
            version: "10 Beta 1",
            date: date(2026, 3, 1),
            kind: .beta,
            origin: .upstream,
            title: "ImageGlass 10 Beta 1 — Avalonia rewrite",
            highlights: [
                "Complete rewrite using modern .NET.",
                "UI built on the Avalonia UI framework.",
                "Targets multiple platforms from a single unified codebase — no longer Windows-only.",
                "Beta software — v9 remains the recommended stable release for everyday use."
            ]
        ),

        ReleaseNote(
            id: "upstream-9.3",
            version: "9.3",
            date: date(2025, 9, 1),
            kind: .stable,
            origin: .upstream,
            title: "ImageGlass 9.3 — 15-year anniversary",
            highlights: [
                "Marked 15 years of active development.",
                "Enhanced Windows Explorer compatibility so ImageGlass behaves more like a first-class native viewer when invoked from the shell."
            ],
            milestones: ["15-year anniversary"]
        ),

        ReleaseNote(
            id: "upstream-9.2",
            version: "9.2",
            date: date(2025, 5, 1),
            kind: .stable,
            origin: .upstream,
            title: "ImageGlass 9.2 — resize & crop",
            highlights: [
                "Image Resize tool added.",
                "Crop tool upgraded."
            ]
        ),

        ReleaseNote(
            id: "upstream-9.1",
            version: "9.1",
            date: date(2025, 1, 1),
            kind: .stable,
            origin: .upstream,
            title: "ImageGlass 9.1 — lossless compression & startup boost",
            highlights: [
                "Lossless compression added.",
                "Startup Boost added for faster perceived launch."
            ]
        ),
    ]

    // MARK: - Project milestones

    /// Project-level milestones independent of any single release. Sourced
    /// from the spec's "Project Milestones" section.
    public static let milestones: [ProjectMilestone] = [
        ProjectMilestone(
            id: "wearedevelopers-2025",
            date: date(2025, 7, 1),
            title: "WeAreDevelopers World Congress 2025 (Berlin)",
            detail: "ImageGlass selected for the Open Source Spotlight."
        ),
        ProjectMilestone(
            id: "openpledge-2025",
            date: date(2025, 8, 1),
            title: "Joined OpenPledge.io",
            detail: "ImageGlass joined the OpenPledge community funding platform."
        ),
        ProjectMilestone(
            id: "anniversary-2025",
            date: date(2025, 9, 1),
            title: "15-year anniversary",
            detail: "Celebrated with the 9.3 release."
        ),
    ]

    // MARK: - End-of-life series

    /// Upstream-Windows release series that no longer receive updates.
    /// Sourced verbatim from the spec's "End of Life" section.
    public static let endOfLifeSeries: [EndOfLifeSeries] = [
        EndOfLifeSeries(
            series: "8.x",
            note: "The 8.x series is no longer receiving updates.",
            recommendation: "Users on 8.x are encouraged to upgrade to 9.x (stable) or try 10 Beta."
        ),
    ]

    // MARK: - Roadmap

    /// 2026 roadmap themes from the spec's "Roadmap" section. Surfaced in
    /// the Releases view's footer so users see where the project is going,
    /// not just where it's been.
    public static let roadmapThemes: [RoadmapTheme] = [
        RoadmapTheme(
            id: "cross-platform-parity",
            title: "Cross-platform parity",
            detail: "Bring all v9 features to Avalonia."
        ),
        RoadmapTheme(
            id: "single-codebase",
            title: "Single codebase",
            detail: "Replace the WinForms-era foundations."
        ),
        RoadmapTheme(
            id: "community-transparency",
            title: "Community transparency",
            detail: "Public roadmap, public betas, public discussion."
        ),
    ]

    /// Maintainer's stated commitment about v9 maintenance during the v10
    /// beta period. Verbatim from the spec.
    public static let roadmapMaintenanceNote =
        "v9 will continue to receive maintenance releases throughout the v10 "
        + "beta period so users aren't forced to upgrade until v10 reaches stable."

    // MARK: - Social channels

    /// External announcement channels listed in the spec footer. Used by the
    /// Releases view's "Where to get releases" / "Follow" section.
    public static let socialChannels: [SocialChannel] = [
        SocialChannel(name: "Twitter",   url: URL(string: "https://twitter.com/d2phap")!),
        SocialChannel(name: "YouTube",   url: URL(string: "https://www.youtube.com/@d2phap")!),
        SocialChannel(name: "Facebook",  url: URL(string: "https://www.facebook.com/imageglass")!),
        SocialChannel(name: "Instagram", url: URL(string: "https://www.instagram.com/d2phap")!),
        SocialChannel(name: "Medium",    url: URL(string: "https://medium.com/@d2phap")!),
    ]

    // MARK: - Derived views

    /// Releases sorted newest-first. This is the canonical display order for
    /// the Releases & News window.
    public static var sortedReverseChronological: [ReleaseNote] {
        releases.sorted { $0.date > $1.date }
    }

    /// Versions known to the spec, used by tests to guard against accidental
    /// removal.
    public static let knownUpstreamVersions: [String] = [
        "9.1", "9.2", "9.3", "10 Beta 1", "9.5.0.515"
    ]

    /// The current stable upstream version, sourced from the spec's
    /// "Current Stable" section. Used in About and update-check surfaces
    /// when reporting which Windows build is the recommended baseline.
    public static let currentStableUpstreamVersion = "9.5.0.515"
}
