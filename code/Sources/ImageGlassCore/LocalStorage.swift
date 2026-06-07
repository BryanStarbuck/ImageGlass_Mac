import Foundation

/// Plain-text on-disk store of scope files.
/// Format: pretty-printed JSON in ~/Library/Application Support/ImageGlass/scopes/<name>.json
public final class LocalStorage: @unchecked Sendable {

    /// Distinguishable failure modes for `loadScope`. Callers (especially
    /// `AppState.activate(scopeNamed:)`) need to tell "file missing" apart
    /// from a real decode failure so the missing case can fall back to a
    /// sensible default at INFO level while a schema mismatch keeps its
    /// ERROR log + the original underlying decoder error.
    public enum Error: Swift.Error {
        case notFound(name: String)
    }

    public static let shared = LocalStorage()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Discovery

    /// Sidecar JSON files that live next to scope files in `scopes/` but are
    /// not Scope records. `crop.json` is `CropConfigStore.fileURL`;
    /// `crop-live.json` is legacy bridge state left over from earlier builds.
    /// Treating them as scopes makes `bootstrapIfNeeded()` pick them up and
    /// then `loadScope()` fails to decode them.
    private static let reservedSidecarNames: Set<String> = ["crop", "crop-live"]

    public func listScopes() throws -> [String] {
        try AppPaths.ensureDirectories()
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: AppPaths.scopesDir,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !Self.reservedSidecarNames.contains($0) }
            .sorted()
    }

    public func scopeURL(for name: String) -> URL {
        AppPaths.scopesDir.appendingPathComponent("\(name).json")
    }

    public func scopeExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: scopeURL(for: name).path)
    }

    // MARK: - Read / Write

    public func loadScope(_ name: String) throws -> Scope {
        let _trace = PerformanceLog.shared.start(
            "LocalStorage.Read",
            extra: [("file", "\(name).json")]
        )
        defer { _trace.finish() }
        let url = scopeURL(for: name)
        // Distinguish "file missing" from "file present but malformed" so
        // callers can react differently. A missing file is a normal
        // condition (scope was deleted, never written, or last-active
        // name is stale across an upgrade); a malformed file is a real
        // decode error that deserves the existing ERROR log.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.notFound(name: name)
        }
        let data = try Data(contentsOf: url)
        var scope = try decoder.decode(Scope.self, from: data)
        scope.name = name // file name is authoritative
        return scope
    }

    public func saveScope(_ scope: Scope) throws {
        let _trace = PerformanceLog.shared.start(
            "LocalStorage.Write",
            extra: [("file", "\(scope.name).json")]
        )
        defer { _trace.finish() }
        try AppPaths.ensureDirectories()
        let url = scopeURL(for: scope.name)
        let data = try encoder.encode(scope)
        try data.write(to: url, options: .atomic)
    }

    public func deleteScope(_ name: String) throws {
        let url = scopeURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - First-run

    /// Ensures at least one scope file exists. Returns the bootstrap scope name.
    @discardableResult
    public func bootstrapIfNeeded() throws -> String {
        try AppPaths.ensureDirectories()
        let existing = try listScopes()
        if let first = existing.first { return first }
        let starter = Scope.starter
        try saveScope(starter)
        return starter.name
    }
}
