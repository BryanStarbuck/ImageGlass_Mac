import Foundation

/// Structured changelog derived from `ReleasesCatalog`.
///
/// `ReleasesCatalog` is the on-disk source of truth — the catalog already
/// holds version, date, and highlights. `Changelog` is the thin formatter
/// that turns those entries into the strings shown in the UI and emitted
/// by the `list_releases` MCP tool, so SwiftUI views and MCP responses
/// stay in lock-step.
public enum Changelog {

    public struct Entry: Sendable, Equatable {
        public let version: String
        public let title: String
        public let date: Date
        public let kind: ReleaseNote.Kind
        public let origin: ReleaseNote.Origin
        public let bullets: [String]

        public init(
            version: String,
            title: String,
            date: Date,
            kind: ReleaseNote.Kind,
            origin: ReleaseNote.Origin,
            bullets: [String]
        ) {
            self.version = version
            self.title = title
            self.date = date
            self.kind = kind
            self.origin = origin
            self.bullets = bullets
        }
    }

    /// All catalog entries projected to changelog form, newest first.
    public static var entries: [Entry] {
        ReleasesCatalog.sortedReverseChronological.map { note in
            Entry(
                version: note.version,
                title: note.title,
                date: note.date,
                kind: note.kind,
                origin: note.origin,
                bullets: note.highlights
            )
        }
    }

    /// Only this fork's entries (`origin == .macFork`). Used by About and
    /// the update-check "What's new" surface.
    public static var macForkEntries: [Entry] {
        entries.filter { $0.origin == .macFork }
    }

    /// Only the upstream-Windows entries. Used by the Releases & News view's
    /// "Upstream Releases" section.
    public static var upstreamEntries: [Entry] {
        entries.filter { $0.origin == .upstream }
    }

    /// Render an entry as a small markdown block:
    ///
    /// ```
    /// ## 0.1.0 — June 2026 (beta · mac fork)
    /// First public preview …
    /// - SwiftUI + AppKit interop …
    /// - …
    /// ```
    public static func renderMarkdown(_ entry: Entry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let dateString = formatter.string(from: entry.date)
        let originLabel = entry.origin == .macFork ? "mac fork" : "upstream"
        var out = "## \(entry.version) — \(dateString) (\(entry.kind.rawValue) · \(originLabel))\n"
        out += "\(entry.title)\n"
        for bullet in entry.bullets {
            out += "- \(bullet)\n"
        }
        return out
    }

    /// Concatenate every entry into a single markdown changelog. Useful for
    /// dumping to stdout from the CLI or for embedding in the About window.
    public static func renderFullMarkdown() -> String {
        entries.map(renderMarkdown).joined(separator: "\n")
    }
}
