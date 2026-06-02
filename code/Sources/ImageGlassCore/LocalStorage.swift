import Foundation

/// Plain-text on-disk store of scope files.
/// Format: pretty-printed JSON in ~/Library/Application Support/ImageGlass/scopes/<name>.json
public final class LocalStorage {

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
        let url = scopeURL(for: name)
        let data = try Data(contentsOf: url)
        var scope = try decoder.decode(Scope.self, from: data)
        scope.name = name // file name is authoritative
        return scope
    }

    public func saveScope(_ scope: Scope) throws {
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
