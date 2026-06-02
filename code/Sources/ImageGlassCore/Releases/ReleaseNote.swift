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
