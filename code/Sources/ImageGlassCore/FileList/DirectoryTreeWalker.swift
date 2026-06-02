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
        queue.async { [weak self] in
            guard let self else { return }
            self.inflight[root]?.cancel()
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
        queue.async { [weak self] in
            guard let self else { return }
            self.inflight[path]?.cancel()
            self.inflight[path] = nil
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
        // Wallclock for the audit line. The walk itself runs off the
        // queue so multiple roots walk in parallel.
        let walkStart = Date()
        let result = Self.walkSync(root: root, filter: filter)
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
        }
        try? store.setLastWalked(path: root, at: Date())

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

    private static func walkDir(
        at url: URL,
        filter: RootFilter,
        fileCount: inout Int,
        firstImage: inout URL?
    ) -> DirectoryNode? {
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
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &childIsDir)
            if childIsDir.boolValue {
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
