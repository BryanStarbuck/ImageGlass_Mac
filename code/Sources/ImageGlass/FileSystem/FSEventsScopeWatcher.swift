// FSEventsScopeWatcher.swift
//
// One per scope. Owns one FSEventStream rooted at the scope's
// directories, normalizes raw kernel callbacks into `ChangeEvent`
// values, debounces and coalesces per spec §5, and pushes
// `ChangeBatch`es into an `AsyncStream<ChangeBatch>` that the
// `FileSystemWatcher` actor forwards to subscribers.
//
// This class is the workhorse of the watcher layer. See spec
// §3.2 for the chosen flag set, §6 for the response pipeline,
// and §7 for the per-scenario behavior.

import Foundation
import CoreServices
import ImageGlassCore

final class FSEventsScopeWatcher {

    /// Stable identifier — the scope's name from Local Storage.
    let scopeID: String
    /// Roots being watched. Stable for the lifetime of this watcher;
    /// changing them requires replacing the instance.
    let roots: [URL]

    /// Serial queue every callback and timer fires on. Spec §4.5
    /// names this `io.imageglass.fsevents`.
    private let queue: DispatchQueue

    private var bridge: FSEventsBridge?

    /// Buffer of normalized events waiting to flush.
    private var buffer: [ChangeEvent] = []
    /// First-event timestamp for the current window. Set when the
    /// buffer is empty and an event lands.
    private var windowOpenedAt: Date?
    /// Adaptive debounce — extended while a flood is in progress
    /// (spec §7.9). Capped at `maxAdaptiveSeconds`.
    private var pendingFlush: DispatchWorkItem?
    private let baseLatencySeconds: Double
    private let maxAdaptiveSeconds: Double = 1.0
    private let bufferCeiling: Int = 5_000

    /// Cursor persister. Spec §5.4: persist after every flush so the
    /// next launch passes it back to FSEvents as `sinceWhen`.
    private let cursorStore: FSEventsCursorStore
    /// Stamps the perf trace per spec §10.
    private let perfTraceName: String

    private let onBatch: (ChangeBatch) -> Void

    init(scopeID: String,
         roots: [URL],
         queue: DispatchQueue,
         latencySeconds: Double,
         cursorStore: FSEventsCursorStore,
         onBatch: @escaping (ChangeBatch) -> Void) {
        self.scopeID = scopeID
        self.roots = roots
        self.queue = queue
        self.baseLatencySeconds = latencySeconds
        self.cursorStore = cursorStore
        self.perfTraceName = "FileSystemWatcher.FSEventsBatch"
        self.onBatch = onBatch
    }

