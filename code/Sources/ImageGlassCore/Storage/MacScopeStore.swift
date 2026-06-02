import Foundation

/// YAML-backed scope store at the spec-mandated path
/// `~/Library/Application Support/ImageGlass_Mac/scopes/<name>.yaml`.
///
/// Lives alongside the legacy JSON `LocalStorage` rather than replacing
/// it: new MCP tools (`update_scope`, `list_files_in_scope`, …) read and
/// write YAML here, and also mirror the same `Scope` into `LocalStorage`
/// so the existing GUI keeps working without a migration step.
/// See `docs/use_cases/mcp_file.mdx` §0.
public final class MacScopeStore: @unchecked Sendable {

    public static let shared = MacScopeStore()

    /// Optional override for tests so they can isolate the YAML files.
    public var overrideDir: URL?

    public init(overrideDir: URL? = nil) {
        self.overrideDir = overrideDir
    }

    public var scopesDir: URL {
        overrideDir ?? AppPaths.macScopesDir
    }

    public func scopeURL(for name: String) -> URL {
        scopesDir.appendingPathComponent("\(name).yaml")
    }

    public func scopeExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: scopeURL(for: name).path)
    }

    public func listScopes() throws -> [String] {
        try ensureDir()
        let fm = FileManager.default
        guard fm.fileExists(atPath: scopesDir.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: scopesDir, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == "yaml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func loadScope(_ name: String) throws -> Scope {
        let url = scopeURL(for: name)
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var scope = try ScopeYAML.decode(s)
        scope.name = name
        return scope
    }

    public func saveScope(_ scope: Scope) throws {
        try ensureDir()
        let url = scopeURL(for: scope.name)
        let yaml = ScopeYAML.encode(scope)
        guard let data = yaml.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeAtomically(data: data, to: url)
    }

    public func deleteScope(_ name: String) throws {
        let url = scopeURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Ensure that a YAML file for `name` exists at the spec path. If
    /// missing, mirror the scope from the JSON `LocalStorage` if available,
    /// otherwise materialise a fresh empty scope. Returns the scope
    /// currently on disk after this call.
    @discardableResult
    public func ensureYAMLPresent(
        name: String,
        legacy: LocalStorage = .shared
    ) throws -> Scope {
        try ensureDir()
        if scopeExists(name) {
            return try loadScope(name)
        }
        let scope: Scope
        let legacyLoaded: Scope?
        if legacy.scopeExists(name) {
            do {
                legacyLoaded = try legacy.loadScope(name)
            } catch {
                ErrorLog.log("legacy LocalStorage.loadScope failed for \(name)",
                             error: error,
                             class: String(describing: Self.self))
                legacyLoaded = nil
            }
        } else {
            legacyLoaded = nil
        }
        if let loaded = legacyLoaded {
            scope = loaded
        } else if name == "default" {
            scope = Scope(
                name: "default",
                schemaVersion: Scope.currentSchemaVersion,
                description: nil,
                criteria: [],
                sort: .init(),
                filter: .init(),
                lastEvaluated: nil,
                resolved: []
            )
        } else {
            scope = Scope(name: name)
        }
        try saveScope(scope)
        return scope
    }

    // MARK: - Helpers

    private func ensureDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: scopesDir.path) {
            try fm.createDirectory(at: scopesDir, withIntermediateDirectories: true)
        }
    }

    /// Atomic write: write to a temp sibling then rename. Matches the
    /// "temp file + rename" promise in `docs/use_cases/mcp_file.mdx` §4.3.
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
