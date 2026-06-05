import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

/// In-memory + on-disk thumbnail cache backed by Image I/O.
/// Spec §4.2 (Thumbnails / Disk cache) and §7.4 (ThumbnailCache actor).
///
/// Cap design:
/// * `NSCache` enforces the in-memory cap (256 entries per spec §6.6).
/// * The on-disk HEIC cache is groomed lazily — current implementation is
///   bounded by a soft byte cap and a recency-based eviction sweep.
///
/// External libraries: none. Pure ImageIO + NSCache, per the prompt's
/// "no external libs" constraint.
public actor ThumbnailCache {

    public static let shared = ThumbnailCache()

    private let memory: NSCache<NSString, CGImageBox>
    private let diskDir: URL
    private let byteCap: Int
    private var pendingDiskBytes: Int = 0
    private var lastGroom: Date = .distantPast
    private let groomInterval: TimeInterval = 600 // 10 min — spec §6.3

    public init(
        diskDir: URL? = nil,
        memoryEntryCap: Int = 256,
        byteCap: Int = 1024 * 1024 * 1024 // 1 GB — spec §6.3
    ) {
        let mem = NSCache<NSString, CGImageBox>()
        mem.countLimit = memoryEntryCap
        self.memory = mem
        self.byteCap = byteCap

        let dir: URL
        if let supplied = diskDir {
            dir = supplied
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            dir = base
                .appendingPathComponent("ImageGlass_Mac", isDirectory: true)
                .appendingPathComponent("thumbnails", isDirectory: true)
        }
        self.diskDir = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            ErrorLog.log("failed to create thumbnail cache directory at \(dir.path)",
                         error: error,
                         class: "ThumbnailCache")
        }
    }

    /// Fetches a thumbnail for `url` capped to `maxSide` pixels. Reads from
    /// memory cache first, then disk, then generates via ImageIO.
    /// Returns `nil` if the file is not a decodable image.
    public func thumbnail(for url: URL, maxSide: Int) -> CGImage? {
        let _trace = PerformanceLog.shared.start("Thumbnail.Generate", extra: [("path", url.path)])
        defer { _trace.finish() }
        let key = Self.cacheKey(url: url, maxSide: maxSide)

        if let box = memory.object(forKey: key as NSString) {
            return box.image
        }

        let diskPath = diskDir.appendingPathComponent("\(maxSide)").appendingPathComponent("\(key).heic")
        if FileManager.default.fileExists(atPath: diskPath.path),
           let cg = Self.readDisk(at: diskPath) {
            memory.setObject(CGImageBox(cg), forKey: key as NSString)
            return cg
        }

        guard let cg = Self.generateImageIO(url: url, maxSide: maxSide) else {
            return nil
        }
        memory.setObject(CGImageBox(cg), forKey: key as NSString)
        // Best-effort write to disk; not fatal if it fails.
        do {
            try FileManager.default.createDirectory(
                at: diskPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            ErrorLog.log("failed to create thumbnail subdir \(diskPath.deletingLastPathComponent().path)",
                         error: error,
                         class: "ThumbnailCache")
        }
        Self.writeDiskHEIC(cg, to: diskPath, byteAccumulator: &pendingDiskBytes)

        // Lazy groom — every 10 minutes or when we've added > 50 MB since last.
        let now = Date()
        if pendingDiskBytes > 50 * 1024 * 1024 ||
            now.timeIntervalSince(lastGroom) > groomInterval {
            lastGroom = now
            pendingDiskBytes = 0
            Task.detached(priority: .background) { [diskDir, byteCap] in
                Self.groomDisk(dir: diskDir, byteCap: byteCap)
            }
        }
        return cg
    }

    /// Drop all in-memory entries. Disk is untouched.
    public func purgeMemory() {
        memory.removeAllObjects()
    }

    /// Diagnostic — number of entries in memory.
    public func memoryEntryCountEstimate() -> Int { -1 } // NSCache offers no count API; placeholder.

    // MARK: - Static helpers (pure)

    /// Stable cache key. Spec §4.2: sha256(path + mtime).
    public static func cacheKey(url: URL, maxSide: Int) -> String {
        let path = url.standardizedFileURL.path
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)
        let mtimeStr = String(Int(mtime.timeIntervalSince1970))
        let raw = "\(path)|\(mtimeStr)|\(maxSide)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generate a CGImage thumbnail via ImageIO. Spec §4.2.
    public static func generateImageIO(url: URL, maxSide: Int) -> CGImage? {
        // Skip files we know aren't real image bytes (Git LFS pointers,
        // cloud-storage placeholders, broken symlinks, …). Feeding them
        // to ImageIO produces a useless empty thumbnail that then gets
        // baked into the on-disk cache and re-served until the user
        // notices and purges. The diagnoser logs a tagged line so the
        // file panel's silent fall-back to the system icon is traceable.
        let dx = LoadDiagnostics.diagnose(url: url)
        if dx != .ok {
            ErrorLog.log("skip thumbnail [\(dx.tag)] \(url.path)",
                         class: "ThumbnailCache")
            LoadDiagnostics.requestDownloadIfPossible(url: url)
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceThumbnailMaxPixelSize:          maxSide,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Read a HEIC-encoded thumbnail from disk; returns nil on any I/O error.
    static func readDisk(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Encode a CGImage as HEIC and write atomically to `url`.
    /// Updates `byteAccumulator` with the file size on success.
    static func writeDiskHEIC(_ image: CGImage, to url: URL, byteAccumulator: inout Int) {
        let utType: CFString = "public.heic" as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
            // Fallback to PNG when HEIC isn't available (e.g. running tests
            // on a stripped-down macOS image).
            let png: CFString = "public.png" as CFString
            guard let pngDest = CGImageDestinationCreateWithURL(url as CFURL, png, 1, nil) else { return }
            CGImageDestinationAddImage(pngDest, image, nil)
            if CGImageDestinationFinalize(pngDest) {
                if let size = try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int { byteAccumulator += size }
            }
            return
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.6]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int { byteAccumulator += size }
        }
    }

    /// LRU groom — walks `dir`, evicts oldest-accessed until under `byteCap`.
    /// Spec §6.3.
    static func groomDisk(dir: URL, byteCap: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var files: [(URL, Int, Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            let size = vals?.fileSize ?? 0
            let atime = vals?.contentAccessDate ?? Date.distantPast
            files.append((url, size, atime))
            total += size
        }
        if total <= byteCap { return }
        files.sort { $0.2 < $1.2 } // oldest first
        var freed = 0
        for (url, size, _) in files {
            if total - freed <= byteCap { break }
            do {
                try fm.removeItem(at: url)
            } catch {
                ErrorLog.log("failed to evict thumbnail \(url.path)",
                             error: error,
                             class: "ThumbnailCache")
            }
            freed += size
        }
    }
}

/// Box so `CGImage` (CoreFoundation type) can live in NSCache.
final class CGImageBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
