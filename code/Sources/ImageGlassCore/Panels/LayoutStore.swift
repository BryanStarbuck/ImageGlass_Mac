import Foundation

/// Persists `LayoutDocument` to and from
/// `~/Library/Application Support/ImageGlass/layout.json`.
///
/// Plain-text on disk (fork charter). Pretty-printed, sorted keys, ISO-8601
/// dates. Atomic writes so a crash mid-save does not corrupt the file.
///
/// Save is debounced by `LayoutController` (200 ms per the spec); this store
/// is intentionally synchronous — debouncing is the caller's job so tests
/// can drive it directly.
public final class LayoutStore: @unchecked Sendable {

    public static let shared = LayoutStore()

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

    public var fileURL: URL {
        AppPaths.appSupportDir.appendingPathComponent("layout.json")
    }

    /// Reads the document from disk. Returns `LayoutDocument.initial` if the
    /// file is missing. Throws only on a real I/O or JSON decode error.
    public func load() throws -> LayoutDocument {
        let url = fileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return LayoutDocument.initial
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(LayoutDocument.self, from: data)
    }

    /// Writes the document atomically. Creates parent directories on demand.
    public func save(_ document: LayoutDocument) throws {
        try AppPaths.ensureDirectories()
        var doc = document
        doc.lastSavedAt = Date()
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Convenience: load → mutate → save. Used by MCP and the layout
    /// director to apply small, atomic changes.
    public func update(_ mutate: (inout LayoutDocument) -> Void) throws -> LayoutDocument {
        var doc = try load()
        mutate(&doc)
        try save(doc)
        return doc
    }
}
