// FileSystemWatcher.swift
//
// Public entry point of the FileSystem/ module (spec §4.3). The
// rest of the app — AppState, the viewer, the MCP file tools — only
// ever talks to this actor. Internally it composes:
//
//   * one `FSEventsScopeWatcher` (or `PollingScopeWatcher`) per
//     loaded scope, chosen by `FileSystemProbe`,
//   * one `ICloudMaterializationWatcher` per scope that intersects
//     iCloud Documents,
//   * one shared `FocusedFileWatcher` for the currently-displayed
//     image,
//   * one shared `CoordinatedFilePresenter` for the focused file's
//     cooperating-app handshake,
//   * one shared `NSWorkspace` subscription that surfaces volume
//     mount / unmount events as `.rootDisappeared` / `.rootReappeared`.
//
// All events leave through `events(for:)` (per-scope) or
// `focusedFileEvents()` (currently-displayed file). Subscribers
// receive `ChangeBatch` values via `AsyncStream`.

import Foundation
import AppKit
import ImageGlassCore

/// Public to the ImageGlass executable target only (the SwiftPM
/// product itself is not a library — no external clients).
actor FileSystemWatcher {

    static let shared = FileSystemWatcher()

    // MARK: - Per-scope state

    private struct ScopeState {
        var roots: [URL]
        var fsWatcher: FSEventsScopeWatcher?
        var pollWatcher: PollingScopeWatcher?
        var cloudWatcher: ICloudMaterializationWatcher?
        var continuations: [UUID: AsyncStream<ChangeBatch>.Continuation] = [:]
        var probeResult: FileSystemProbeResult
    }

    private var scopes: [String: ScopeState] = [:]
    private var focusedURL: URL?
    private var focusedContinuations: [UUID: AsyncStream<ChangeBatch>.Continuation] = [:]

    private let fsEventsQueue = DispatchQueue(label: "io.imageglass.fsevents",
                                              qos: .userInitiated)

    private var focusedWatcher: FocusedFileWatcher?
    private var coordinatedPresenter: CoordinatedFilePresenter?

    /// Workspace mount / unmount observation. Spec §7.11.
    private var workspaceObservers: [NSObjectProtocol] = []

    private let cursorStore: FSEventsCursorStore
    private let probe: FileSystemProbe

    init(cursorStore: FSEventsCursorStore = .shared,
         probe: FileSystemProbe = .shared) {
        self.cursorStore = cursorStore
        self.probe = probe
        Task { await self.installWorkspaceObservers() }
    }

    // MARK: - Public API (spec §4.3)

    /// Bind `roots` to `scopeID`. Idempotent: a second call with the
    /// same `(scopeID, roots)` is a no-op. A call with a different
    /// roots set replaces the underlying watcher.
    func watch(scope scopeID: String, roots: [URL]) async {
        if let existing = scopes[scopeID], existing.roots == roots {
            return
        }
        unwatchInternal(scopeID: scopeID)

        // Probe each root and pick the slowest-but-most-conservative
        // result. (If any root needs polling, the whole scope polls
        // — mixing per-root strategies in one scope is more
        // complexity than it's worth.)
        var pollingNeeded = false
        for root in roots {
            if probe.probe(root: root) == .polling {
                pollingNeeded = true
                break
            }
        }

        let probeResult: FileSystemProbeResult = pollingNeeded ? .polling : .fsevents
        var state = ScopeState(roots: roots,
                               fsWatcher: nil,
                               pollWatcher: nil,
                               cloudWatcher: nil,
                               continuations: scopes[scopeID]?.continuations ?? [:],
                               probeResult: probeResult)

        if probeResult == .fsevents {
            let watcher = FSEventsScopeWatcher(
                scopeID: scopeID,
                roots: roots,
                queue: fsEventsQueue,
                latencySeconds: 0.20,
                cursorStore: cursorStore
            ) { [weak self] batch in
                Task { await self?.publish(batch: batch) }
            }
            watcher.start()
            state.fsWatcher = watcher
        } else {
            let poll = PollingScopeWatcher(scopeID: scopeID, roots: roots) { [weak self] batch in
                Task { await self?.publish(batch: batch) }
            }
            poll.start()
            state.pollWatcher = poll
        }

        // iCloud sidecar, if any root lives under iCloud.
        if let cloud = ICloudMaterializationWatcher.makeIfNeeded(
            scopeID: scopeID,
            roots: roots,
            onBatch: { [weak self] batch in
                Task { await self?.publish(batch: batch) }
            }
        ) {
            cloud.start()
            state.cloudWatcher = cloud
        }

        scopes[scopeID] = state
    }

    /// Stop watching `scopeID`. All AsyncStreams are finished.
    func unwatch(scope scopeID: String) async {
        unwatchInternal(scopeID: scopeID)
    }

    /// Bind the focused-file watcher to `url`. Passing `nil` releases
    /// it (the viewer is empty).
    func setFocusedFile(_ url: URL?) async {
        focusedURL = url

        if focusedWatcher == nil {
            focusedWatcher = FocusedFileWatcher { [weak self] batch in
                Task { await self?.publishFocused(batch: batch) }
            }
        }
        focusedWatcher?.setURL(url)

        // Cooperate with NSFileCoordinator-aware apps (spec §7.13).
        if coordinatedPresenter == nil {
            let presenter = CoordinatedFilePresenter()
            presenter.onWriterAcquired = { [weak self] in
                Task { await self?.focusedWatcherPause(true) }
            }
            presenter.onWriterReleased = { [weak self] in
                Task { await self?.focusedWatcherPause(false) }
            }
            presenter.onChange = { [weak self] url in
                Task { await self?.publishFocused(batch: ChangeBatch(
                    scope: "__focused__",
                    events: [.modified(url, inode: nil)],
                    firstEventAt: Date(),
                    flushedAt: Date()
                )) }
            }
            presenter.onMove = { [weak self] from, to in
                Task { await self?.publishFocused(batch: ChangeBatch(
                    scope: "__focused__",
                    events: [.renamed(from: from, to: to, inode: nil)],
                    firstEventAt: Date(),
                    flushedAt: Date()
                )) }
            }
            coordinatedPresenter = presenter
        }
        coordinatedPresenter?.setURL(url)
    }

    /// Subscribe to per-scope batches. Returns a fresh `AsyncStream`;
    /// the caller iterates with `for await`.
    func events(for scopeID: String) -> AsyncStream<ChangeBatch> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.register(id: id, scopeID: scopeID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.deregister(id: id, scopeID: scopeID) }
            }
        }
    }

    /// Subscribe to focused-file batches. Same shape as
    /// `events(for:)` but the stream carries events only for the
    /// currently-displayed file.
    func focusedFileEvents() -> AsyncStream<ChangeBatch> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.registerFocused(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.deregisterFocused(id: id) }
            }
        }
    }

    /// Force a full re-resolution. Used by MCP `fs.rescan` and by
    /// the watcher itself on `.historyDropped` / `.rootReappeared`.
    func forceRescan(scope scopeID: String) async {
        guard let state = scopes[scopeID] else { return }
        let now = Date()
        let batch = ChangeBatch(
            scope: scopeID,
            events: [.historyDropped(scope: scopeID, since: 0)],
            firstEventAt: now,
            flushedAt: now
        )
        publish(batch: batch)
        _ = state
    }

    /// Re-probe a root, bypassing the cache. Spec §12 / `fs.probe`.
    func probeRoot(_ root: URL) async -> FileSystemProbeResult {
        return probe.forceProbe(root: root)
    }

    // MARK: - Internal plumbing

    private func unwatchInternal(scopeID: String) {
        guard let state = scopes[scopeID] else { return }
        state.fsWatcher?.stop()
        state.pollWatcher?.stop()
        state.cloudWatcher?.stop()
        for cont in state.continuations.values {
            cont.finish()
        }
        scopes.removeValue(forKey: scopeID)
    }

    private func register(id: UUID,
                          scopeID: String,
                          continuation: AsyncStream<ChangeBatch>.Continuation) {
        if var state = scopes[scopeID] {
            state.continuations[id] = continuation
            scopes[scopeID] = state
        } else {
            // Subscriber attached before `watch` — buffer the
            // continuation so it survives until the scope is bound.
            var state = ScopeState(roots: [], fsWatcher: nil, pollWatcher: nil,
                                   cloudWatcher: nil, continuations: [:],
                                   probeResult: .fsevents)
            state.continuations[id] = continuation
            scopes[scopeID] = state
        }
    }

    private func deregister(id: UUID, scopeID: String) {
        guard var state = scopes[scopeID] else { return }
        state.continuations.removeValue(forKey: id)
        scopes[scopeID] = state
    }

    private func registerFocused(id: UUID,
                                 continuation: AsyncStream<ChangeBatch>.Continuation) {
        focusedContinuations[id] = continuation
    }

    private func deregisterFocused(id: UUID) {
        focusedContinuations.removeValue(forKey: id)
    }

    private func publish(batch: ChangeBatch) {
        guard let state = scopes[batch.scope] else { return }
        for cont in state.continuations.values {
            cont.yield(batch)
        }
    }

    private func publishFocused(batch: ChangeBatch) {
        for cont in focusedContinuations.values {
            cont.yield(batch)
        }
    }

    private func focusedWatcherPause(_ paused: Bool) {
        focusedWatcher?.paused = paused
    }

    // MARK: - Workspace mount / unmount

    private func installWorkspaceObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let mountObs = workspace.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await self?.handleVolumeChange(url: url, mounted: true) }
        }
        let unmountObs = workspace.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await self?.handleVolumeChange(url: url, mounted: false) }
        }
        // `willUnmount` lets us pre-emptively release FDs (spec §7.11
        // corner case).
        let willUnmountObs = workspace.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await self?.handleVolumeWillUnmount(url: url) }
        }
        workspaceObservers = [mountObs, unmountObs, willUnmountObs]
    }

    private func handleVolumeChange(url volume: URL, mounted: Bool) {
        let now = Date()
        for (scopeID, state) in scopes {
            let affected = state.roots.contains { root in
                root.path.hasPrefix(volume.path)
            }
            guard affected else { continue }
            let event: ChangeEvent = mounted ? .rootReappeared(volume)
                                              : .rootDisappeared(volume)
            let batch = ChangeBatch(scope: scopeID,
                                    events: [event],
                                    firstEventAt: now,
                                    flushedAt: now)
            publish(batch: batch)
            if mounted {
                // Re-arm the FSEvents stream to catch up.
                state.fsWatcher?.stop()
                let watcher = FSEventsScopeWatcher(
                    scopeID: scopeID,
                    roots: state.roots,
                    queue: fsEventsQueue,
                    latencySeconds: 0.20,
                    cursorStore: cursorStore
                ) { [weak self] batch in
                    Task { await self?.publish(batch: batch) }
                }
                watcher.start()
                var newState = state
                newState.fsWatcher = watcher
                scopes[scopeID] = newState
            }
        }
    }

    private func handleVolumeWillUnmount(url volume: URL) {
        // Pre-emptively drop watchers rooted on the volume so the
        // unmount itself is not blocked by our open FDs (spec §7.11).
        for (scopeID, state) in scopes {
            let affected = state.roots.contains { $0.path.hasPrefix(volume.path) }
            guard affected else { continue }
            state.fsWatcher?.stop()
            state.pollWatcher?.stop()
            var newState = state
            newState.fsWatcher = nil
            newState.pollWatcher = nil
            scopes[scopeID] = newState
        }
        if let focused = focusedURL, focused.path.hasPrefix(volume.path) {
            focusedWatcher?.setURL(nil)
        }
    }
}
