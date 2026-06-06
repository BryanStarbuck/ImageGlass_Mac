import Foundation
import CoreGraphics
import ImageIO

/// Multi-frame / animation frame buffer. Built once per image-open from a
/// CGImageSource and read by the canvas to advance through frames.
///
/// `FrameSource` covers both:
///   * Animated formats (GIF, APNG, WebP, animated SVG-as-raster) — frames
///     carry per-frame delays and the viewer loops with a timer.
///   * Multi-frame stills (multi-page TIFF, ICO with multiple sizes) —
///     frames have no timing; the viewer exposes Prev/Next Frame commands.
///
/// Lazy-decode contract: when constructed from a URL or Data, only frame 0
/// is decoded eagerly. Subsequent frames decode on first access to
/// `Frame.cgImage` and memoize inside a shared decoder so the animation
/// timer pays the decode at most once per frame index. A 100-frame GIF
/// changes from "decode 100 frames now" to "decode 1 now + 99 just-in-time".
public final class FrameSource: @unchecked Sendable {

    /// Backing store for lazy frame decode. One per FrameSource instance,
    /// shared by reference from every `Frame` so memoization is per-source.
    fileprivate final class Decoder: @unchecked Sendable {
        let source: CGImageSource?
        private var cached: [Int: CGImage]
        private let lock = NSLock()

        init(source: CGImageSource?, frame0: CGImage?) {
            self.source = source
            self.cached = frame0.map { [0: $0] } ?? [:]
        }

        func image(at index: Int) -> CGImage {
            lock.lock()
            if let hit = cached[index] {
                lock.unlock()
                return hit
            }
            let src = source
            lock.unlock()
            guard let src else {
                // No backing CGImageSource (eager-constructed via the
                // public init(frames:isAnimated:loopCount:) path): return
                // whatever frame 0 was seeded with, or a tiny fallback.
                return cached[0] ?? Decoder.fallbackPixel
            }
            // Decode outside the lock; kCGImageSourceShouldCacheImmediately
            // forces the bitmap to be realized now rather than on first
            // CGContext.draw call (which is where the Image.Render 14 ms
            // max outlier comes from).
            let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateImageAtIndex(src, index, opts as CFDictionary) else {
                ErrorLog.log("lazy decode failed at frame \(index)", class: "FrameSource")
                return cached[0] ?? Decoder.fallbackPixel
            }
            lock.lock()
            cached[index] = cg
            lock.unlock()
            return cg
        }

        /// Seed a specific index — used by the back-compat eager Frame
        /// constructor that hands us a pre-decoded CGImage.
        func seed(index: Int, image: CGImage) {
            lock.lock()
            cached[index] = image
            lock.unlock()
        }

        static let fallbackPixel: CGImage = {
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }()
    }

    public struct Frame: @unchecked Sendable {
        public let delay: TimeInterval
        fileprivate let index: Int
        fileprivate let decoder: Decoder

        /// Back-compat constructor: callers (tests, external producers)
        /// hand us a fully-decoded CGImage. We wrap it in a single-image
        /// decoder so `cgImage` returns the same pixels.
        public init(cgImage: CGImage, delay: TimeInterval) {
            self.delay = delay
            self.index = 0
            self.decoder = Decoder(source: nil, frame0: cgImage)
        }

        fileprivate init(delay: TimeInterval, index: Int, decoder: Decoder) {
            self.delay = delay
            self.index = index
            self.decoder = decoder
        }

        public var cgImage: CGImage { decoder.image(at: index) }
    }

    public let frames: [Frame]
    /// True when at least one frame carries a non-zero delay — i.e. an
    /// animation that should auto-advance.
    public let isAnimated: Bool
    /// Loop count from the container (0 = infinite). Honored by the canvas
    /// timer when `isAnimated`.
    public let loopCount: Int

    /// Back-compat public init. Used by tests and any caller that wants to
    /// build a FrameSource from pre-decoded Frames. The provided Frames
    /// already own their CGImages via individual single-image Decoders,
    /// so no rebinding is needed; we just store them.
    public init(frames: [Frame], isAnimated: Bool, loopCount: Int) {
        self.frames = frames
        self.isAnimated = isAnimated
        self.loopCount = loopCount
    }

    /// Lazy-decode init used by `load(url:)` / `load(data:)`. Builds a
    /// shared Decoder and Frames pointing into it.
    private init(decoder: Decoder, delays: [TimeInterval], isAnimated: Bool, loopCount: Int) {
        var fr: [Frame] = []
        fr.reserveCapacity(delays.count)
        for (i, d) in delays.enumerated() {
            fr.append(Frame(delay: d, index: i, decoder: decoder))
        }
        self.frames = fr
        self.isAnimated = isAnimated
        self.loopCount = loopCount
    }

