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
public final class FrameSource: @unchecked Sendable {

    public struct Frame: @unchecked Sendable {
        public let cgImage: CGImage
        /// Delay in seconds (0 for multi-frame stills).
        public let delay: TimeInterval
        public init(cgImage: CGImage, delay: TimeInterval) {
            self.cgImage = cgImage
            self.delay = delay
        }
    }

    public let frames: [Frame]
    /// True when at least one frame carries a non-zero delay — i.e. an
    /// animation that should auto-advance.
    public let isAnimated: Bool
    /// Loop count from the container (0 = infinite). Honored by the canvas
    /// timer when `isAnimated`.
    public let loopCount: Int

    public init(frames: [Frame], isAnimated: Bool, loopCount: Int) {
        self.frames = frames
        self.isAnimated = isAnimated
        self.loopCount = loopCount
    }

    public var frameCount: Int { frames.count }
    public var isMultiFrame: Bool { frames.count > 1 }

    /// Load a FrameSource from disk. Returns nil for empty/unreadable files
    /// and a single-frame FrameSource for ordinary stills.
    public static func load(url: URL) -> FrameSource? {
        if isGitLFSPointer(at: url) {
            ErrorLog.log("Git LFS pointer file (not real image bytes); run 'git lfs pull' to materialize: \(url.path)",
                         class: "FrameSource")
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

    /// True when `url` points at a Git LFS pointer file rather than a real
    /// image: a tiny text file whose first line is exactly
    /// `version https://git-lfs.github.com/spec/v1`. We peek at the first
    /// few bytes because the alternative — letting ImageIO fail and logging
    /// `CGImageSourceGetCount returned 0` — gives the user no actionable
    /// signal about why the image can't load.
    private static func isGitLFSPointer(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 64)) ?? Data()
        guard let head = String(data: prefix, encoding: .utf8) else { return false }
        return head.hasPrefix("version https://git-lfs.github.com/spec/")
    }

    /// Human-readable reason a file at `path` can't be displayed, for the
    /// on-canvas error card. Returns the most actionable cause. Call only
    /// after a load has actually failed.
    public static func failureReason(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if isGitLFSPointer(at: url) {
            return "This is a Git LFS placeholder, not the image itself. Run `git lfs pull` in the source repo to download the real files."
        }
        if !FileManager.default.isReadableFile(atPath: path) {
            return "Can't read this file (permission or sandbox). Re-add the folder via Directories ▸ Add Directory… so macOS grants access."
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if let size, size == 0 {
            return "This file is empty (0 bytes)."
        }
        return "Couldn't display this image — unsupported or corrupt encoding (e.g. CMYK / progressive JPEG, or a non-image file with an image extension)."
    }

    public static func load(data: Data) -> FrameSource? {
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

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        var hasDelay = false

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                ErrorLog.log("CGImageSourceCreateImageAtIndex(\(i)) returned nil for \(contextLabel)",
                             class: "FrameSource")
                continue
            }
            let frameProps = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let delay = readFrameDelay(frameProps)
            if delay > 0 { hasDelay = true }
            frames.append(Frame(cgImage: cg, delay: delay))
        }
        guard !frames.isEmpty else {
            ErrorLog.log("decoded 0 frames from \(contextLabel) (declared count=\(count))",
                         class: "FrameSource")
            return nil
        }
        return FrameSource(frames: frames, isAnimated: hasDelay, loopCount: loopCount)
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
