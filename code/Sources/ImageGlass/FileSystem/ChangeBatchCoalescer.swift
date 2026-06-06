// ChangeBatchCoalescer.swift
//
// Implements the per-URL coalescing rules in spec §5.2 over a buffer of
// raw events accumulated within one debounce window. The rules collapse
// chatter (e.g., five `.modified` events for the same URL during a slow
// write) and synthesize `.renamed` from a same-batch `.removed` + `.added`
// pair when inodes match.
//
// This type is pure — no I/O, no concurrency, no logging — so the same
// logic exercised by `FSEventsScopeWatcher` against real kernel events
// is also driven directly by `ChangeBatchCoalescerTests` against
// hand-built event sequences.

import Foundation

struct ChangeBatchCoalescer {

    /// Apply the rules in spec §5.2 in order. Events for distinct
    /// URLs are kept (the spec does not promise cross-URL ordering
    /// inside a batch, but it does promise per-URL ordering).
    static func coalesce(_ raw: [ChangeEvent]) -> [ChangeEvent] {
        guard raw.count > 1 else { return raw }

        // Pass 1 — pair `.removed`(inode=X) + `.added`(inode=X) into
        // either `.renamed` (distinct URLs) or `.modified` (same URL
        // with matching size/mtime — the inode-reuse guard from §7.16
        // lives at the watcher layer; here we trust the inode alone
        // when the URL did not change).
        var working = raw
        var i = 0
        while i < working.count {
            let event = working[i]
            guard case let .removed(removedURL, removedInode) = event,
                  let removedInode else {
                i += 1
                continue
            }
            // Look ahead for a matching .added with the same inode.
            var matchIndex: Int?
            for j in (i + 1)..<working.count {
                if case let .added(addedURL, addedInode) = working[j],
                   addedInode == removedInode {
                    _ = addedURL
                    matchIndex = j
                    break
                }
            }
            if let j = matchIndex,
               case let .added(addedURL, _) = working[j] {
                if addedURL == removedURL {
                    // Same path, same inode → in-place modify (rare —
                    // most editors change inode on save; this branch
                    // covers `touch` and `chmod` look-alikes).
                    working[i] = .modified(removedURL, inode: removedInode)
                    working.remove(at: j)
                } else {
                    working[i] = .renamed(from: removedURL,
                                          to: addedURL,
                                          inode: removedInode)
                    working.remove(at: j)
                }
            }
            i += 1
        }

        // Pass 2 — per-URL collapse using the §5.2 table. We walk the
        // buffer once and keep the *first* event per URL, then merge
        // every subsequent event into it. Order is preserved by the
        // index of the first occurrence.
        var orderedURLs: [URL] = []
        var byURL: [URL: ChangeEvent] = [:]
        // `.renamed` carries two URLs; we key it by the new URL.
        for event in working {
            let key = event.url
            if let existing = byURL[key] {
                byURL[key] = merge(existing, event)
                // Dropped events leave the URL keyed to nil so we can
                // remove the slot at the end.
            } else {
                byURL[key] = event
                orderedURLs.append(key)
            }
        }

        var result: [ChangeEvent] = []
        result.reserveCapacity(orderedURLs.count)
        for url in orderedURLs {
            if let event = byURL[url] {
                result.append(event)
            }
        }
        return result
    }

    /// Spec §5.2 table.
    private static func merge(_ first: ChangeEvent, _ second: ChangeEvent) -> ChangeEvent? {
        switch (first, second) {
        // added + modified  → added (the file is new; the mod is implicit)
        case (.added, .modified):
            return first

        // added + removed   → nil   (came and went; ignore)
        case (.added, .removed):
            return nil

        // modified + modified → modified (collapse)
        case (.modified, .modified):
            return second

        // removed + added handled in pass 1; if it survives here it
        // means inodes did not match → real replace, keep both.
        case (.removed, .added):
            return second  // last-write-wins; pass 1 already handled the inode case

        // removed + removed → removed
        case (.removed, .removed):
            return first

        // renamed + modified (on the new URL) → keep both is correct,
        // but here we are inside a per-URL collapse so the "modified"
        // is for the new URL and the rename already implies a write
        // notification; keep the rename and drop the modify.
        case (.renamed, .modified):
            return first

        // attributesChanged + modified → modified (attribs implied)
        case (.attributesChanged, .modified):
            return second

        // modified + attributesChanged → modified (attribs implied)
        case (.modified, .attributesChanged):
            return first

        // materialized + modified → modified (file is real now and
        // mutated; the materialization is implied by the modification
        // making the file readable at all).
        case (.materialized, .modified):
            return second

        // Default: keep the second (last-write-wins).
        default:
            return second
        }
    }
}
