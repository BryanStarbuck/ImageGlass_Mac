#if canImport(AppKit)
import AppKit
#endif
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Result of loading an image — pixels plus the metadata clients need to
/// drive a viewer (size, frame count, source format).
public struct LoadedImage: @unchecked Sendable {
    /// The image as a CGImage. Always present for successful loads.
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let format: FormatInfo?
    /// Best-effort uniform type identifier reported by Image I/O.
    public let uti: String?
    /// Path the image was loaded from, if any. nil for clipboard/base64.
    public let sourceURL: URL?

    public init(
        cgImage: CGImage,
        pixelWidth: Int,
        pixelHeight: Int,
        frameCount: Int,
        format: FormatInfo?,
        uti: String?,
        sourceURL: URL?
    ) {
        self.cgImage = cgImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.format = format
        self.uti = uti
        self.sourceURL = sourceURL
    }

    #if canImport(AppKit)
    /// Convert to an NSImage sized to the pixel dimensions.
    public var nsImage: NSImage {
        NSImage(cgImage: cgImage,
                size: NSSize(width: pixelWidth, height: pixelHeight))
    }
    #endif
}

/// Errors raised by `FormatLoader`.
public enum FormatLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case unreadable(URL, underlying: Error?)
    case unknownFormat(extension: String)
    case requiresExternalDelegate(FormatInfo)
    case decodingFailed(String)
    case emptyData
    case invalidBase64

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .unreadable(let url, let err):
            return "Cannot read \(url.lastPathComponent): \(err?.localizedDescription ?? "unknown error")"
        case .unknownFormat(let ext):
            return "Unrecognized image format: .\(ext)"
        case .requiresExternalDelegate(let f):
            return "\(f.displayName) requires an external delegate which is not available. \(f.note ?? "")"
        case .decodingFailed(let m):
            return "Image decoding failed: \(m)"
        case .emptyData:
            return "Image data is empty."
        case .invalidBase64:
            return "Text does not contain valid base64-encoded image data."
        }
    }
}

/// High-level loader. Routes through `FormatRegistry` to decide whether a
/// given URL/Data is decodable by Image I/O (the in-process path) or whether
/// it needs an external delegate.
public enum FormatLoader {

    // MARK: - URL

    /// Load an image from disk. Returns `LoadedImage` with pixel buffer and
    /// metadata. Throws `FormatLoaderError` on every failure mode.
    public static func load(url: URL) throws -> LoadedImage {
        return try load(url: url, targetMaxDim: 0)
    }

    /// Load an image from disk with optional downsample-on-decode.
    ///
    /// `targetMaxDim` controls the decoded resolution:
    ///   * 0 (default) — full-resolution decode. Slowest for big images but
    ///     mandatory when the viewer is zoomed in past the thumbnail size.
    ///   * > 0 — request ImageIO produce a thumbnail with the longest edge
    ///     at most `targetMaxDim` pixels. For RAW/HEIC/big JPEGs this skips
    ///     the full pixel decode and is dramatically faster.
    ///
    /// Results are cached by (URL, mtime, size, targetMaxDim) so repeat
    /// visits during navigation hit the in-process cache instead of
    /// re-running ImageIO.
    public static func load(url: URL, targetMaxDim: Int) throws -> LoadedImage {
        let path = url.path
        // Stat the file once: it is needed for both existence and the cache
        // key. FileManager.attributesOfItem returns the stat data in a single
        // syscall round-trip; calling fileExists separately would double it.
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw FormatLoaderError.fileNotFound(url)
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attrs[.size] as? Int) ?? 0

        let format = FormatRegistry.shared.format(forURL: url)
        let action: String
        var traceExtra: [(String, String)] = []
        if let f = format {
            action = "Image.Load.\(f.id.uppercased())"
            traceExtra.append(("path", path))
        } else {
            action = "Image.LoadFormat"
            traceExtra.append(("path", path))
            traceExtra.append(("format", "unknown"))
        }
        if targetMaxDim > 0 {
            traceExtra.append(("target_max_dim", String(targetMaxDim)))
        }
        let _outerTrace = PerformanceLog.shared.start(action, extra: traceExtra)

