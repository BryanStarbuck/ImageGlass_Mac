import Foundation

/// YAML-backed per-window settings store
/// (multi_window.mdx §3.2, §4.4). One instance per `window_id`. Reads
/// and writes `settings_window_<windowID>.yaml`. Writes are atomic
/// (temp file + `replaceItem`) and serialized through an instance
/// `NSLock` so the per-window serial-queue contract (§3.4) is
/// satisfied without an actor hop.
public final class WindowScopedSettingsStore: @unchecked Sendable {

    public let windowID: Int

    /// Optional override for tests; mirrors `DirectoriesStore.overrideFile`.
    public var overrideFile: URL?

    public init(windowID: Int, overrideFile: URL? = nil) {
        precondition(windowID >= 1, "window_id must be >= 1")
        self.windowID = windowID
        self.overrideFile = overrideFile
    }

    public var fileURL: URL {
        overrideFile ?? AppPaths.macSettingsWindowFile(id: windowID)
    }

    private let lock = NSLock()

    // MARK: - Load / save

    /// Load the file. If it does not exist yet, returns a fresh default
    /// `WindowScopedSettings(windowID:)` (the bootstrap state in §1.4).
    public func load() throws -> WindowScopedSettings {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func save(_ settings: WindowScopedSettings) throws {
        precondition(settings.windowID == windowID,
            "WindowScopedSettingsStore[\(windowID)] cannot save settings carrying window_id=\(settings.windowID)")
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(settings)
    }

    @discardableResult
    public func ensureExists() throws -> WindowScopedSettings {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let blank = WindowScopedSettings(windowID: windowID)
            try save(blank)
            return blank
        }
        return try load()
    }

    // MARK: - Convenience mutators

    /// Atomically read-modify-write under the store's lock.
    public func mutate(_ body: (inout WindowScopedSettings) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var s = (try? loadUnlocked()) ?? WindowScopedSettings(windowID: windowID)
        body(&s)
        try saveUnlocked(s)
    }

    // MARK: - Private I/O

    private func loadUnlocked() throws -> WindowScopedSettings {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            return WindowScopedSettings(windowID: windowID)
        }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try WindowScopedSettingsYAML.decode(s, expectedWindowID: windowID)
    }

    private func saveUnlocked(_ s: WindowScopedSettings) throws {
        try ensureContainerDir()
        let yaml = WindowScopedSettingsYAML.encode(s)
        guard let data = yaml.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeAtomically(data: data, to: fileURL)
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
