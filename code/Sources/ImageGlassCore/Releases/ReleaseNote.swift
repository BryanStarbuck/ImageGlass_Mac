import Foundation

/// A single release entry shown in the "Releases & News" surface.
///
/// Note on origin:
/// * `.upstream` — a release of the original Windows ImageGlass project. We
///   *report* on these in the Mac fork's UI; we do not ship them.
/// * `.macFork` — a release of *this* Mac-native rebuild (the thing we
///   actually ship from this repo).
public struct ReleaseNote: Identifiable, Hashable, Sendable {

    public enum Kind: String, Sendable, Hashable {
        case stable
        case beta
    }

    public enum Origin: String, Sendable, Hashable {
        case upstream
        case macFork
    }

    public let id: String
    public let version: String
    public let date: Date
    public let kind: Kind
    public let origin: Origin
    public let title: String
    public let highlights: [String]
    /// Project milestones associated with this release, if any
    /// (e.g. "15-year anniversary", "WeAreDevelopers Open Source Spotlight").
    public let milestones: [String]

    public init(
        id: String,
        version: String,
        date: Date,
        kind: Kind,
        origin: Origin,
        title: String,
        highlights: [String],
        milestones: [String] = []
    ) {
        self.id = id
        self.version = version
        self.date = date
        self.kind = kind
        self.origin = origin
        self.title = title
        self.highlights = highlights
        self.milestones = milestones
    }
}

/// A project-level milestone independent of any single release.
public struct ProjectMilestone: Identifiable, Hashable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    public let detail: String

    public init(id: String, date: Date, title: String, detail: String) {
        self.id = id
        self.date = date
        self.title = title
        self.detail = detail
    }
}

/// A release series that no longer receives updates (e.g. ImageGlass 8.x).
/// Surfaced in the Releases view so users on a stale series see a clear
/// "upgrade to 9.x or try 10 Beta" prompt.
public struct EndOfLifeSeries: Identifiable, Hashable, Sendable {
    public var id: String { series }
    public let series: String
    public let note: String
    public let recommendation: String

    public init(series: String, note: String, recommendation: String) {
        self.series = series
        self.note = note
        self.recommendation = recommendation
    }
}

/// A theme from the public roadmap (spec §Roadmap).
public struct RoadmapTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// External announcement channel (Twitter, YouTube, Facebook, Instagram,
/// Medium). Listed verbatim from the spec's footer.
public struct SocialChannel: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}
