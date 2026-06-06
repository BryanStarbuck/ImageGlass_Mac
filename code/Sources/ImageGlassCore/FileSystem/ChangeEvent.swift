// ChangeEvent.swift
//
// The uniform event type emitted by every file-system watcher in the
// FileSystem/ module. The spec
// (docs/file_system_change.mdx §4.2) names this as the contract the
// rest of the app sees, regardless of which underlying API
// (FSEvents, kqueue, NSFilePresenter, NSMetadataQuery, polling)
// produced it.

import Foundation

/// One discrete file-system mutation observed by the watcher layer.
///
/// `inode` is `nil` when the underlying API did not surface one
/// (kqueue events do not carry inodes; FSEvents only does when the
/// stream was created with `kFSEventStreamCreateFlagUseExtendedData`).
///
/// `renamed` is synthesized from a matching `removed` / `added`
/// pair within one debounce window when both carry the same inode —
/// see `ChangeBatchCoalescer` for the rules in spec §5.2.
public enum ChangeEvent: Sendable, Equatable {
    case added(URL, inode: UInt64?)
    case removed(URL, inode: UInt64?)
    case modified(URL, inode: UInt64?)
    case renamed(from: URL, to: URL, inode: UInt64?)
    case attributesChanged(URL)
    /// Watched scope root was deleted, renamed, or unmounted. The
    /// `FSEventsScopeWatcher` emits this when the stream's
    /// `kFSEventStreamEventFlagRootChanged` fires (spec §7.10).
    case rootDisappeared(URL)
    /// Previously-disappeared root has come back (volume re-mounted,
    /// directory recreated). Triggers a full rescan (spec §7.10 / §7.11).
    case rootReappeared(URL)
    /// FSEvents reported that the kernel can no longer replay events
    /// from the persisted cursor (`kFSEventStreamEventIdSinceNow`).
    /// Subscribers should force a baseline walk (spec §5.4).
    case historyDropped(scope: String, since: UInt64)
    /// iCloud Drive placeholder has been replaced with the real file
    /// (spec §7.12).
    case materialized(URL)
    /// iCloud Drive has evicted a previously-materialized file back
    /// to a placeholder (spec §7.12 corner case).
    case dematerialized(URL)
}

extension ChangeEvent {

    /// Path the event applies to. For `renamed` returns the *new*
    /// path; callers that care about the old path must pattern-match.
    public var url: URL {
        switch self {
        case .added(let url, _),
             .removed(let url, _),
             .modified(let url, _),
             .attributesChanged(let url),
             .rootDisappeared(let url),
             .rootReappeared(let url),
             .materialized(let url),
             .dematerialized(let url):
            return url
        case .renamed(_, let to, _):
            return to
        case .historyDropped:
            return URL(fileURLWithPath: "/")
        }
    }

    /// Inode if the producing watcher carried one; `nil` otherwise.
    public var inode: UInt64? {
        switch self {
        case .added(_, let i),
             .removed(_, let i),
             .modified(_, let i),
             .renamed(_, _, let i):
            return i
        default:
            return nil
        }
    }

    /// Short debug tag used by the audit log and the test harness.
    public var kind: String {
        switch self {
        case .added: return "added"
        case .removed: return "removed"
        case .modified: return "modified"
        case .renamed: return "renamed"
        case .attributesChanged: return "attribs"
        case .rootDisappeared: return "rootDisappeared"
        case .rootReappeared: return "rootReappeared"
        case .historyDropped: return "historyDropped"
        case .materialized: return "materialized"
        case .dematerialized: return "dematerialized"
        }
    }
}

/// A bundle of `ChangeEvent`s that fired within one debounce
/// window. Subscribers receive batches, not individual events, so
/// they can apply a single diff to the file panel / resolved list /
/// thumbnail cache per window — see spec §5.1.
public struct ChangeBatch: Sendable, Equatable {
    public let scope: String
    public let events: [ChangeEvent]

    /// First-event-in-window timestamp. Used by the perf harness to
    /// measure kernel→paint latency (spec §10 budget).
    public let firstEventAt: Date
    /// Flush timestamp (when the batch left the debouncer).
    public let flushedAt: Date

    public init(scope: String,
                events: [ChangeEvent],
                firstEventAt: Date,
                flushedAt: Date) {
        self.scope = scope
        self.events = events
        self.firstEventAt = firstEventAt
        self.flushedAt = flushedAt
    }
}
