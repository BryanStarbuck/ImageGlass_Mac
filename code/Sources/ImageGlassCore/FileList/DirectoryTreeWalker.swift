import Foundation

/// Owns the in-memory `RootDirectory` graph and the background walks
/// that populate it. Spec: `docs/list_of_files.mdx` §3A.5 – §3A.7;
/// behavior tour: `docs/use_cases/mcp_file.mdx` §4 / §6 / §7 / §10.
///
/// Concurrency model: the walker is a Swift `actor`. The MCP tools post
/// work to it via the non-isolated `scheduleWalk` / `removeRoot` /
/// `refilter*` / `firstImage*` wrappers, which hop onto the actor via
/// `Task`. The eventual `app=directory.walk` / `app=panel.auto_select_first`
/// audit lines are written from inside the actor so they always reflect
/// the actual walk outcome.
public final class DirectoryTreeWalker: @unchecked Sendable {

    public static let shared = DirectoryTreeWalker()

    /// Notification name the panel observes to learn that a root's tree
    /// has changed (walk completed, refilter ran, root removed). The
    /// `object` is the canonical `URL` for the affected root, or `nil`
    /// for "every root".
    public static let didChangeNotification = Notification.Name(
        "ImageGlassCore.DirectoryTreeWalker.didChange"
    )

    /// Notification posted when the walker discovers the first image in
    /// a fresh walk and the trigger conditions in §10.1 are met. The
    /// `object` is the canonical `URL` for the image; `userInfo["corr"]`
    /// carries the triggering MCP call's correlation id.
    public static let firstImageFoundNotification = Notification.Name(
        "ImageGlassCore.DirectoryTreeWalker.firstImageFound"
    )

    /// True while the auto-select-first rule (§10) should fire. Defaults
    /// to "viewer empty" — the panel layer (Stage E) toggles this off as
    /// soon as a real selection lands.
    public var viewerIsEmpty: Bool = true

    public let store: DirectoriesStore
    public let logger: MCPAuditLogger

    private let queue = DispatchQueue(label: "ImageGlass.DirectoryTreeWalker", qos: .utility)

    /// In-memory roots indexed by canonical path. Mutated only on `queue`.
    private var roots: [URL: RootDirectory] = [:]

    /// Outstanding walk tasks, indexed by canonical path. The actor
    /// cancels the previous walk before starting a new one for the same
    /// root, satisfying §10.3.
    private var inflight: [URL: Task<Void, Never>] = [:]

    /// Filter that the in-flight walk for each root is using. Lets
    /// `scheduleWalk` short-circuit when a duplicate request lands with
    /// the same root+filter — without this guard, FSEvents-driven
    /// `reloadDirectoriesFromDisk` calls can schedule dozens of
    /// concurrent walks on the same cloud-backed root while the first
    /// walk is still running, because the walker's `roots` map isn't
    /// populated until the walk finishes.
    private var inflightFilter: [URL: RootFilter] = [:]

    public init(
        store: DirectoriesStore = .shared,
        logger: MCPAuditLogger = .shared
    ) {
        self.store = store
        self.logger = logger
    }

    // MARK: - Public API

