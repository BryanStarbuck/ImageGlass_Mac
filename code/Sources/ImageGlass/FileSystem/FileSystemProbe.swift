// FileSystemProbe.swift
//
// Startup probe (spec §4.4) that decides whether FSEvents is
// functional for a given scope root or whether the watcher must
// fall back to polling. The probe:
//
//   1. Stat the root; record the volume identifier (via
//      `getmntinfo` — keyed by `f_fstypename`).
//   2. If the filesystem type is in the known-bad list (smbfs to
//      non-macOS, cifs, fuse, vpn-tunneled nfs), short-circuit
//      to `.polling` immediately.
//   3. Otherwise, open a small FSEvents stream rooted at the
//      target, drop a throwaway marker file under a writable
//      sub-location, wait up to `probeTimeout` for the
//      corresponding callback. Mark `.fsevents` if it lands;
//      `.polling` otherwise.
//   4. Cache results per `volumeUUID` in
//      `~/T/_imageglass/fsevents_probe_cache.yaml` so subsequent
//      launches do not re-probe.
//
// The probe is a *one-time* per-volume cost. The cache file is
// plain-text YAML for the same Local Storage reasons noted in
// `local_storage.mdx` §2.

import Foundation
import CoreServices
import ImageGlassCore

enum FileSystemProbeResult: String, Sendable {
    case fsevents
    case polling
}

final class FileSystemProbe: @unchecked Sendable {

    static let shared = FileSystemProbe()

    /// Cached `volumeUUID → result`. Populated lazily.
    private var cache: [String: FileSystemProbeResult] = [:]
    private var loaded = false
    private let lock = NSLock()
    let cacheURL: URL

    /// Filesystem types where FSEvents is known not to propagate
    /// cross-host writes. Spec §3.2.
    private let knownBad: Set<String> = [
        "smbfs", "cifs", "fuse", "fuse4x", "macfuse"
    ]

    private let probeTimeout: TimeInterval = 2.0

    init(cacheURL: URL? = nil) {
        if let url = cacheURL {
            self.cacheURL = url
        } else {
            let dir = ("~/T/_imageglass" as NSString).expandingTildeInPath
            self.cacheURL = URL(fileURLWithPath: dir)
                .appendingPathComponent("fsevents_probe_cache.yaml")
        }
    }

    /// Synchronous probe for `root`. Returns the cached result if
    /// the volume has already been probed in this install.
    func probe(root: URL) -> FileSystemProbeResult {
        lock.lock()
        loadIfNeeded()
        let uuid = Self.volumeIdentifier(for: root) ?? root.path
        if let cached = cache[uuid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 1. fs type fast-path
        if let fsType = Self.filesystemType(for: root),
           knownBad.contains(fsType.lowercased()) {
            recordAndPersist(uuid: uuid, result: .polling)
            return .polling
        }

        // 2. Active probe — write a marker, watch for it.
        let ok = activeProbe(root: root)
        let result: FileSystemProbeResult = ok ? .fsevents : .polling
        recordAndPersist(uuid: uuid, result: result)
        return result
    }

    /// Force re-probe (`fs.probe` MCP tool, spec §12).
    func forceProbe(root: URL) -> FileSystemProbeResult {
        lock.lock()
        let uuid = Self.volumeIdentifier(for: root) ?? root.path
        cache.removeValue(forKey: uuid)
        lock.unlock()
        return probe(root: root)
    }

    // MARK: - Active probe implementation

    private func activeProbe(root: URL) -> Bool {
        let markerDir = root
        let markerName = ".imageglass-fsevent-probe-\(UUID().uuidString)"
        let markerURL = markerDir.appendingPathComponent(markerName)
        let queue = DispatchQueue(label: "io.imageglass.fsevents.probe")
        let semaphore = DispatchSemaphore(value: 0)
        var observed = false

        let bridge = FSEventsBridge(
            roots: [root],
            sinceWhen: nil,
            latencySeconds: 0.05,
            callbackQueue: queue
        ) { raw in
            for path in raw.paths {
                if path.hasSuffix(markerName) {
                    observed = true
                    semaphore.signal()
                    return
                }
            }
        }
        guard bridge.start() else {
            return false
        }
        defer { bridge.stop() }

        // Touch the marker. If the directory is read-only (e.g., a
        // mounted DMG), we can't probe actively — assume FSEvents
        // works and let the watcher discover otherwise.
        do {
            try Data().write(to: markerURL, options: .atomic)
        } catch {
            return true
        }
        defer { try? FileManager.default.removeItem(at: markerURL) }

        _ = semaphore.wait(timeout: .now() + probeTimeout)
        return observed
    }

    // MARK: - Volume metadata

    static func volumeIdentifier(for url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeIdentifierKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if let uuid = values.volumeUUIDString { return uuid }
            if let id = values.volumeIdentifier as? String { return id }
        }
        return nil
    }

    static func filesystemType(for url: URL) -> String? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return withUnsafeBytes(of: &st.f_fstypename) { raw -> String? in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    // MARK: - Persistence

    private func recordAndPersist(uuid: String, result: FileSystemProbeResult) {
        lock.lock()
        cache[uuid] = result
        writeUnsafe()
        lock.unlock()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let text = String(data: data, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let uuid = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let r = FileSystemProbeResult(rawValue: v) {
                cache[uuid] = r
            }
        }
    }

    private func writeUnsafe() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var lines: [String] = []
        lines.append("# ImageGlass_Mac FSEvents probe cache")
        lines.append("# docs/file_system_change.mdx §4.4 — one entry per volume UUID.")
        for key in cache.keys.sorted() {
            lines.append("\(key): \(cache[key]!.rawValue)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let tmp = cacheURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.moveItem(at: tmp, to: cacheURL)
        } catch {
            ErrorLog.log("FileSystemProbe write failed at \(cacheURL.path)",
                         error: error,
                         class: "FileSystemProbe")
        }
    }
}
