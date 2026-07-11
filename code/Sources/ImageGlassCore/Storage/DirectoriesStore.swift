import Foundation

/// YAML-backed store for the directory tree panel
/// (`docs/list_of_files.mdx` §3A.1, walked end-to-end in
/// `docs/use_cases/mcp_file.mdx`). One file at:
///
///     ~/Library/Application Support/ImageGlass_Mac/directories.yaml
///
/// The MCP tools (`add_directory`, `remove_directory`, …) and the
/// SwiftUI panel both read and write through this store. Writes are
/// atomic (temp file + `replaceItem`).
public final class DirectoriesStore: @unchecked Sendable {

    /// Multi-window dispatch hook (multi_window.mdx §6). The GUI
    /// installs a resolver at launch that returns the frontmost
    /// `WindowState.directoriesStore`. The CLI, the standalone MCP
    /// server, and tests leave it nil, in which case `.shared`
    /// resolves to `_sharedFallback` — the legacy single-window
    /// instance that points at the v1 file (with the §3.5 compat
    /// shim).
    ///
    /// Implementation note: `@unchecked Sendable` because the resolver
    /// is set exactly once at launch on the main actor and read
    /// thereafter; concurrent installs are not supported.
    nonisolated(unsafe) public static var frontmostResolver: (@Sendable () -> DirectoriesStore?)?

    /// The default-target store for any caller that does not specify
    /// a window. When the GUI is attached this resolves to the
    /// frontmost window's per-window store; when not (CLI, MCP-only
    /// process, tests), it falls back to the legacy singleton.
    public static var shared: DirectoriesStore {
        if let resolver = frontmostResolver, let store = resolver() {
            return store
        }
        return _sharedFallback
    }

    private static let _sharedFallback = DirectoriesStore()

    /// Optional override for tests so they can isolate the YAML file.
    public var overrideFile: URL?

    /// Per-window targeting (multi_window.mdx §3.3, §4.2). When set, this
    /// store reads/writes `directories_window_<windowID>.yaml` instead of
    /// the legacy `directories.yaml`. Mutating MCP tools route through
    /// `WindowRegistry` to the per-window store of the frontmost window.
    /// Nil means "legacy v1 single-window file" — kept for the migration
    /// window and for tests that exercise the v1 path.
    public let windowID: Int?

    public init(overrideFile: URL? = nil) {
        self.overrideFile = overrideFile
        self.windowID = nil
    }

    /// Per-window initializer (multi_window.mdx §4.2). The store's
    /// `fileURL` resolves to `directories_window_<id>.yaml`; tests can
    /// still override the path via `overrideFile`.
    public init(windowID: Int, overrideFile: URL? = nil) {
        precondition(windowID >= 1, "window_id must be >= 1")
        self.overrideFile = overrideFile
        self.windowID = windowID
    }

    public var fileURL: URL {
        if let overrideFile { return overrideFile }
        if let windowID { return AppPaths.macDirectoriesWindowFile(id: windowID) }
        // v1 → v2 compat shim (multi_window.mdx §3.5): when this store is
        // the legacy `.shared` singleton (no `windowID` set), prefer the
        // v1 file if it still exists, otherwise fall back to
        // `directories_window_1.yaml`. After the migration runs the v1
        // file has been renamed to `.v1.bak`, so all reads/writes through
        // `.shared` start landing on window 1's file — which is the
        // single-window-equivalent behavior the rest of the codebase
        // assumes during Groups B/C.
        let v1 = AppPaths.macDirectoriesFile
        if FileManager.default.fileExists(atPath: v1.path) {
            return v1
        }
        return AppPaths.macDirectoriesWindowFile(id: 1)
    }

    private let lock = NSLock()

    // MARK: - Cache + write coalescer state (perf/plans/LocalStorage.plan)
    // All access guarded by `lock`. The debounce timer fires on
    // `flushQueue`; its handler re-acquires `lock`, snapshots the
    // pending file into a local value, and writes outside the lock.

