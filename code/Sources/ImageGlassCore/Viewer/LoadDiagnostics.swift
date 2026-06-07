import Foundation

/// Why a file couldn't be opened, in user-friendly form.
///
/// Every viewer surface (image canvas, SVG canvas, video canvas, thumbnail
/// generator) funnels its failures through `LoadDiagnostics.diagnose` so
/// the on-screen error card always names a single actionable cause —
/// instead of bottoming out at a generic "the file is not playable" or
/// "ImageIO returned nil" line that doesn't help the user fix anything.
///
/// The diagnoses cover the macOS file-system quirks that bite image
/// viewers most often:
///
///   * **Git LFS pointer** — file is a 130-byte text stub waiting for
///     `git lfs pull`. (See [[git-lfs-pointer]].)
///   * **iCloud / cloud-storage placeholder** — file exists in the
///     filesystem but its bytes haven't been downloaded yet. macOS shows
///     these in Finder with a download-arrow badge. Affects iCloud Drive,
///     Dropbox, Google Drive, OneDrive, Box — anything that uses the
///     `NSFileProvider` extension API.
///   * **Broken symlink** — the link resolves to a path that doesn't exist
///     (deleted target, ejected external drive, renamed file).
///   * **Permission / sandbox denial** — the file is on disk but our
///     process can't read it (`com.apple.security.files.user-selected.*`
///     bookmark expired, parent dir not granted, TCC denied).
///   * **Empty file** — zero bytes; whatever wrote it crashed mid-stream.
///   * **Stale network mount** — file is on an unreachable SMB / AFP /
///     NFS volume and the syscall came back with ETIMEDOUT or similar.
///   * **Generic decoder failure** — the file is local, readable, non-zero,
///     and not a placeholder, but ImageIO still refuses it (corrupt,
///     unsupported variant, etc.).
public enum LoadDiagnosis: Sendable, Equatable {
    case ok
    case gitLFSPointer(repoRoot: String?)
    case cloudPlaceholder(providerHint: String?)
    case brokenSymlink(target: String?)
    case missing
    case permissionDenied
    case emptyFile
    case staleNetworkMount
    case generic(String)
}

public extension LoadDiagnosis {
    /// Human-readable, action-oriented sentence shown in the viewer's
    /// error card. Always written so the user knows what to do next.
    var userMessage: String {
        switch self {
        case .ok:
            return ""
        case .gitLFSPointer(let repo):
            if let repo {
                return "This is a Git LFS placeholder, not the image itself. " +
                       "Run `git lfs pull` in \(repo) to download the real file."
            }
            return "This is a Git LFS placeholder, not the image itself. " +
                   "Run `git lfs pull` in the source repo to download the real file."
        case .cloudPlaceholder(let hint):
            let where_ = hint.map { " (\($0))" } ?? ""
            return "This file lives in a cloud folder\(where_) and hasn't been downloaded to this Mac yet. " +
                   "Open it in Finder, or right-click ▸ Download Now, then try again."
        case .brokenSymlink(let target):
            if let target {
                return "This is a symbolic link, but its target is missing: \(target)"
            }
            return "This is a symbolic link, but its target no longer exists."
        case .missing:
            return "The file is no longer at this path. It may have been moved, renamed, or deleted."
        case .permissionDenied:
            return "macOS won't let this app read the file. Re-add the folder via Directories ▸ Add Directory… so the system grants access."
        case .emptyFile:
            return "This file is empty (0 bytes)."
        case .staleNetworkMount:
            return "The network volume holding this file is unreachable. Reconnect, then try again."
        case .generic(let msg):
            return msg
        }
    }

    /// Short telemetry tag for log lines.
    var tag: String {
        switch self {
        case .ok: return "ok"
        case .gitLFSPointer: return "git-lfs"
        case .cloudPlaceholder: return "cloud-placeholder"
        case .brokenSymlink: return "broken-symlink"
        case .missing: return "missing"
        case .permissionDenied: return "permission-denied"
        case .emptyFile: return "empty"
        case .staleNetworkMount: return "stale-network"
        case .generic: return "generic"
        }
    }
}

public enum LoadDiagnostics {

    // MARK: - Diagnosis result cache
    //
    // The same URL is diagnosed repeatedly within a session: FrameSource
    // preflight, ThumbnailCache thumbnailer, SVGPlaybackController, and
    // VideoPlaybackController all funnel through `diagnose(url:)`. The
    // verdict is a pure function of (path, mtime, size), so we memoize.
    // Cloud-placeholder verdicts are deliberately NOT cached because they
    // can flip during the session as background downloads complete.

    private struct CacheKey: Hashable {
        let path: String
        let mtime: Int64
        let size: Int64
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: LoadDiagnosis] = [:]
    nonisolated(unsafe) private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 1024