        // Cache lookup: a hit short-circuits all of ImageIO. We thread the
        // cache_hit boolean into the outer trace so the analyzer can split
        // the histogram between true work and cache returns.
        let cacheKey = DecodedImageCache.Key(
            url: url.absoluteString,
            mtime: mtime,
            size: fileSize,
            targetMaxDim: targetMaxDim
        )
        if let cached = DecodedImageCache.shared.get(cacheKey) {
            _outerTrace.finish(extra: [("cache_hit", "true")])
            return cached
        }
        defer { _outerTrace.finish(extra: [("cache_hit", "false")]) }

        // Spec §"Special Input Methods": .b64 files contain base64-encoded
        // image bytes. Decode the text, then re-enter the loader with the
        // resulting binary blob.
        if format?.id == "base64" {
            return try Base64Loader.loadFromBase64File(url: url)
        }

        if let f = format, f.needsExternalDelegate {
            // Special case: HEIC/HEIF, PSD, AVIF — Image I/O can sometimes
            // produce a flat composite even though the spec marks them as
            // needing a delegate for advanced features. Try Image I/O and
            // fall back to the error if it can't decode.
            do {
                let loaded = try decodeWithImageIO(url: url, format: format, targetMaxDim: targetMaxDim)
                DecodedImageCache.shared.put(cacheKey, loaded)
                return loaded
            } catch {
                ErrorLog.log("Image I/O could not decode \(f.id) at \(url.path); needs external delegate",
                             error: error,
                             class: "FormatLoader")
            }
            throw FormatLoaderError.requiresExternalDelegate(f)
        }