    private var cachedFile: DirectoriesFile?
    private var cachedMTime: Date?
    private var cachedURL: URL?
    private var dirty: Bool = false
    private var pendingFlushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "ImageGlassCore.DirectoriesStore.flush")
    private static let debounceInterval: DispatchTimeInterval = .milliseconds(250)

    /// When true, `saveUnlocked` writes synchronously instead of
    /// scheduling a debounced flush. Auto-enabled when `overrideFile`
    /// is set (test path) so existing tests that `String(contentsOf:)`
    /// the YAML right after a mutate continue to observe the new bytes.
    private var synchronousWrites: Bool {
        return overrideFile != nil
    }

    deinit {
        // Best-effort: surface any in-memory mutations to disk on
        // teardown. The C runtime tears down without an event loop,
        // so we can't rely on the debounce timer firing.
        flushPendingWritesNoThrow()
    }

    // MARK: - High-level API

    /// Load the current state from disk. If the file doesn't exist yet,
    /// returns an empty `DirectoriesFile` (the panel's bootstrap state
    /// in §1).
    public func load() throws -> DirectoriesFile {
        let _trace = PerformanceLog.shared.start("LocalStorage.Read.directories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    /// Save the entire `DirectoriesFile` atomically.
    public func save(_ file: DirectoriesFile) throws {
        let _trace = PerformanceLog.shared.start("LocalStorage.Write.directories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(file)
    }

    /// Synchronously persist any in-memory mutations that have been
    /// staged by the write coalescer but not yet flushed. Call from
    /// `applicationWillTerminate` (GUI) and any other shutdown path
    /// that wants durability guarantees.
    public func flushPendingWrites() throws {
        lock.lock()
        let snapshot: DirectoriesFile? = dirty ? cachedFile : nil
        let url = cachedURL ?? fileURL
        if snapshot != nil {
            dirty = false
            pendingFlushTimer?.cancel()
            pendingFlushTimer = nil
        }
        lock.unlock()
        guard let file = snapshot else { return }
        try writeFileNow(file, to: url)
        lock.lock()
        cachedURL = url
        cachedMTime = currentMTime(of: url)
        lock.unlock()
    }

    private func flushPendingWritesNoThrow() {
        do { try flushPendingWrites() } catch { /* best effort */ }
    }

    // MARK: - Private unlocked I/O helpers
    // Call only while `lock` is held by the caller.

    private func loadUnlocked() throws -> DirectoriesFile {
        let url = fileURL
        if cachedURL != url {
            // Path changed (overrideFile flipped, frontmost window
            // resolver pointed elsewhere). Drop the cache and any
            // in-flight debounce — the old buffer belongs to the
            // previous URL.
            cachedFile = nil
            cachedMTime = nil
            cachedURL = nil
            dirty = false
            pendingFlushTimer?.cancel()
            pendingFlushTimer = nil
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            if dirty, let file = cachedFile { return file }
            let empty = DirectoriesFile()
            cachedFile = empty
            cachedMTime = nil
            cachedURL = url
            return empty
        }
        let diskMTime = currentMTime(of: url)
        if let cached = cachedFile,
           let cachedM = cachedMTime,
           let diskM = diskMTime,
           cachedM == diskM,
           !dirty {
            return cached
        }
        if dirty, let cached = cachedFile {
            return cached
        }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try DirectoriesYAML.decode(s)
        cachedFile = decoded
        cachedMTime = diskMTime
        cachedURL = url
        return decoded
    }

    private func saveUnlocked(_ file: DirectoriesFile) throws {
        let url = fileURL
        cachedFile = file
        cachedURL = url
        dirty = true
        if synchronousWrites {
            pendingFlushTimer?.cancel()
            pendingFlushTimer = nil
            try writeFileNow(file, to: url)
            cachedMTime = currentMTime(of: url)
            dirty = false
            return
        }
        scheduleDebouncedFlushLocked()
    }

    private func scheduleDebouncedFlushLocked() {
        pendingFlushTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + Self.debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.handleDebouncedFlush()
        }
        pendingFlushTimer = timer
        timer.resume()
    }

    private func handleDebouncedFlush() {
        lock.lock()
        guard dirty, let file = cachedFile else {
            pendingFlushTimer = nil
            lock.unlock()
            return
        }
        let url = cachedURL ?? fileURL
        dirty = false
        pendingFlushTimer = nil
        lock.unlock()
        do {
            try writeFileNow(file, to: url)
            lock.lock()
            cachedURL = url
            cachedMTime = currentMTime(of: url)
            lock.unlock()
        } catch {
            // Re-mark dirty so the next mutation (or shutdown flush)
            // retries. Logging to PerformanceLog would recurse; the
            // GUI's user-visible error path runs through explicit
            // calls to `save(_:)`, not the debounce queue.
            lock.lock()
            dirty = true
            lock.unlock()
        }
    }

    private func writeFileNow(_ file: DirectoriesFile, to url: URL) throws {
        try ensureContainerDir(for: url)
        let yaml = DirectoriesYAML.encode(file)
        guard let data = yaml.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeAtomically(data: data, to: url)
    }

    private func currentMTime(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Make sure the file exists on disk, materialising an empty one if
    /// it doesn't. Returns the file currently on disk. Called on first
    /// launch (§1).
    @discardableResult
    public func ensureExists() throws -> DirectoriesFile {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let blank = DirectoriesFile()
            try save(blank)
            return blank
        }
        return try load()
    }

    // MARK: - Mutations used by the MCP tools

    /// Append a new root. Returns the canonical path it was stored at
    /// and a flag indicating whether the path was already present.
    /// The entire load → check → append → save sequence is performed
    /// under a single lock acquisition, preventing duplicate entries
    /// from concurrent calls (spec §3A.10, idempotency guarantee).
    @discardableResult
    public func addRoot(path: String, filter: RootFilter = .empty) throws -> (URL, alreadyExisted: Bool) {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        let canonical = try Self.canonicalize(path)
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        if file.roots.contains(where: { $0.path == canonical }) {
            return (canonical, true)
        }
        file.roots.append(RootDirectory(path: canonical, filter: filter))
        try saveUnlocked(file)
        return (canonical, false)
    }

    /// Remove the root with the given path. Returns whether anything was
    /// removed.
    @discardableResult
    public func removeRoot(path: String) throws -> Bool {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        let canonical = try Self.canonicalize(path, mustExist: false)
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        let before = file.roots.count
        file.roots.removeAll { $0.path == canonical }
        let removed = file.roots.count != before
        if removed { try saveUnlocked(file) }
        return removed
    }

    /// Replace the filter on one root. Returns false if the root is
    /// unknown.
    @discardableResult
    public func updateFilter(path: String, filter: RootFilter) throws -> Bool {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        let canonical = try Self.canonicalize(path, mustExist: false)
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == canonical }) else {
            return false
        }
        file.roots[idx].filter = filter
        try saveUnlocked(file)
        return true
    }

    /// Apply the same filter to every existing root. Returns the number
    /// of roots affected.
    @discardableResult
    public func setGlobalFilter(_ filter: RootFilter) throws -> Int {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        for i in file.roots.indices {
            file.roots[i].filter = filter
        }
        let n = file.roots.count
        try saveUnlocked(file)
        return n
    }

    /// Wipe every root. Used by §9's `clear_directories`.
    public func clearAll() throws {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        file.roots = []
        try saveUnlocked(file)
    }

    /// include_checks.mdx §5.3 / §11.1 — set the include override for
    /// one row. Passing `.inherit` removes the matching
    /// `include_overrides[]` entry entirely (§5.5 — `inherit` is the
    /// absence of an entry). Returns the resolved state after the
    /// change so the caller can report `{ ok, resolved }` per §11.1.
    /// `rootPath` must match a registered root; `relativePath` is the
    /// path **relative** to that root.
    @discardableResult
    public func setIncludeState(
        rootPath: URL,
        relativePath: String,
        state: IncludeState
    ) throws -> IncludeState {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else {
            throw DirectoriesStoreError.pathNotFound(rootPath.path)
        }
        var root = file.roots[idx]
        let normalized = RootDirectory.normalize(relativePath)
        root.includeOverrides.removeAll {
            RootDirectory.normalize($0.path) == normalized
        }
        if state != .inherit {
            root.includeOverrides.append(
                IncludeOverrideEntry(path: normalized, state: state)
            )
        }
        file.roots[idx] = root
        try saveUnlocked(file)
        return root.effectiveState(for: normalized)
    }

    /// include_checks.mdx §5.2 / §11.3 — root-level default. `inherit`
    /// is rejected per §5.2 (the resolver needs a concrete fallback).
    public func setDefaultIncludeState(
        rootPath: URL,
        state: IncludeState
    ) throws {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        guard state != .inherit else {
            throw DirectoriesStoreError.invalidIncludeState("inherit")
        }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else {
            throw DirectoriesStoreError.pathNotFound(rootPath.path)
        }
        file.roots[idx].defaultIncludeState = state
        try saveUnlocked(file)
    }

    /// include_checks.mdx §7.2 — recursively set a node **and every
    /// descendant** to `state` in one atomic write. On a folder or file
    /// (`relativePath` non-empty) the node's own override is set to
    /// `state` and every descendant override is dropped so the whole
    /// subtree resolves to `state` by inheritance (§6.4). On the root
    /// itself (`relativePath` empty) the root default is set and all of
    /// that root's overrides are cleared. `inherit` is rejected — a
    /// recursive "make this inherit" has no well-defined meaning at the
    /// root and would just be "clear overrides" at a node.
    @discardableResult
    public func setSubtreeIncludeState(
        rootPath: URL,
        relativePath: String,
        state: IncludeState
    ) throws -> IncludeState {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        guard state != .inherit else {
            throw DirectoriesStoreError.invalidIncludeState("inherit")
        }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else {
            throw DirectoriesStoreError.pathNotFound(rootPath.path)
        }
        var root = file.roots[idx]
        let normalized = RootDirectory.normalize(relativePath)
        if normalized.isEmpty {
            // The root itself — "including children" is the whole root
            // subtree. Set the default and drop every override so the
            // entire root resolves to `state` uniformly.
            root.defaultIncludeState = state
            root.includeOverrides.removeAll()
        } else {
            // Drop the node's own override and every descendant override,
            // then write one explicit override on the node. Descendants
            // carry no entry, so they inherit the node's new decision.
            let prefix = normalized + "/"
            root.includeOverrides.removeAll { entry in
                let n = RootDirectory.normalize(entry.path)
                return n == normalized || n.hasPrefix(prefix)
            }
            root.includeOverrides.append(
                IncludeOverrideEntry(path: normalized, state: state)
            )
        }
        file.roots[idx] = root
        try saveUnlocked(file)
        return root.effectiveState(for: normalized)
    }

    /// include_checks.mdx §7.3 — switch the **entire tree** (every root
    /// and every node under it) to `state` in one atomic write. Sets each
    /// root's `default_include_state` and clears all `include_overrides`
    /// so every row resolves uniformly to `state`. `include` is the
    /// factory default; the "Change Include Off" menu item sets
    /// `exclude`. Returns the number of roots affected. `inherit` is
    /// rejected (roots need a concrete default, §5.2).
    @discardableResult
    public func setAllRootsIncludeState(state: IncludeState) throws -> Int {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        guard state != .inherit else {
            throw DirectoriesStoreError.invalidIncludeState("inherit")
        }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        for i in file.roots.indices {
            file.roots[i].defaultIncludeState = state
            file.roots[i].includeOverrides.removeAll()
        }
        try saveUnlocked(file)
        return file.roots.count
    }

    /// moves_and_reconciliation.mdx §4.4 / §5.2 / include_checks.mdx §12A.1
    /// — apply an **in-tree move** to the include state: an item (and its
    /// subtree) at root-relative path `fromRelative` moved to
    /// `toRelative` under the same root. Reprefixes the matching
    /// `include_overrides[]` keys so every explicit green check / exclude
    /// is carried forward to the new location; states are untouched. One
    /// atomic write. Returns the number of override entries rewritten
    /// (0 when `fromRelative == toRelative`, e.g. a pure root relocation).
    @discardableResult
    public func applyInTreeMove(
        rootPath: URL,
        fromRelative: String,
        toRelative: String
    ) throws -> Int {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else {
            throw DirectoriesStoreError.pathNotFound(rootPath.path)
        }
        let n = file.roots[idx].rewriteOverridePaths(
            fromRelative: fromRelative, toRelative: toRelative
        )
        if n > 0 { try saveUnlocked(file) }
        return n
    }

    /// moves_and_reconciliation.mdx §5.4 / include_checks.mdx §12A.3 —
    /// an item that moved **out of scope** loses its explicit check.
    /// Deletes the override for `relativePath` and every descendant.
    /// One atomic write. Returns the count deleted.
    @discardableResult
    public func dropOverridesOutOfScope(
        rootPath: URL,
        relativePath: String
    ) throws -> Int {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else {
            throw DirectoriesStoreError.pathNotFound(rootPath.path)
        }
        let n = file.roots[idx].dropOverrides(under: relativePath)
        if n > 0 { try saveUnlocked(file) }
        return n
    }

    /// moves_and_reconciliation.mdx §4.5 / §7.5 / include_checks.mdx §12A.2
    /// — a watched **root** was relocated (moved/renamed) while every
    /// item kept its position under the root. Rewrites the root's `path:`
    /// to `newPath`; because items are unmoved relative to the root, the
    /// `include_overrides[]` keys are untouched (zero override churn).
    /// One atomic write. Returns false if `oldPath` is not a known root.
    @discardableResult
    public func relocateRoot(oldPath: URL, newPath: URL) throws -> Bool {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == oldPath }) else {
            return false
        }
        file.roots[idx].path = newPath
        try saveUnlocked(file)
        return true
    }

    /// Update the cached `last_walked` timestamp for one root after the
    /// walker completes a pass.
    public func setLastWalked(path: URL, at date: Date) throws {
        let _trace = PerformanceLog.shared.start("LocalStorage.MutateDirectories")
        defer { _trace.finish() }
        lock.lock()
        defer { lock.unlock() }
        var file = (try? loadUnlocked()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == path }) else {
            return
        }
        file.roots[idx].lastWalked = date
        try saveUnlocked(file)
    }

    // MARK: - Helpers

    /// Expand `~/`, resolve `..`, and (when the path actually exists)
    /// resolve symlinks. Throws `pathNotFound` if `mustExist` is true
    /// and the resulting path does not exist.
    public static func canonicalize(_ raw: String, mustExist: Bool = true) throws -> URL {
        let expanded = AppPaths.expandTilde(raw)
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            url = url.resolvingSymlinksInPath()
        } else if mustExist {
            throw DirectoriesStoreError.pathNotFound(raw)
        }
        return url
    }

    private func ensureContainerDir() throws {
        try ensureContainerDir(for: fileURL)
    }

    private func ensureContainerDir(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeAtomically(data: Data, to url: URL) throws {
        let tempURL = url.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
    }
}

