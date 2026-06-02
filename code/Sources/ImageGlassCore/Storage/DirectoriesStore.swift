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

    public init(overrideFile: URL? = nil) {
        self.overrideFile = overrideFile
    }

    public var fileURL: URL {
        overrideFile ?? AppPaths.macDirectoriesFile
    }

    private let lock = NSLock()

    // MARK: - High-level API

    /// Load the current state from disk. If the file doesn't exist yet,
    /// returns an empty `DirectoriesFile` (the panel's bootstrap state
    /// in §1).
    public func load() throws -> DirectoriesFile {
        lock.lock()
        defer { lock.unlock() }
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

    /// Save the entire `DirectoriesFile` atomically.
    public func save(_ file: DirectoriesFile) throws {
        lock.lock()
        defer { lock.unlock() }
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
    @discardableResult
    public func addRoot(path: String, filter: RootFilter = .empty) throws -> (URL, alreadyExisted: Bool) {
        let canonical = try Self.canonicalize(path)
        var file = (try? load()) ?? DirectoriesFile()
        if let _ = file.roots.firstIndex(where: { $0.path == canonical }) {
            return (canonical, true)
        }
        file.roots.append(RootDirectory(path: canonical, filter: filter))
        try save(file)
        return (canonical, false)
    }

    /// Remove the root with the given path. Returns whether anything was
    /// removed.
    @discardableResult
    public func removeRoot(path: String) throws -> Bool {
        let canonical = try Self.canonicalize(path, mustExist: false)
        var file = (try? load()) ?? DirectoriesFile()
        let before = file.roots.count
        file.roots.removeAll { $0.path == canonical }
        let removed = file.roots.count != before
        if removed { try save(file) }
        return removed
    }

    /// Replace the filter on one root. Returns false if the root is
    /// unknown.
    @discardableResult
    public func updateFilter(path: String, filter: RootFilter) throws -> Bool {
        let canonical = try Self.canonicalize(path, mustExist: false)
        var file = (try? load()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == canonical }) else {
            return false
        }
        file.roots[idx].filter = filter
        try save(file)
        return true
    }

    /// Apply the same filter to every existing root. Returns the number
    /// of roots affected.
    @discardableResult
    public func setGlobalFilter(_ filter: RootFilter) throws -> Int {
        var file = (try? load()) ?? DirectoriesFile()
        for i in file.roots.indices {
            file.roots[i].filter = filter
        }
        let n = file.roots.count
        try save(file)
        return n
    }

    /// Wipe every root. Used by §9's `clear_directories`.
    public func clearAll() throws {
        var file = (try? load()) ?? DirectoriesFile()
        file.roots = []
        try save(file)
    }

    /// Update the cached `last_walked` timestamp for one root after the
    /// walker completes a pass.
    public func setLastWalked(path: URL, at date: Date) throws {
        var file = (try? load()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == path }) else {
            return
        }
        file.roots[idx].lastWalked = date
        try save(file)
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

    public var description: String {
        switch self {
        case .pathNotFound(let p): return "Path not found: \(p)"
        case .invalidFilter(let m): return "Invalid filter: \(m)"
        case .alreadyExists(let p): return "Already a root: \(p)"
        }
    }
}
