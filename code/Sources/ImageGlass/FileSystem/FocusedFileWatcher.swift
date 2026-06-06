// FocusedFileWatcher.swift
//
// Sub-50ms watcher for the single currently-displayed file. The
// FSEvents stream on the scope is enough for the file panel but its
// 0.20 s coalescing window is visible in the viewer when an external
// editor saves over the user's open image. This class plugs that
// gap by running a kqueue-backed `DispatchSourceFileSystemObject` on
// the focused file's descriptor and emitting `.modified` /
// `.attributesChanged` / `.removed` / `.renamed` events through the
// same `ChangeBatch` channel the FSEvents path uses.
//
// Spec §3.2 (secondary mechanism) and §7.3.
//
// We intentionally reuse the existing `FileWatcher` shape — but
// extend it with event-mask decoding so a `.write` doesn't masquerade
// as a `.delete` and trigger viewer cleanup.

import Foundation
import ImageGlassCore

final class FocusedFileWatcher {

    private(set) var url: URL?
    private let queue = DispatchQueue(label: "io.imageglass.kqueue",
                                      qos: .userInteractive)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    /// Tightest sensible coalesce — one display frame at 60 Hz.
    /// Spec §5.1: "effectively 0 ms with a 16 ms maximum coalesce".
    private let coalesceWindow: TimeInterval = 0.016
    private var pendingFlush: DispatchWorkItem?
    private var pendingEvents: DispatchSource.FileSystemEvent = []

    /// True while a coordinated writer (NSFilePresenter) has the
    /// file. Spec §7.13 says we mute kqueue emissions during the
    /// writer-relinquish handshake to avoid reading half-written
    /// bytes; the presenter's relinquish handler flips this on, the
    /// reacquire handler flips it back off and forces a flush.
    var paused: Bool = false

    private let onChange: (ChangeBatch) -> Void

    init(onChange: @escaping (ChangeBatch) -> Void) {
        self.onChange = onChange
    }

    /// Bind the watcher to `newURL`. Passing `nil` tears it down (the
    /// viewer is empty). Idempotent on the same URL.
    func setURL(_ newURL: URL?) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.url == newURL { return }
            self.teardownUnsafe()
            self.url = newURL
            guard let u = newURL else { return }
            self.setupUnsafe(url: u)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.teardownUnsafe()
            self?.url = nil
        }
    }

    deinit {
        teardownUnsafe()
    }

    // MARK: - Setup / teardown

    private func setupUnsafe(url: URL) {
        let opened = open(url.path, O_EVTONLY)
        guard opened >= 0 else {
            ErrorLog.log("FocusedFileWatcher open(O_EVTONLY) failed errno=\(errno) path=\(url.path)",
                         class: "FocusedFileWatcher")
            return
        }
        fd = opened
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke, .link],
            queue: queue
        )
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingEvents = self.pendingEvents.union(s.data)
            self.pendingFlush?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flushPending()
            }
            self.pendingFlush = work
            self.queue.asyncAfter(deadline: .now() + self.coalesceWindow,
                                  execute: work)
        }
        s.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        s.resume()
        source = s
    }

    private func teardownUnsafe() {
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingEvents = []
        source?.cancel()
        source = nil
    }

    // MARK: - Event translation

    private func flushPending() {
        guard !paused, let url = self.url else { return }
        let mask = pendingEvents
        pendingEvents = []
        let now = Date()
        var events: [ChangeEvent] = []

        // Order matters: a save can produce `.write + .rename` (atomic
        // save) or `.delete + .rename` together. We emit at most one
        // semantic event per flush, in priority order.
        if mask.contains(.delete) && !pathExists(url.path) {
            events.append(.removed(url, inode: nil))
        } else if mask.contains(.rename) {
            // The path now points at a different inode (atomic save).
            // Surface as `.modified` — the user-visible filename is
            // unchanged so the viewer reloads from the new inode.
            // Spec §7.3.
            events.append(.modified(url, inode: nil))
        } else if mask.contains(.write) || mask.contains(.extend) {
            events.append(.modified(url, inode: nil))
        } else if mask.contains(.attrib) {
            events.append(.attributesChanged(url))
        } else if mask.contains(.revoke) {
            events.append(.removed(url, inode: nil))
        } else if mask.contains(.link) {
            events.append(.attributesChanged(url))
        }

        guard !events.isEmpty else { return }
        let batch = ChangeBatch(scope: "__focused__",
                                events: events,
                                firstEventAt: now,
                                flushedAt: now)
        onChange(batch)

        // After a rename/delete the FD may now reference a stale
        // inode. Rebind to the same path so we keep watching the
        // user-visible file.
        if mask.contains(.rename) || mask.contains(.delete) {
            teardownUnsafe()
            if pathExists(url.path) {
                setupUnsafe(url: url)
            }
        }
    }

    private func pathExists(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0
    }
}
