import Foundation

/// One row in the per-scope audit log. Recorded on every evaluation so the
/// user (and Claude Code) can answer "what was in this scope on June 1st?"
/// or "what did the last 10 evaluations add and drop?".
///
/// The on-disk format is **JSON Lines** (one row per line, append-only)
/// — still plain text, still grep-able, still version-controllable.
public struct ScopeAuditEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var fileCount: Int
    public var added: [String]
    public var removed: [String]
    public var sources: [String]?

    public init(timestamp: Date,
                fileCount: Int,
                added: [String] = [],
                removed: [String] = [],
                sources: [String]? = nil) {
        self.timestamp = timestamp
        self.fileCount = fileCount
        self.added = added
        self.removed = removed
        self.sources = sources
    }
}

/// Append-only JSONL audit log, one file per scope.
public final class ScopeAuditLog {

    public static let shared = ScopeAuditLog()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        // One line per entry — DO NOT pretty-print, but keep keys sorted so
        // diffs are deterministic.
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func logURL(for scopeName: String) -> URL {
        AppPaths.auditDir.appendingPathComponent("\(scopeName).log")
    }

    /// Append a row to the scope's audit log. Creates the file if needed.
    public func append(_ entry: ScopeAuditEntry, scopeName: String) throws {
        let _trace = PerformanceLog.shared.start(
            "Scope.AuditAppend",
            extra: [("scope", scopeName)]
        )
        defer { _trace.finish() }
        try AppPaths.ensureDirectories()
        let url = logURL(for: scopeName)
        var data = try encoder.encode(entry)
        data.append(0x0A) // newline

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer {
            do {
                try handle.close()
            } catch {
                ErrorLog.log("failed to close audit log handle for \(scopeName)",
                             error: error,
                             class: "ScopeAuditLog")
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Read the last `limit` entries (most recent last). Returns `[]` if no
    /// log exists yet for this scope.
    public func tail(scopeName: String, limit: Int = 50) throws -> [ScopeAuditEntry] {
        let url = logURL(for: scopeName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            ErrorLog.log("audit log for \(scopeName) not valid UTF-8",
                         class: "ScopeAuditLog")
            return []
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        let slice = lines.suffix(max(0, limit))
        return slice.compactMap { line -> ScopeAuditEntry? in
            guard let d = line.data(using: .utf8) else { return nil }
            do {
                return try decoder.decode(ScopeAuditEntry.self, from: d)
            } catch {
                ErrorLog.log("failed to decode audit entry for \(scopeName)",
                             error: error,
                             class: "ScopeAuditLog")
                return nil
            }
        }
    }

    /// Erase the audit log for a scope (used on `delete_scope`).
    public func clear(scopeName: String) throws {
        let url = logURL(for: scopeName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