    func start() {
        // Replay from the persisted cursor (spec §5.4). If we have
        // never seen this scope before, the bridge falls through to
        // `kFSEventStreamEventIdSinceNow`.
        let since = cursorStore.load(scopeID: scopeID)

        let bridge = FSEventsBridge(
            roots: roots,
            sinceWhen: since,
            latencySeconds: baseLatencySeconds,
            callbackQueue: queue
        ) { [weak self] raw in
            self?.handleRaw(raw)
        }

        if !bridge.start() {
            ErrorLog.log("FSEventStreamCreate or Start failed for scope=\(scopeID) roots=\(roots.map(\.path))",
                         class: "FSEventsScopeWatcher")
            return
        }
        self.bridge = bridge
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFlush?.cancel()
            self.pendingFlush = nil
            self.bridge?.stop()
            self.bridge = nil
        }
    }

    deinit {
        bridge?.stop()
    }

    // MARK: - Raw callback → normalized events

    private func handleRaw(_ raw: FSEventsRawCallback) {
        // Stage 2: normalize. Spec §6.
        var produced: [ChangeEvent] = []
        produced.reserveCapacity(raw.paths.count)

        var kernelDropped = false

        for (i, path) in raw.paths.enumerated() {
            guard !path.isEmpty else { continue }
            let flags = FSEventsBridge.decode(raw.flags[i])
            let url = URL(fileURLWithPath: path)
            let inode = raw.inodes[i]

            if flags.dropped || flags.userDropped {
                kernelDropped = true
                continue
            }

            if flags.isRootChanged {
                // Spec §7.10 — root deleted/renamed/unmounted. Bypass
                // the normal buffer; emit immediately.
                emitImmediate(.rootDisappeared(url))
                continue
            }

            // Re-stat to confirm the event matches reality on disk.
            // FSEvents flags are hints — the kernel may have already
                  // unwound to a state that differs from what the flag
            // suggests (spec §3.1).
            let now = statResult(path: path)

            if flags.isRemoved && now == nil {
                produced.append(.removed(url, inode: inode))
                continue
            }

            if flags.isCreated && now != nil {
                produced.append(.added(url, inode: inode ?? now?.inode))
                continue
            }

            if flags.isRenamed {
                // Rename is delivered to both old and new paths in the
                // same batch. We can't tell from one event alone which
                // side this is — pass it through as `.removed` if the
                // path is gone, `.added` if it now exists. The
                // coalescer pairs them in pass 1.
                if now == nil {
                    produced.append(.removed(url, inode: inode))
                } else {
                    produced.append(.added(url, inode: inode ?? now?.inode))
                }
                continue
            }

            if flags.isModified && now != nil {
                produced.append(.modified(url, inode: inode ?? now?.inode))
                continue
            }

            if flags.isAttribChange && now != nil {
                produced.append(.attributesChanged(url))
                continue
            }

            // Fallback: file exists and the flag bag tells us nothing
            // useful. Re-stat said something is there; emit `.modified`
            // so the scope engine re-resolves the metadata.
            if now != nil {
                produced.append(.modified(url, inode: inode ?? now?.inode))
            } else {
                produced.append(.removed(url, inode: inode))
            }
        }

        if kernelDropped {
            // Spec §5.4 / §7.18 — emit a historyDropped sentinel.
            // Subscribers force a baseline rescan.
            let dropped = ChangeEvent.historyDropped(scope: scopeID,
                                                    since: bridge?.currentEventId() ?? 0)
            emitImmediate(dropped)
        }

        guard !produced.isEmpty else { return }

        if windowOpenedAt == nil {
            windowOpenedAt = Date()
        }
        buffer.append(contentsOf: produced)

        // Adaptive flood debounce — spec §7.9.
        if buffer.count >= bufferCeiling {
            flushNow()
            return
        }

        // Cancel any pending flush, schedule a fresh one. Each new
        // callback inside the window extends the deadline up to
        // `maxAdaptiveSeconds`.
        pendingFlush?.cancel()
        let openedAt = windowOpenedAt ?? Date()
        let elapsed = Date().timeIntervalSince(openedAt)
        let nextDelay = min(maxAdaptiveSeconds - elapsed, baseLatencySeconds)
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + max(0.01, nextDelay), execute: work)

        // Persist cursor opportunistically — spec §5.4.
        if let id = bridge?.currentEventId(),
           id != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            cursorStore.save(scopeID: scopeID, cursor: id)
        }
    }

    private func flushNow() {
        guard !buffer.isEmpty else { return }
        let firstAt = windowOpenedAt ?? Date()
        let raw = buffer
        buffer.removeAll(keepingCapacity: true)
        windowOpenedAt = nil
        pendingFlush?.cancel()
        pendingFlush = nil

        let trace = PerformanceLog.shared.start(
            perfTraceName,
            extra: [("scope", scopeID), ("raw", String(raw.count))]
        )
        let coalesced = ChangeBatchCoalescer.coalesce(raw)
        let batch = ChangeBatch(scope: scopeID,
                                events: coalesced,
                                firstEventAt: firstAt,
                                flushedAt: Date())
        onBatch(batch)
        trace.finish(extra: [("emitted", String(coalesced.count))])
    }

    private func emitImmediate(_ event: ChangeEvent) {
        // Spec §5.3 — rootDisappeared and historyDropped bypass the
        // batch and are delivered ahead of the queued buffer.
        let now = Date()
        if !buffer.isEmpty {
            flushNow()
        }
        let batch = ChangeBatch(scope: scopeID,
                                events: [event],
                                firstEventAt: now,
                                flushedAt: now)
        onBatch(batch)
    }

    // MARK: - stat helper

    private struct StatResult {
        let inode: UInt64
        let size: UInt64
        let mtime: TimeInterval
        let isDirectory: Bool
    }

    private func statResult(path: String) -> StatResult? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return StatResult(
            inode: UInt64(st.st_ino),
            size: UInt64(st.st_size),
            mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000,
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR
        )
    }
}
