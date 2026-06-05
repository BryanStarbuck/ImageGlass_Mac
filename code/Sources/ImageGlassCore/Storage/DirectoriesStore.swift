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

    public static let shared = DirectoriesStore()

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
        return AppPaths.macDirectoriesFile
    }

    private let lock = NSLock()

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

    // MARK: - Private unlocked I/O helpers
    // Call only while `lock` is held by the caller.

    private func loadUnlocked() throws -> DirectoriesFile {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            return DirectoriesFile()
        }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try DirectoriesYAML.decode(s)
    }

    private func saveUnlocked(_ file: DirectoriesFile) throws {
        try ensureContainerDir()
        let yaml = DirectoriesYAML.encode(file)
        guard let data = yaml.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeAtomically(data: data, to: fileURL)
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
        let dir = fileURL.deletingLastPathComponent()
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