    private static func cacheGet(_ key: CacheKey) -> LoadDiagnosis? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func cachePut(_ key: CacheKey, _ verdict: LoadDiagnosis) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit {
                let drop = cacheOrder.removeFirst()
                cache.removeValue(forKey: drop)
            }
        }
        cache[key] = verdict
    }

    /// Invalidate any cached diagnosis for `url`. Call when the file was
    /// replaced in a way that mtime parity may not catch.
    public static func invalidateCache(for url: URL) {
        let path = url.standardizedFileURL.path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let keys = cache.keys.filter { $0.path == path }
        for k in keys { cache.removeValue(forKey: k) }
        cacheOrder.removeAll { $0.path == path }
    }

    /// Drop the entire diagnosis cache. Test/diagnostic hook; production
    /// code should prefer `invalidateCache(for:)` for the single-URL case.
    public static func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Test/diagnostic accessor: number of entries currently in the cache.
    public static var cacheCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    /// Inspect the file at `url` and return the most-specific diagnosis.
    /// Order matters: cheaper / more specific checks come first so a Git
    /// LFS pointer in an iCloud folder reports "git-lfs", not "cloud".
    public static func diagnose(url: URL) -> LoadDiagnosis {
        let _trace = PerformanceLog.shared.start(
            "Image.LoadDiagnostics",
            extra: [("path", url.path)]
        )
        defer { _trace.finish() }
        let fm = FileManager.default
        let path = url.path

        // Single batched stat: pull isSymbolicLink + isDirectory + isRegular
        // + fileSize + isReadable + mtime in one resourceValues call.
        // On macOS this collapses what used to be 3-4 separate stat(2)
        // syscalls into one getattrlist(2).
        let rvKeys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isReadableKey,
            .contentModificationDateKey,
        ]
        let rv = try? url.resourceValues(forKeys: rvKeys)
        let isSymlink = rv?.isSymbolicLink ?? false
        let isDir = rv?.isDirectory ?? false
        let fileSize = Int64(rv?.fileSize ?? 0)
        let isReadable = rv?.isReadable ?? true
        let mtime: Int64 = rv?.contentModificationDate
            .map { Int64($0.timeIntervalSince1970) } ?? 0

        // 1. Symlink? Check the link itself before the target, so we can
        // distinguish a broken link from a plain missing file.
        if isSymlink {
            let target = try? fm.destinationOfSymbolicLink(atPath: path)
            // Resolve relative targets against the symlink's directory.
            let resolved: String? = target.map { t in
                if (t as NSString).isAbsolutePath { return t }
                return (url.deletingLastPathComponent().path as NSString)
                    .appendingPathComponent(t)
            }
            if let r = resolved, !fm.fileExists(atPath: r) {
                return .brokenSymlink(target: target)
            }
        }

        // 2. File presence + kind. resourceValues returning nil means the
        // URL does not resolve. Confirm with fileExists for the missing /
        // directory disambiguation.
        if rv == nil {
            var dirFlag: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &dirFlag) else {
                return .missing
            }
            if dirFlag.boolValue {
                return .generic("This path is a directory, not an image.")
            }
        } else if isDir {
            return .generic("This path is a directory, not an image.")
        }

        // Cache lookup keyed on (path, mtime, size). Checked AFTER the
        // structural checks (missing / directory / broken symlink) since
        // those have no business being cached. When the batched stat
        // failed (`rv == nil`) we still produce a verdict but skip the
        // cache write below to avoid poisoning the table with a (path, 0, 0)
        // entry that would shadow the real key once stat starts working.
        let canCache = (rv != nil)
        let cacheKey = CacheKey(path: path, mtime: mtime, size: fileSize)
        if canCache, let cached = cacheGet(cacheKey) {
            return cached
        }

        // 3. Cloud-storage placeholder — iCloud Drive uses the ubiquitous
        // download-status keys, third-party providers (Dropbox, Google
        // Drive, OneDrive) appear as `NSURLFileResourceTypeRegular` with
        // an `NSURLFileResourceIdentifierKey` but **zero allocated bytes**
        // for the data fork until the user opens the file. The most
        // reliable cross-provider signal is the ubiquitous downloading
        // status, plus a fallback "size > 0 but reading 1 byte fails with
        // NSFileReadNoSuchFileError (cocoa 257)" probe further down.
        if let ubiquity = cloudDownloadStatus(for: url) {
            // `.current` and `.downloaded` both mean "bytes are here";
            // `.notDownloaded` means a placeholder.
            if ubiquity != .current && ubiquity != .downloaded {
                // Deliberately NOT cached — placeholder state is expected
                // to flip mid-session as background downloads complete.
                return .cloudPlaceholder(providerHint: providerHint(for: url))
            }
        }

        // 4. Empty file. Already known from fileSizeKey above.
        if fileSize == 0 {
            if canCache { cachePut(cacheKey, .emptyFile) }
            return .emptyFile
        }

        // 5. Permission. The isReadableKey reflects the sandbox + POSIX
        // permissions seen by *this process*, which is the permission that
        // actually matters.
        if !isReadable {
            if canCache { cachePut(cacheKey, .permissionDenied) }
            return .permissionDenied
        }

        // 6. Git LFS pointer. Short-circuit by size — LFS pointers are
        // <200 bytes by spec, so anything over 1 KB cannot be one.
        // Skipping the FileHandle open here is where the LFSDetect cost
        // goes from "every file" to "every <=1KB file".
        if fileSize <= 1024 {
            if GitLFSPointer.isPointer(at: url) {
                let repo = GitLFSPointer.repoRoot(for: url).map { AppPaths.contractTilde($0.path) }
                let verdict: LoadDiagnosis = .gitLFSPointer(repoRoot: repo)
                if canCache { cachePut(cacheKey, verdict) }
                return verdict
            }
        }

        if canCache { cachePut(cacheKey, .ok) }
        return .ok
    }

    /// Second-pass diagnosis used by canvases that already attempted to
    /// decode the file and got nothing back. Adds the "looks fine on disk
    /// but the decoder hated it" verdict that `diagnose` is too cautious
    /// to return on its own. Always preserves the more-specific causes
    /// (LFS, cloud, broken symlink, …) from the first pass.
    public static func diagnoseAfterDecodeFailure(url: URL,
                                                  decoderHint: String? = nil) -> LoadDiagnosis {
        let first = diagnose(url: url)
        if first != .ok { return first }
        // The file passes the cheap checks but no decoder produced an
        // image. If it lives in a cloud folder, the most likely cause is
        // that the bytes aren't all here yet (third-party file providers
        // can report a full size for a placeholder).
        if let hint = providerHint(for: url) {
            return .cloudPlaceholder(providerHint: hint)
        }
        return .generic(decoderHint
            ?? "Couldn't display this file — unsupported or corrupt encoding (e.g. CMYK / progressive JPEG, an unrecognized variant, or a non-image file with an image extension).")
    }

    /// Best-effort opportunistic kick — ask the cloud provider to start
    /// pulling the file down. No-op for non-cloud paths and for providers
    /// other than iCloud Drive. Safe to call on every load failure; the
    /// next attempt may succeed once the download finishes.
    public static func requestDownloadIfPossible(url: URL) {
        let fm = FileManager.default
        if let ubiquity = cloudDownloadStatus(for: url),
           ubiquity != .current && ubiquity != .downloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    // MARK: - Cloud detection helpers

    /// Returns the iCloud download status, or nil when the URL is not
    /// inside an ubiquitous (iCloud Drive) container. Third-party cloud
    /// providers (Dropbox, Google Drive, …) won't report a status here —
    /// they use NSFileProvider extensions instead, and we detect them via
    /// `providerHint(for:)` plus the byte-probe below.
    private static func cloudDownloadStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus? {
        guard let vals = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else { return nil }
        guard vals.isUbiquitousItem == true else { return nil }
        return vals.ubiquitousItemDownloadingStatus
    }

    /// Name of the cloud provider whose folder contains `url`, if we can
    /// recognize it from the path. Used to make error messages more
    /// specific ("iCloud Drive" vs. "Dropbox").
    public static func providerHint(for url: URL) -> String? {
        let p = url.path
        let home = NSHomeDirectory()
        let containers = [
            ("\(home)/Library/Mobile Documents/com~apple~CloudDocs",
             "iCloud Drive"),
            ("\(home)/Library/CloudStorage/iCloud~", "iCloud Drive"),
            ("\(home)/Library/CloudStorage/Dropbox", "Dropbox"),
            ("\(home)/Dropbox", "Dropbox"),
            ("\(home)/Library/CloudStorage/GoogleDrive-", "Google Drive"),
            ("\(home)/Google Drive", "Google Drive"),
            ("\(home)/Library/CloudStorage/OneDrive-", "OneDrive"),
            ("\(home)/OneDrive", "OneDrive"),
            ("\(home)/Library/CloudStorage/Box-", "Box"),
            ("\(home)/Box", "Box"),
        ]
        for (prefix, name) in containers {
            if p.hasPrefix(prefix) { return name }
        }
        // Fallback: anything under CloudStorage we don't have a name for.
        if p.hasPrefix("\(home)/Library/CloudStorage/") {
            return "cloud folder"
        }
        return nil
    }
}
