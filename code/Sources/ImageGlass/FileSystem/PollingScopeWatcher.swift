// PollingScopeWatcher.swift
//
// Spec §3.2 last-resort fallback: stat-based polling for scopes whose
// roots live on a filesystem where FSEvents does not propagate
// cross-host writes (SMB to non-macOS server, certain NAS firmware,
// some FUSE mounts). Selected by `FileSystemProbe` when the
// FSEvents probe times out (spec §4.4).
//
// The polling strategy is deliberately simple:
//   * Period: 5 s foreground, 30 s background (matches spec §3.2).
//   * Snapshot every shallow-enumerable file under the roots,
//     keyed by URL, holding (size, mtime, inode).
//   * On each tick, diff the new snapshot against the previous one
//     and emit added/removed/modified events through `ChangeBatch`.
//
// Polling does not see `.renamed`, `.attributesChanged`, root-
// changes, or iCloud materialization — those collapse to
// added+removed and modified respectively. The UI badge in the
// scope chrome ("polling — live updates may lag") makes the
// degraded mode visible.

import Foundation
import ImageGlassCore

final class PollingScopeWatcher {

    let scopeID: String
    let roots: [URL]
    var foregroundInterval: TimeInterval = 5.0
    var backgroundInterval: TimeInterval = 30.0

    private let queue = DispatchQueue(label: "io.imageglass.polling",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var snapshot: [URL: Entry] = [:]
    private var isBackground: Bool = false

    private let onBatch: (ChangeBatch) -> Void

    private struct Entry: Equatable {
        let size: UInt64
        let mtime: TimeInterval
        let inode: UInt64
    }

    init(scopeID: String,
         roots: [URL],
         onBatch: @escaping (ChangeBatch) -> Void) {
        self.scopeID = scopeID
        self.roots = roots
        self.onBatch = onBatch
    }

    func start() {
        queue.async { [weak self] in
            self?.snapshot = self?.scanAll() ?? [:]
            self?.scheduleTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func setBackground(_ background: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard background != self.isBackground else { return }
            self.isBackground = background
            self.scheduleTimer()
        }
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = isBackground ? backgroundInterval : foregroundInterval
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
    }

    private func tick() {
        let next = scanAll()
        let prev = snapshot
        snapshot = next
        var events: [ChangeEvent] = []
        for (url, entry) in next {
            if let old = prev[url] {
                if old != entry {
                    events.append(.modified(url, inode: entry.inode))
                }
            } else {
                events.append(.added(url, inode: entry.inode))
            }
        }
        for (url, entry) in prev where next[url] == nil {
            events.append(.removed(url, inode: entry.inode))
        }
        guard !events.isEmpty else { return }
        let now = Date()
        onBatch(ChangeBatch(scope: scopeID,
                            events: events,
                            firstEventAt: now,
                            flushedAt: now))
    }

    // MARK: - Snapshot

    private func scanAll() -> [URL: Entry] {
        var result: [URL: Entry] = [:]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        for root in roots {
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }
            for case let url as URL in enumerator {
                guard let entry = stat(url: url) else { continue }
                result[url] = entry
            }
        }
        return result
    }

    private func stat(url: URL) -> Entry? {
        var st = Darwin.stat()
        guard Darwin.stat(url.path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Entry(
            size: UInt64(st.st_size),
            mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000,
            inode: UInt64(st.st_ino)
        )
    }
}