public enum DirectoriesStoreError: Error, CustomStringConvertible {
    case pathNotFound(String)
    case invalidFilter(String)
    case alreadyExists(String)
    /// A `kind: regex` filter item carries a regex that `NSRegularExpression`
    /// refuses to compile (mcp_file.mdx §10B.9). The MCP tool layer maps
    /// this to `err=invalid_regex` in `log.log`.
    case invalidRegex(pattern: String, reason: String)
    /// A filter item's pattern still contains `/` after the boundary
    /// normalization stripped the `.../` recursive-prefix shorthand
    /// (mcp_file.mdx §10B.1 / §10B.9). v1 only supports filename
    /// matching; the MCP tool layer maps this to
    /// `err=path_separator_in_pattern`.
    case pathSeparatorInPattern(String)
    /// include_checks.mdx §11.1 — an `state=` value outside the
    /// three-token vocabulary, or `inherit` passed to
    /// `set_default_include_state` (which only accepts the two
    /// concrete states per §5.2).
    case invalidIncludeState(String)

    public var description: String {
        switch self {
        case .pathNotFound(let p): return "Path not found: \(p)"
        case .invalidFilter(let m): return "Invalid filter: \(m)"
        case .alreadyExists(let p): return "Already a root: \(p)"
        case .invalidRegex(let p, let r): return "Invalid regex \"\(p)\": \(r)"
        case .pathSeparatorInPattern(let p): return "Pattern \"\(p)\" contains a path separator '/'; v1 filters match against the filename only (mcp_file.mdx §10B.8)."
        case .invalidIncludeState(let v): return "Invalid include state \"\(v)\"; expected one of include / inherit / exclude (include_checks.mdx §11.1)."
        }
    }

    /// The `err=` value the MCP tools should journal for this error.
    /// Centralized here so the spec contract (mcp_file.mdx §10B.9) and
    /// the tool dispatchers stay in sync.
    public var auditCode: String {
        switch self {
        case .pathNotFound:            return "path_not_found"
        case .invalidFilter:           return "invalid_filter"
        case .alreadyExists:           return "already_exists"
        case .invalidRegex:            return "invalid_regex"
        case .pathSeparatorInPattern:  return "path_separator_in_pattern"
        case .invalidIncludeState:     return "invalid_state"
        }
    }
}