    public var frameCount: Int { frames.count }
    public var isMultiFrame: Bool { frames.count > 1 }

    /// Load a FrameSource from disk. Returns nil for empty/unreadable files
    /// and a single-frame FrameSource for ordinary stills.
    public static func load(url: URL) -> FrameSource? {
        let _trace = PerformanceLog.shared.start(
            "Image.LoadFrames",
            extra: [("path", url.path)]
        )
        defer { _trace.finish() }
        // Cheap up-front diagnosis catches Git LFS pointers, cloud
        // placeholders, broken symlinks, and permission issues before we
        // hand the URL to ImageIO. The diagnosis is cached by
        // LoadDiagnostics so this is near-free when the canvas / thumbnail
        // cache has already diagnosed the same URL this session.
        let dx = LoadDiagnostics.diagnose(url: url)
        if dx != .ok {
            ErrorLog.log("preflight rejected [\(dx.tag)] \(url.path): \(dx.userMessage)",
                         class: "FrameSource")
            LoadDiagnostics.requestDownloadIfPossible(url: url)
            return nil
        }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            ErrorLog.log("CGImageSourceCreateWithURL returned nil for \(url.path)",
                         class: "FrameSource")
            return nil
        }
        return decode(source: src, contextLabel: url.lastPathComponent)
    }

    /// Human-readable reason a file at `path` can't be displayed, for the
    /// on-canvas error card. Returns the most actionable cause. Call only
    /// after a load has actually failed.
    public static func failureReason(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return LoadDiagnostics.diagnoseAfterDecodeFailure(url: url).userMessage
    }

    public static func load(data: Data) -> FrameSource? {
        let _trace = PerformanceLog.shared.start(
            "Image.LoadFrames",
            extra: [("path", "<data:\(data.count)b>")]
        )
        defer { _trace.finish() }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else {
            ErrorLog.log("CGImageSourceCreateWithData returned nil (data size=\(data.count))",
                         class: "FrameSource")
            return nil
        }
        return decode(source: src, contextLabel: "<data:\(data.count)b>")
    }

    private static func decode(source: CGImageSource, contextLabel: String = "<unknown>") -> FrameSource? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            ErrorLog.log("CGImageSourceGetCount returned 0 for \(contextLabel)",
                         class: "FrameSource")
            return nil
        }

        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loopCount = readLoopCount(containerProps)

        // Phase 1: read per-frame property dicts only (cheap header reads,
        // no pixel decode). This gets per-frame delay + hasDelay in
        // O(count) header reads without paying the pixel cost for frames
        // beyond #0 that the canvas may never display this session.
        var delays: [TimeInterval] = []
        delays.reserveCapacity(count)
        var hasDelay = false
        for i in 0..<count {
            let frameProps = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let d = readFrameDelay(frameProps)
            if d > 0 { hasDelay = true }
            delays.append(d)
        }

        // Phase 2: eagerly decode ONLY frame 0 with
        // kCGImageSourceShouldCacheImmediately so the bitmap is realized
        // up front. Without this, the implicit decode happens on the next
        // CGContext.draw call — that lazy materialization is the
        // Image.Render 14 ms max outlier in perf_report.csv.
        let frame0Opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let frame0 = CGImageSourceCreateImageAtIndex(source, 0, frame0Opts as CFDictionary) else {
            ErrorLog.log("CGImageSourceCreateImageAtIndex(0) returned nil for \(contextLabel)",
                         class: "FrameSource")
            return nil
        }

        let decoder = Decoder(source: source, frame0: frame0)
        return FrameSource(
            decoder: decoder,
            delays: delays,
            isAnimated: hasDelay,
            loopCount: loopCount
        )
    }

    private static func readLoopCount(_ props: [CFString: Any]?) -> Int {
        guard let props else { return 0 }
        // Containers report loop count under their type-specific dict.
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
            if let dict = props[key] as? [CFString: Any] {
                if let n = dict[kCGImagePropertyGIFLoopCount] as? Int { return n }
                if let n = dict[kCGImagePropertyAPNGLoopCount] as? Int { return n }
            }
        }
        if let dict = props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
           let n = dict[kCGImagePropertyWebPLoopCount] as? Int {
            return n
        }
        return 0
    }

    private static func readFrameDelay(_ props: [CFString: Any]?) -> TimeInterval {
        guard let props else { return 0 }
        for (containerKey, unclampedKey, clampedKey) in [
            (kCGImagePropertyGIFDictionary,  kCGImagePropertyGIFUnclampedDelayTime,  kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary,  kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ] {
            if let dict = props[containerKey] as? [CFString: Any] {
                if let d = dict[unclampedKey] as? Double, d > 0 { return d }
                if let d = dict[clampedKey] as? Double, d > 0 { return d }
            }
        }
        return 0
    }
}