        do {
            let loaded = try decodeWithImageIO(url: url, format: format, targetMaxDim: targetMaxDim)
            DecodedImageCache.shared.put(cacheKey, loaded)
            return loaded
        } catch {
            throw FormatLoaderError.unreadable(url, underlying: error)
        }
    }

    /// Async URL load. Runs the synchronous decode on a background-QoS task
    /// so the caller's thread (usually main) does not block on ImageIO.
    /// Cache hits return instantly without leaving the task hop.
    public static func loadAsync(url: URL, targetMaxDim: Int = 0) async throws -> LoadedImage {
        // Fast-path: cache hit avoids the executor hop. We re-stat to honor
        // the (URL, mtime, size) invariant — without it we would return a
        // stale entry for a file that changed under us.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let fileSize = (attrs[.size] as? Int) ?? 0
            let key = DecodedImageCache.Key(
                url: url.absoluteString, mtime: mtime, size: fileSize, targetMaxDim: targetMaxDim
            )
            if let cached = DecodedImageCache.shared.get(key) {
                return cached
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            DecodeExecutor.shared.submit {
                do {
                    let loaded = try Self.load(url: url, targetMaxDim: targetMaxDim)
                    cont.resume(returning: loaded)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Warm the cache for upcoming navigation. Caller hands us the next/prev
    /// URLs and a target size; we decode in the background with a small
    /// concurrency cap (3) so a long file list does not spawn unbounded work.
    /// Errors are swallowed — prefetch is a hint, not a contract.
    public static func prefetch(urls: [URL], targetMaxDim: Int = 0) {
        for url in urls {
            DecodeExecutor.shared.submit {
                _ = try? Self.load(url: url, targetMaxDim: targetMaxDim)
            }
        }
    }

    /// Drop everything from the decoded-image cache. Useful when scopes
    /// change underneath us or for tests.
    public static func clearCache() {
        DecodedImageCache.shared.clear()
    }

    // MARK: - Data

    /// Load an image from raw bytes (clipboard payload, network blob, ...).
    public static func load(data: Data, hintedExtension: String? = nil) throws -> LoadedImage {
        guard !data.isEmpty else { throw FormatLoaderError.emptyData }

        let sniffedExt = hintedExtension ?? sniffExtension(from: data)
        let format = sniffedExt.flatMap { FormatRegistry.shared.format(forExtension: $0) }

        // §5.2 outer trace. Same pattern as load(url:): bucket by resolved
        // format when known, fall through to the generic label otherwise.
        let action: String
        let traceExtra: [(String, String)]
        if let f = format {
            action = "Image.Load.\(f.id.uppercased())"
            traceExtra = [("source", "data"), ("bytes", String(data.count))]
        } else {
            action = "Image.LoadFormat"
            traceExtra = [
                ("source", "data"),
                ("bytes", String(data.count)),
                ("format", sniffedExt ?? "unknown"),
            ]
        }
        let _outerTrace = PerformanceLog.shared.start(action, extra: traceExtra)
        defer { _outerTrace.finish() }

        if let f = format, f.needsExternalDelegate {
            do {
                return try decodeWithImageIO(data: data, format: format, sourceURL: nil)
            } catch {
                ErrorLog.log("Image I/O could not decode \(f.id) data blob; needs external delegate",
                             error: error,
                             class: "FormatLoader")
            }
            throw FormatLoaderError.requiresExternalDelegate(f)
        }

        return try decodeWithImageIO(data: data, format: format, sourceURL: nil)
    }

    // MARK: - Sniffing

    /// Best-effort magic-number sniff. Returns a canonical lowercase
    /// extension (no dot) when the leading bytes match a known signature.
    public static func sniffExtension(from data: Data) -> String? {
        if data.count >= 8 {
            // PNG: 89 50 4E 47 0D 0A 1A 0A
            if data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
                return "png"
            }
        }
        if data.count >= 3 {
            // JPEG: FF D8 FF
            if data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
                return "jpg"
            }
            // GIF87a / GIF89a
            if data[0] == 0x47, data[1] == 0x49, data[2] == 0x46 {
                return "gif"
            }
        }
        if data.count >= 4 {
            // BMP: 42 4D
            if data[0] == 0x42, data[1] == 0x4D {
                return "bmp"
            }
            // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
            if (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0x00)
            || (data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A) {
                return "tiff"
            }
        }
        if data.count >= 12 {
            // JPEG 2000 container box header: 00 00 00 0C 6A 50 20 20 0D 0A 87 0A
            if data[0] == 0x00, data[1] == 0x00, data[2] == 0x00, data[3] == 0x0C,
               data[4] == 0x6A, data[5] == 0x50, data[6] == 0x20, data[7] == 0x20 {
                return "jp2"
            }
            // RIFF....WEBP
            if data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
               data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
                return "webp"
            }
            // HEIC/HEIF/AVIF: starts with ftyp box at offset 4.
            if data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 {
                let brand = String(bytes: data[8..<12], encoding: .ascii)?.lowercased() ?? ""
                if brand.hasPrefix("heic") || brand.hasPrefix("heix")
                    || brand.hasPrefix("heim") || brand.hasPrefix("heis")
                    || brand == "mif1" || brand == "msf1" {
                    return "heic"
                }
                if brand.hasPrefix("avif") || brand.hasPrefix("avis") {
                    return "avif"
                }
                if brand.hasPrefix("jxl ") {
                    return "jxl"
                }
            }
        }
        if data.count >= 4 {
            // JPEG XL codestream signature: FF 0A
            if data[0] == 0xFF, data[1] == 0x0A {
                return "jxl"
            }
            // JPEG XL container signature: 00 00 00 0C 4A 58 4C 20 0D 0A 87 0A
            if data.count >= 12,
               data[0] == 0x00, data[1] == 0x00, data[2] == 0x00, data[3] == 0x0C,
               data[4] == 0x4A, data[5] == 0x58, data[6] == 0x4C, data[7] == 0x20 {
                return "jxl"
            }
        }
        if data.count >= 5 {
            // PDF: %PDF-
            if data[0] == 0x25, data[1] == 0x50, data[2] == 0x44, data[3] == 0x46,
               data[4] == 0x2D {
                return "pdf"
            }
            // SVG (XML) — cheap text peek for "<svg" in the first 1KB.
            let head = data.prefix(1024)
            if let text = String(data: head, encoding: .utf8)?.lowercased(),
               text.contains("<svg") {
                return "svg"
            }
        }
        if data.count >= 4 {
            // PSD/PSB: 8BPS
            if data[0] == 0x38, data[1] == 0x42, data[2] == 0x50, data[3] == 0x53 {
                return "psd"
            }
            // QOI: "qoif"
            if data[0] == 0x71, data[1] == 0x6F, data[2] == 0x69, data[3] == 0x66 {
                return "qoi"
            }
            // OpenEXR: 76 2F 31 01
            if data[0] == 0x76, data[1] == 0x2F, data[2] == 0x31, data[3] == 0x01 {
                return "exr"
            }
            // BPG: "BPG\xFB"
            if data[0] == 0x42, data[1] == 0x50, data[2] == 0x47, data[3] == 0xFB {
                return "bpg"
            }
            // Windows ICO/CUR: 00 00 01 00 (icon) or 00 00 02 00 (cursor)
            if data[0] == 0x00, data[1] == 0x00, data[3] == 0x00 {
                if data[2] == 0x01 { return "ico" }
                if data[2] == 0x02 { return "cur" }
            }
        }
        if data.count >= 6 {
            // Radiance HDR: "#?RADIANCE" or "#?RGBE"
            if data[0] == 0x23, data[1] == 0x3F {
                if let text = String(data: data.prefix(11), encoding: .ascii)?.uppercased() {
                    if text.hasPrefix("#?RADIANCE") || text.hasPrefix("#?RGBE") {
                        return "hdr"
                    }
                }
            }
            // FITS: "SIMPLE"
            if data[0] == 0x53, data[1] == 0x49, data[2] == 0x4D,
               data[3] == 0x50, data[4] == 0x4C, data[5] == 0x45 {
                return "fits"
            }
        }
        return nil
    }

    // MARK: - Image I/O backend

    private static func decodeWithImageIO(
        url: URL,
        format: FormatInfo?,
        targetMaxDim: Int = 0
    ) throws -> LoadedImage {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        // §5.2 `Image.OpenSource` — the I/O + header-parse step.
        let _openTrace = PerformanceLog.shared.start(
            "Image.OpenSource",
            extra: [
                ("path", url.path),
                ("format", format?.id ?? "unknown"),
            ]
        )
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            _openTrace.finish(reason: "error")
            throw FormatLoaderError.decodingFailed("CGImageSource init failed")
        }
        _openTrace.finish()
        return try decode(source: source, format: format, sourceURL: url, targetMaxDim: targetMaxDim)
    }

    private static func decodeWithImageIO(
        data: Data,
        format: FormatInfo?,
        sourceURL: URL?,
        targetMaxDim: Int = 0
    ) throws -> LoadedImage {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        // §5.2 `Image.OpenSource` — header parse on an in-memory blob.
        let _openTrace = PerformanceLog.shared.start(
            "Image.OpenSource",
            extra: [
                ("source", "data"),
                ("bytes", String(data.count)),
                ("format", format?.id ?? "unknown"),
            ]
        )
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            _openTrace.finish(reason: "error")
            throw FormatLoaderError.decodingFailed("CGImageSource init failed")
        }
        _openTrace.finish()
        return try decode(source: source, format: format, sourceURL: sourceURL, targetMaxDim: targetMaxDim)
    }

    private static func decode(
        source: CGImageSource,
        format: FormatInfo?,
        sourceURL: URL?,
        targetMaxDim: Int = 0
    ) throws -> LoadedImage {
        // §5.2 `Image.Decode` — the pixel decode itself. For RAW + HEIC this
        // is the dominant cost; we want it instrumented separately so the
        // analyzer can subtract OpenSource from Load and see how much of the
        // remainder is real decode vs. other overhead.
        let _decodeTrace = PerformanceLog.shared.start(
            "Image.Decode",
            extra: [
                ("format", format?.id ?? "unknown"),
                ("path", sourceURL?.path ?? ""),
                ("target_max_dim", String(targetMaxDim)),
            ]
        )
        let frameCount = max(1, CGImageSourceGetCount(source))
        let cg: CGImage?
        if targetMaxDim > 0 {
            // Downsample-on-decode: ImageIO produces an image whose longest
            // edge is at most `targetMaxDim` pixels, going through the codec
            // path that skips full-resolution pixel materialization. For a
            // 50 MP RAW rendered to a 1500-pixel canvas this is ~10x faster
            // than full decode then resize.
            //
            // `FromImageAlways` forces creation even when no embedded
            // thumbnail exists (the default would silently return nil for
            // PNG/JPEG without prebaked thumbs). `WithTransform` applies the
            // EXIF orientation so the cached image is canvas-ready.
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: targetMaxDim,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
        } else {
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cg = cg else {
            _decodeTrace.finish(reason: "error")
            throw FormatLoaderError.decodingFailed("CGImageSourceCreateImageAtIndex returned nil")
        }
        let uti = CGImageSourceGetType(source) as String?
        _decodeTrace.finish(extra: [
            ("decoded_pixels", String(cg.width * cg.height)),
            ("frames", String(frameCount)),
        ])
        return LoadedImage(
            cgImage: cg,
            pixelWidth: cg.width,
            pixelHeight: cg.height,
            frameCount: frameCount,
            format: format,
            uti: uti,
            sourceURL: sourceURL
        )
    }
}