    /// Schedule a background walk of `root` with the given `filter`.
    /// Returns immediately. The eventual completion writes an
    /// `app=directory.walk` line carrying `corr`.
    public func scheduleWalk(root: URL, filter: RootFilter, corr: String) {
        let _trace = PerformanceLog.shared.start("DirectoryWalk.Schedule", extra: [("root", root.path), ("corr", corr)])
        defer { _trace.finish() }
        queue.async { [weak self] in
            guard let self else { return }
            // Coalesce: if a walk is already running for this root with
            // the same filter, do nothing. The in-flight walk's eventual
            // `roots[root]=…` write satisfies the same contract this
            // call would have. Without this guard a chatty caller (e.g.
            // `reloadDirectoriesFromDisk` reacting to FSEvents triggered
            // by the walker's own audit-log writes) stacks dozens of
            // concurrent walks of the same cloud-backed root.
            if self.inflight[root] != nil, self.inflightFilter[root] == filter {
                return
            }
            self.inflight[root]?.cancel()
            self.inflightFilter[root] = filter
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runWalk(root: root, filter: filter, corr: corr)
            }
            self.inflight[root] = task
        }
    }

    /// Drop the root from the in-memory graph and cancel any in-flight
    /// walk. Idempotent — calling on an unknown root is a no-op.
    public func removeRoot(path: URL) {
        let _trace = PerformanceLog.shared.start("DirectoryWalk.Remove", extra: [("root", path.path)])
        defer { _trace.finish() }
        queue.async { [weak self] in
            guard let self else { return }
            self.inflight[path]?.cancel()
            self.inflight[path] = nil
            self.inflightFilter[path] = nil
            self.roots[path] = nil
            NotificationCenter.default.post(
                name: Self.didChangeNotification, object: path
            )
        }
    }

    /// Apply a new filter to one root's in-memory tree (§3A.7). Does
    /// **not** touch the filesystem. Returns the visible-count delta
    /// (positive = more files now visible).
    @discardableResult
    public func refilter(root: URL, filter: RootFilter) -> Int {
        let _trace = PerformanceLog.shared.start("DirectoryWalk.Refilter", extra: [("root", root.path)])
        defer { _trace.finish() }
        var delta = 0
        queue.sync {
            guard var r = self.roots[root] else { return }
            let before = Self.countVisible(r.tree)
            r.filter = filter
            if let tree = r.tree {
                r.tree = Self.recomputeFilter(tree, with: filter)
            }
            self.roots[root] = r
            let after = Self.countVisible(r.tree)
            delta = after - before
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: root)
        return delta
    }

    /// Apply the same filter to every known root. Returns the sum of
    /// visible-count deltas. See §6.
    @discardableResult
    public func refilterAll(filter: RootFilter) -> Int {
        let _trace = PerformanceLog.shared.start("DirectoryWalk.RefilterAll")
        defer { _trace.finish() }
        var delta = 0
        queue.sync {
            for (path, var r) in self.roots {
                let before = Self.countVisible(r.tree)
                r.filter = filter
                if let tree = r.tree {
                    r.tree = Self.recomputeFilter(tree, with: filter)
                }
                self.roots[path] = r
                delta += Self.countVisible(r.tree) - before
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return delta
    }

    /// Read-only snapshot of the current in-memory graph. Used by the
    /// panel view-model (Stage E).
    public func snapshot() -> [RootDirectory] {
        var copy: [RootDirectory] = []
        queue.sync { copy = Array(self.roots.values) }
        return copy
    }

    /// Read-only snapshot of one root, or `nil` if unknown.
    public func snapshot(of path: URL) -> RootDirectory? {
        var found: RootDirectory?
        queue.sync { found = self.roots[path] }
        return found
    }

    // MARK: - Walk

    private func runWalk(root: URL, filter: RootFilter, corr: String) async {
        let _trace = PerformanceLog.shared.start("DirectoryWalk.Run", extra: [("root", root.path), ("corr", corr)])
        var _fileCount = 0
        defer { _trace.finish(extra: [("file_count", String(_fileCount))]) }
        // Log walk start immediately so a hung walk is diagnosable even
        // if the completion line never appears.
        logger.logTreeWalkStart(path: root.path, corr: corr)

        // Wallclock for the audit line. The walk itself runs off the
        // queue so multiple roots walk in parallel. The top-level of
        // the root fans out across CPU cores via `walkParallel` — see
        // docs/performance.mdx §7.2 / §10.2.
        let walkStart = Date()
        let result = await Self.walkParallel(root: root, filter: filter)
        _fileCount = result.fileCount
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)

        // Commit to the in-memory map and the on-disk last_walked.
        queue.sync {
            self.roots[root] = RootDirectory(
                path: root,
                filter: filter,
                lastWalked: Date(),
                tree: result.tree
            )
            self.inflight[root] = nil
            self.inflightFilter[root] = nil
        }
        try? store.setLastWalked(path: root, at: Date())

        // The walker used to emit one `app=tree.node …` line per
        // directory and file (50k+ writes on a real-world root), and
        // those lines were ≥95% of `log.log`'s byte volume. The
        // walk-summary `app=directory.walk` line below already carries
        // the file count, so v1 drops per-node lines entirely. If a
        // future debugging session needs them, gate them behind a
        // dedicated `igconfig.json` debug flag — do not turn them back
        // on unconditionally.
        if result.tree == nil {
            logger.logTreeWalkFailed(path: root.path, corr: corr)
        }

        logger.logDirectoryWalk(
            path: root.path,
            count: result.fileCount,
            elapsedMs: elapsedMs,
            corr: corr
        )

        NotificationCenter.default.post(name: Self.didChangeNotification, object: root)

        // §10: auto-select-first if the viewer is empty AND we hit a
        // visible `.image` file. SVG / video / filtered-out files don't
        // trigger.
        if viewerIsEmpty, let first = result.firstImage {
            logger.logAutoSelectFirst(
                path: first.path,
                corr: corr,
                reason: "viewer_empty"
            )
            NotificationCenter.default.post(
                name: Self.firstImageFoundNotification,
                object: first,
                userInfo: ["corr": corr]
            )
        }
    }

    // MARK: - Synchronous walk implementation

    /// One-shot recursive walk. Returns the populated `DirectoryNode`
    /// tree, the visible file count, and the URL of the first
    /// `.image` file (depth-first lexicographic). Used by `runWalk` and
    /// directly by tests.
    public struct WalkResult: Sendable {
        public let tree: DirectoryNode?
        public let fileCount: Int
        public let firstImage: URL?
    }

    public static func walkSync(root: URL, filter: RootFilter) -> WalkResult {
        var fileCount = 0
        var firstImage: URL?
        let tree = walkDir(at: root, filter: filter, fileCount: &fileCount, firstImage: &firstImage)
        return WalkResult(tree: tree, fileCount: fileCount, firstImage: firstImage)
    }

    /// Parallel variant of `walkSync`. Lists the top-level children of
    /// `root` and walks each top-level subdirectory in its own task via
    /// `TaskGroup`. Top-level files are classified inline. The
    /// per-subtree walk inside each task remains the synchronous
    /// `walkDir`, so lex-ordered traversal and the visible-count
    /// accounting are preserved at the subtree level.
    ///
    /// `firstImage` is re-derived from the final tree in
    /// depth-first lexicographic order so the parallel and the
    /// sequential implementations always agree on which file gets
    /// auto-selected. See `docs/performance.mdx` §7.2.
    public static func walkParallel(root: URL, filter: RootFilter) async -> WalkResult {
        let _outer = PerformanceLog.shared.start(
            "DirectoryWalk.Parallel",
            extra: [("root", root.path)]
        )
        defer { _outer.finish() }

        // If the surrounding task has been cancelled — e.g. `scheduleWalk`
        // was invoked again for this root and the old task is now stale —
        // bail immediately instead of doing minutes of cloud-backed I/O
        // that will be thrown away.
        if Task.isCancelled {
            return WalkResult(tree: nil, fileCount: 0, firstImage: nil)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return WalkResult(tree: nil, fileCount: 0, firstImage: nil)
        }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return WalkResult(
                tree: .directory(name: root.lastPathComponent, children: []),
                fileCount: 0,
                firstImage: nil
            )
        }
        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Partition: top-level files are handled inline (cheap), top-level
        // subdirectories fan out one task each. `contentsOfDirectory`
        // already cached `.isDirectoryKey` on each URL, so a stat per
        // child is avoided — important on cloud-backed roots where each
        // stat may be a network round-trip.
        struct ChildSlot: Sendable {
            let index: Int
            let entry: URL
            let isDir: Bool
        }
        var slots: [ChildSlot] = []
        slots.reserveCapacity(sorted.count)
        for (i, entry) in sorted.enumerated() {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            slots.append(ChildSlot(index: i, entry: entry, isDir: isDir))
        }

        var children: [DirectoryNode?] = Array(repeating: nil, count: sorted.count)
        var fileCount = 0

        for slot in slots where !slot.isDir {
            guard let kind = FileKind.classify(path: slot.entry.path) else { continue }
            let passes = filter.evaluate(filename: slot.entry.lastPathComponent)
            children[slot.index] = .file(
                name: slot.entry.lastPathComponent,
                kind: kind,
                passesFilter: passes
            )
            if passes { fileCount += 1 }
        }

        struct SubtreeResult: Sendable {
            let index: Int
            let node: DirectoryNode?
            let fileCount: Int
        }

        // Spawn one task per top-level subdirectory. Swift's runtime
        // schedules these across the global concurrent pool, which is
        // sized to `ProcessInfo.processInfo.activeProcessorCount`. On a
        // 16-core Apple Silicon machine that is a 16× speed-up for
        // wide roots; on a 4-core machine it is a 4× speed-up.
        await withTaskGroup(of: SubtreeResult.self) { group in
            for slot in slots where slot.isDir {
                let entry = slot.entry
                let idx = slot.index
                let f = filter
                group.addTask {
                    var fc = 0
                    var fi: URL?
                    let node = walkDir(
                        at: entry,
                        filter: f,
                        fileCount: &fc,
                        firstImage: &fi
                    )
                    return SubtreeResult(index: idx, node: node, fileCount: fc)
                }
            }
            for await result in group {
                children[result.index] = result.node
                fileCount += result.fileCount
            }
        }

        let finalChildren = children.compactMap { $0 }
        let tree = DirectoryNode.directory(
            name: root.lastPathComponent,
            children: finalChildren
        )

        // Derive `firstImage` in lex order from the final tree so the
        // parallel and sequential walkers always pick the same file.
        let firstImage = Self.firstImageInOrder(in: tree, at: root)

        return WalkResult(tree: tree, fileCount: fileCount, firstImage: firstImage)
    }

    /// Depth-first lexicographic search for the first `.image` file
    /// whose `passesFilter` is true. Used by `walkParallel` to recover
    /// the same `firstImage` the sequential walker would have produced.
    private static func firstImageInOrder(in node: DirectoryNode, at url: URL) -> URL? {
        switch node {
        case .directory(_, let children):
            for child in children {
                let childURL = url.appendingPathComponent(child.name)
                if let found = firstImageInOrder(in: child, at: childURL) {
                    return found
                }
            }
            return nil
        case .file(_, let kind, let passes):
            return (kind == .image && passes) ? url : nil
        }
    }

    /// Threshold (ms) above which a single-directory walk emits a perf
    /// log event. Below the threshold we emit nothing: the parent
    /// `DirectoryWalk.Parallel` / `DirectoryWalk.Run` trace already
    /// covers the total wallclock, and per-directory tracing on a deep
    /// tree (e.g. a Dropbox-synced Photos library) generates millions
    /// of lines per walk — 75% of a real-world 1.36 GB perf log.
    /// Matches `docs/performance.mdx` §6.9 ("Do not wrap tiny
    /// synchronous functions … >100 µs").
    private static let singleDirSlowThresholdNs: UInt64 = 50_000_000  // 50 ms

    private static func walkDir(
        at url: URL,
        filter: RootFilter,
        fileCount: inout Int,
        firstImage: inout URL?
    ) -> DirectoryNode? {
        let started = DispatchTime.now()
        // Check cooperative cancellation once per directory. If the
        // owning task was cancelled (e.g. a newer `scheduleWalk`
        // superseded this one), stop descending instead of finishing
        // a multi-minute walk whose result will be discarded.
        if Task.isCancelled { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .directory(name: url.lastPathComponent, children: [])
        }
        // Depth-first lexicographic — §10.2.
        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var children: [DirectoryNode] = []
        for entry in sorted {
            // `contentsOfDirectory` cached `.isDirectoryKey` above; read
            // it from the URL instead of doing a fresh stat per child.
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let sub = walkDir(at: entry, filter: filter, fileCount: &fileCount, firstImage: &firstImage) {
                    children.append(sub)
                }
            } else {
                guard let kind = FileKind.classify(path: entry.path) else { continue }
                let passes = filter.evaluate(filename: entry.lastPathComponent)
                children.append(.file(
                    name: entry.lastPathComponent,
                    kind: kind,
                    passesFilter: passes
                ))
                if passes {
                    fileCount += 1
                    if kind == .image, firstImage == nil {
                        firstImage = entry
                    }
                }
            }
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
        if elapsedNs >= singleDirSlowThresholdNs {
            PerformanceLog.shared.event(
                "DirectoryWalk.SingleDir",
                extra: [
                    ("path", url.path),
                    ("elapsed_ms", String(elapsedNs / 1_000_000)),
                ]
            )
        }
        return .directory(name: url.lastPathComponent, children: children)
    }

    // MARK: - Filter recomputation (in-memory only)

    private static func recomputeFilter(_ node: DirectoryNode, with filter: RootFilter) -> DirectoryNode {
        switch node {
        case .directory(let name, let children):
            return .directory(
                name: name,
                children: children.map { recomputeFilter($0, with: filter) }
            )
        case .file(let name, let kind, _):
            return .file(
                name: name,
                kind: kind,
                passesFilter: filter.evaluate(filename: name)
            )
        }
    }

    private static func countVisible(_ node: DirectoryNode?) -> Int {
        guard let node else { return 0 }
        switch node {
        case .directory(_, let children):
            return children.reduce(0) { $0 + countVisible($1) }
        case .file(_, _, let passes):
            return passes ? 1 : 0
        }
    }
}
