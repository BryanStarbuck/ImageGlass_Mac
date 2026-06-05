import Foundation

/// Process-wide async file appender shared by `MCPAuditLogger`,
/// `PerformanceLog`, and `ErrorLog`.
///
/// Why a shared sink?
///
/// The user-visible requirement is "writes from the main thread must
/// not block on disk I/O." Every logger funnels its formatted bytes
/// here; the sink dispatches the actual `write(2)` onto a dedicated
/// serial utility-QoS queue. The calling thread returns as soon as
/// the closure has been queued (a few hundred nanoseconds), and the
/// kernel call lands later on the background worker.
///
/// The sink also owns log rotation. Each writer caps its file at
/// `maxBytes` (10 MB by default). When a write would push past the
/// cap the current file is renamed to `<name>.1` (overwriting any
/// existing rotated copy) and a fresh file is opened for the next
/// write. Only one rotated generation is kept — the user's
/// requirement is "self-rotating at 10 MB," not a multi-generation
/// archive.
///
/// The append-mode `FileHandle` is cached across writes so we do
/// not pay the open/seek/close syscalls per line. On any write
/// error the handle is dropped and the next call re-opens.
public final class LogSink: @unchecked Sendable {

    /// Default per-file cap. The user's spec is "all log files
    /// can get to 10 MB but not longer."
    public static let defaultMaxBytes: Int = 10 * 1024 * 1024

    private let queue: DispatchQueue
    private let resolveURL: () -> URL
    private let maxBytes: Int
    private let synchronous: Bool

    /// Cached append-mode handle. Reset to `nil` when the resolved
    /// URL changes or a write fails. Accessed only on `queue`.
    private var handle: FileHandle?
    private var currentURL: URL?

    /// Bytes already in the current file (seeded by `stat` on open,
    /// incremented on every successful write). Used to decide when to
    /// rotate without re-stating on every write.
    private var currentBytes: Int = 0

    /// - Parameters:
    ///   - label: GCD queue label, used in Instruments traces.
    ///   - url: Closure that resolves the target file on every write.
    ///          Allows callers (and tests) to swap the destination at
    ///          runtime — when the resolved URL changes the sink
    ///          re-opens.
    ///   - maxBytes: Rotate when the file size would exceed this many
    ///               bytes. Default 10 MB.
    ///   - synchronous: When true, `write(_:)` blocks the caller until
    ///                  the byte hit disk. Reserved for tests that read
    ///                  the file immediately after writing; production
    ///                  callers always use the default (false).
    public init(
        label: String,
        url: @escaping () -> URL,
        maxBytes: Int = LogSink.defaultMaxBytes,
        synchronous: Bool = false
    ) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.resolveURL = url
        self.maxBytes = maxBytes
        self.synchronous = synchronous
    }

    /// Queue `data` for append. Returns immediately when the sink is
    /// async; blocks until the write completes when the sink was
    /// constructed with `synchronous: true`.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if synchronous {
            queue.sync { self.performWrite(data) }
        } else {
            queue.async { [weak self] in
                self?.performWrite(data)
            }
        }
    }

    /// Block until every previously-queued write has flushed. Useful
    /// before shutdown and in tests that need deterministic file
    /// contents.
    public func flush() {
        queue.sync { }
    }

    /// Close the cached handle. The next write re-opens. Tests call
    /// this when they rebind `HOME` between cases.
    public func reset() {
        queue.sync {
            try? handle?.close()
            handle = nil
            currentURL = nil
            currentBytes = 0
        }
    }

    // MARK: - Internals (queue-only)

    private func performWrite(_ data: Data) {
        let target = resolveURL()
        guard let h = ensureHandle(for: target) else { return }
        if currentBytes + data.count > maxBytes {
            rotate(target)
            guard let _ = ensureHandle(for: target) else { return }
        }
        let h2 = handle ?? h
        do {
            try h2.write(contentsOf: data)
            currentBytes += data.count
        } catch {
            FileHandle.standardError.write(
                Data("LogSink: write failed for \(target.path): \(error)\n".utf8)
            )
            try? handle?.close()
            handle = nil
            currentURL = nil
            currentBytes = 0
        }
    }

    private func ensureHandle(for url: URL) -> FileHandle? {
        if let h = handle, currentURL == url { return h }
        if handle != nil {
            try? handle?.close()
            handle = nil
            currentURL = nil
            currentBytes = 0
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("LogSink: cannot create parent for \(url.path): \(error)\n".utf8)
            )
            return nil
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
            currentURL = url
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                currentBytes = size
            } else {
                currentBytes = 0
            }
            return h
        } catch {
            FileHandle.standardError.write(
                Data("LogSink: cannot open \(url.path): \(error)\n".utf8)
            )
            return nil
        }
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        currentURL = nil
        currentBytes = 0
        let rotated = URL(fileURLWithPath: url.path + ".1")
        let fm = FileManager.default
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }
}