// MARK: - Decoded-image cache

/// Bounded LRU cache for decoded `LoadedImage` values. Thread-safe via an
/// internal lock; eviction is byte-accurate (LRU until below cap).
///
/// Why not NSCache: NSCache has no byte-accurate cap, no deterministic
/// eviction order, and no way to introspect what is currently resident.
/// All three matter for perf testing and the 256 MB budget.
final class DecodedImageCache: @unchecked Sendable {

    struct Key: Hashable {
        let url: String
        let mtime: TimeInterval
        let size: Int
        let targetMaxDim: Int
    }

    static let shared = DecodedImageCache(byteCap: 256 * 1024 * 1024)

    private let byteCap: Int
    private let lock = NSLock()
    private final class Node {
        let key: Key
        let value: LoadedImage
        let bytes: Int
        var prev: Node?
        var next: Node?
        init(key: Key, value: LoadedImage, bytes: Int) {
            self.key = key
            self.value = value
            self.bytes = bytes
        }
    }
    private var map: [Key: Node] = [:]
    private var head: Node?  // LRU end — evict from here
    private var tail: Node?  // MRU end — insert here
    private var resident: Int = 0

    init(byteCap: Int) {
        self.byteCap = byteCap
    }

    func get(_ key: Key) -> LoadedImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    func put(_ key: Key, _ value: LoadedImage) {
        // Estimate 4 bytes per pixel — close enough for RGBA8 / BGRA8 which
        // is what ImageIO returns by default on macOS. Float HDR would be
        // 16 bytes/pixel; we are off by 4x in that case but the cap is a
        // hint, not a hard contract.
        let bytes = max(1, value.pixelWidth * value.pixelHeight * 4)
        lock.lock()
        defer { lock.unlock() }
        if let existing = map[key] {
            resident += bytes - existing.bytes
            unlink(existing)
            map.removeValue(forKey: key)
        }
        let node = Node(key: key, value: value, bytes: bytes)
        map[key] = node
        appendToTail(node)
        resident += bytes
        evictUntilUnderCap()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        head = nil
        tail = nil
        resident = 0
    }

