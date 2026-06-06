// FSEventsCursorStore.swift
//
// Persistence for the per-scope FSEvents replay cursor (spec §5.4).
// Plain-text YAML so the file is debuggable from Finder / the
// terminal, matching the project's Local Storage philosophy
// (docs/local_storage.mdx §2). The file lives next to the rest of
// Local Storage so it travels with backups of the application's
// state.
//
//   ~/T/_imageglass/fsevents_cursors.yaml
//
// Schema (one line per scope, last-write-wins):
//   <scope-id>: <cursor>
//
// Atomic write: the store rewrites the whole file every save, via
// the standard temp-file + rename dance.

import Foundation
import CoreServices
import ImageGlassCore

final class FSEventsCursorStore: @unchecked Sendable {

    static let shared = FSEventsCursorStore()

    /// Location override (used by tests).
    var fileURL: URL

    /// In-memory cache, loaded lazily on the first read or save.
    private var cache: [String: UInt64] = [:]
    private var loaded = false
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        if let f = fileURL {
            self.fileURL = f
        } else {
            let defaultDir = ("~/T/_imageglass" as NSString).expandingTildeInPath
            self.fileURL = URL(fileURLWithPath: defaultDir)
                .appendingPathComponent("fsevents_cursors.yaml")
        }
    }

    /// Returns the persisted cursor for `scopeID`, or `nil` if none
    /// has been written. `nil` causes `FSEventsBridge` to start with
    /// `kFSEventStreamEventIdSinceNow` (cold start, no replay).
    func load(scopeID: String) -> FSEventStreamEventId? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let value = cache[scopeID] else { return nil }
        return FSEventStreamEventId(value)
    }

    /// Persist `cursor` for `scopeID`. Idempotent — re-saving the
    /// same value is a no-op (avoids a fsync per FSEvents callback).
    func save(scopeID: String, cursor: FSEventStreamEventId) {
        let newValue = UInt64(cursor)
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        if cache[scopeID] == newValue {
            return
        }
        cache[scopeID] = newValue
        writeUnsafe()
    }

    /// Forget the cursor for a scope (e.g., scope deleted or user
    /// chose Reset → Forget History from the menu).
    func forget(scopeID: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard cache.removeValue(forKey: scopeID) != nil else { return }
        writeUnsafe()
    }

    // MARK: - I/O

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let id = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, let n = UInt64(v) else { continue }
            cache[id] = n
        }
    }

    private func writeUnsafe() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        var lines: [String] = []
        lines.append("# ImageGlass_Mac FSEvents replay cursors")
        lines.append("# docs/file_system_change.mdx §5.4 — one entry per scope.")
        lines.append("# Cursor 0 means \"start from kFSEventStreamEventIdSinceNow\".")
        for key in cache.keys.sorted() {
            lines.append("\(key): \(cache[key] ?? 0)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            ErrorLog.log("FSEventsCursorStore write failed at \(fileURL.path)",
                         error: error,
                         class: "FSEventsCursorStore")
        }
    }
}