    /// Test/diagnostic hook. Bytes currently resident in the cache.
    var residentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return resident
    }

    // MARK: - LRU internals (all called under `lock`)

    private func moveToTail(_ node: Node) {
        guard tail !== node else { return }
        unlink(node)
        appendToTail(node)
    }

    private func appendToTail(_ node: Node) {
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
        if head == nil { head = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func evictUntilUnderCap() {
        while resident > byteCap, let victim = head {
            resident -= victim.bytes
            map.removeValue(forKey: victim.key)
            unlink(victim)
        }
    }
}

// MARK: - Decode executor

/// Bounded concurrency pool for off-thread image decode. The single visible
/// image stays serial (one call, one task); prefetch piles up here behind
/// a 3-wide semaphore so a long file list never spawns unbounded work.
///
/// Why not GCD .concurrent alone: it has no cap and prefetching a
/// 5,000-file directory would saturate the system. Why not 19 threads:
/// image decode is memory-bandwidth bound, and oversubscribing actively
/// hurts.
final class DecodeExecutor: @unchecked Sendable {
    static let shared = DecodeExecutor(maxConcurrent: 3)

    private let semaphore: DispatchSemaphore
    private let queue: DispatchQueue

    init(maxConcurrent: Int) {
        self.semaphore = DispatchSemaphore(value: maxConcurrent)
        self.queue = DispatchQueue(
            label: "imageglass.decode",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    func submit(_ work: @escaping @Sendable () -> Void) {
        queue.async { [semaphore] in
            semaphore.wait()
            defer { semaphore.signal() }
            work()
        }
    }
}
