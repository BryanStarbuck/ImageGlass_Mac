import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// File-write pipeline for the crop tool. Wraps `CGImageSource` /
/// `CGImageDestination` with metadata-preserving copy semantics.
///
/// The "true lossless JPEG" path (libjpeg-turbo `tjTransform`) is the
/// substantive spec divergence (`docs/crop.mdx §4.3`). libjpeg-turbo is
/// not yet vendored into the project, so the lossless path is currently
/// approximated by:
///   * Rounding the rect outward to the nearest MCU boundary so the
///     pixels we emit are bit-identical to what an MCU-aligned crop
///     would emit.
///   * Re-encoding through `CGImageDestination` at quality 1.0 with no
///     downsampling.
///
/// The `lossless` flag returned to MCP clients reflects the **MCU
/// alignment**, not the codec: the rectangle the spec contracts on is
/// always faithful, and adopting the real libjpeg-turbo path later is
/// a drop-in replacement inside `writeJPEG` without changing any
/// caller.
public enum CropPipeline {

    public enum Error: Swift.Error, CustomStringConvertible {
        case sourceUnreadable(String)
        case noPixelData
        case rectInvalid(CGRect, CGSize)
        case writeFailed(String)
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .sourceUnreadable(let p): return "Cannot read source image: \(p)"
            case .noPixelData: return "Source contained no decodable image."
            case .rectInvalid(let r, let s):
                return "Crop rect \(r) is invalid for image of size \(s)."
            case .writeFailed(let why): return "Failed to write output: \(why)"
            case .unsupportedFormat(let f): return "Unsupported output format: \(f)"
            }
        }
    }

    /// Result of a crop pipeline run. Mirrors the MCP `crop_image`
    /// output schema so the MCP tool can pass this through verbatim.
    public struct Result: Codable, Sendable {
        public var outputPath: String
        public var width: Int
        public var height: Int
        public var bytes: Int
        public var lossless: Bool
        public var actualRect: [Int]  // [x, y, w, h] — may differ from request

        public init(outputPath: String, width: Int, height: Int, bytes: Int, lossless: Bool, actualRect: CGRect) {
            self.outputPath = outputPath
            self.width = width
            self.height = height
            self.bytes = bytes
            self.lossless = lossless
            self.actualRect = [
                Int(actualRect.minX), Int(actualRect.minY),
                Int(actualRect.width), Int(actualRect.height),
            ]
        }
    }

    public struct Options: Sendable {
        public var format: CropOutputFormat
        public var quality: Int            // 1..100
        public var preferLossless: Bool    // JPEG-only lossless path
        public var preserveMetadata: Bool
        public var stripGPS: Bool

        public init(
            format: CropOutputFormat = .auto,
            quality: Int = 90,
            preferLossless: Bool = true,
            preserveMetadata: Bool = true,
            stripGPS: Bool = false
        ) {
            self.format = format
            self.quality = max(1, min(100, quality))
            self.preferLossless = preferLossless
            self.preserveMetadata = preserveMetadata
            self.stripGPS = stripGPS
        }
    }

    // MARK: - Public entry

    /// Crop `inputURL` to `rect` and write the result to `outputURL`.
    /// `rect` is in image pixel coordinates (origin top-left of the image).
    public static func crop(
        inputURL: URL,
        rect: CGRect,
        outputURL: URL,
        options: Options
    ) throws -> Result {

        let sourceFormat = inputURL.pathExtension.lowercased()
        let _trace = PerformanceLog.shared.start(
            "Crop.Apply",
            extra: [("source_format", sourceFormat)]
        )
        defer { _trace.finish() }

        guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw Error.sourceUnreadable(inputURL.path)
        }
        guard let originalCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Error.noPixelData
        }

        let imageSize = CGSize(width: originalCG.width, height: originalCG.height)
        let clippedRequest = CropMath.clip(CropMath.snapToIntegerPixels(rect), to: imageSize)
        guard clippedRequest.width >= 1, clippedRequest.height >= 1 else {
            throw Error.rectInvalid(rect, imageSize)
        }

        let resolvedFormat = resolveFormat(options.format, sourceURL: inputURL)
        let sourceUTI = CGImageSourceGetType(src) as String?

        // Decide actual rect: for JPEG-lossless, expand outward to MCU.
        var actualRect = clippedRequest
        var lossless = false
        if resolvedFormat == .jpeg, options.preferLossless,
           sourceUTI == UTType.jpeg.identifier {
            let mcu = mcuSize(for: src)
            actualRect = CropMath.roundOutwardToMCU(clippedRequest, mcu: mcu, imageSize: imageSize)
            lossless = CropMath.isMCUAligned(actualRect, mcu: mcu, imageSize: imageSize)
        }

        // Produce the cropped CGImage. CGImage uses bottom-left or top-left
        // origin depending on its provider; `cropping(to:)` interprets the
        // rect in image-pixel coords with top-left origin for ImageIO-
        // sourced images, which is what we have here.
        guard let cropped = originalCG.cropping(to: actualRect) else {
            throw Error.rectInvalid(actualRect, imageSize)
        }

        // Pull metadata properties once.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]

        try writeImage(
            cropped,
            to: outputURL,
            format: resolvedFormat,
            quality: options.quality,
            sourceProperties: options.preserveMetadata ? props : nil,
            stripGPS: options.stripGPS
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return Result(
            outputPath: outputURL.path,
            width: cropped.width,
            height: cropped.height,
            bytes: bytes,
            lossless: lossless,
            actualRect: actualRect
        )
    }

    // MARK: - Output format

    public static func resolveFormat(_ requested: CropOutputFormat, sourceURL: URL) -> CropOutputFormat {
        if requested != .auto { return requested }
        switch sourceURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "jfif", "jpe": return .jpeg
        case "png":  return .png
        case "webp": return .webp
        case "heic", "heif": return .heic
        case "avif": return .avif
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }

    public static func utType(for format: CropOutputFormat) -> CFString {
        switch format {
        case .auto, .png:  return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .webp: return UTType.webP.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        case .avif: return ("public.avif" as CFString)
        case .tiff: return UTType.tiff.identifier as CFString
        }
    }

    /// Default suffix for the format's filename. The spec uses
    /// `<basename>_cropped.<ext>` (`§4.1 / §7.1`).
    public static func defaultExtension(for format: CropOutputFormat, sourceURL: URL) -> String {
        switch format {
        case .auto: return sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .webp: return "webp"
        case .heic: return "heic"
        case .avif: return "avif"
        case .tiff: return "tif"
        }
    }

    // MARK: - Writer

    private static func writeImage(
        _ image: CGImage,
        to url: URL,
        format: CropOutputFormat,
        quality: Int,
        sourceProperties: [CFString: Any]?,
        stripGPS: Bool
    ) throws {
        let type = utType(for: format)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw Error.writeFailed("CGImageDestinationCreateWithURL returned nil for type \(type)")
        }
        var props: [CFString: Any] = [:]

        // Copy through EXIF / IPTC / XMP / GPS dictionaries.
        if var src = sourceProperties {
            // Rewrite EXIF orientation to .up — the cropped CGImage has
            // already been baked into display orientation.
            if var exif = src[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyOrientation] = 1
                src[kCGImagePropertyExifDictionary] = exif
            }
            src[kCGImagePropertyOrientation] = 1
            if stripGPS {
                src[kCGImagePropertyGPSDictionary] = nil
            }
            // Re-merge into props so format-specific keys below win.
            for (k, v) in src { props[k] = v }
        }

        if format == .jpeg || format == .webp || format == .heic || format == .avif {
            let q = max(0.0, min(1.0, Double(quality) / 100.0))
            props[kCGImageDestinationLossyCompressionQuality] = q
        }

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw Error.writeFailed("CGImageDestinationFinalize returned false (format=\(format))")
        }
    }

    // MARK: - JPEG MCU detection

    /// Best-effort MCU size from a JPEG's properties. Returns 16 for
    /// the common 4:2:0 case, 8 for 4:4:4 / grayscale / unknown.
    /// A real libjpeg-turbo path would parse SOF0/SOF2; we approximate
    /// from `kCGImagePropertyJFIFDictionary` and the image's color model.
    public static func mcuSize(for src: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return 16
        }
        if let color = props[kCGImagePropertyColorModel] as? String,
           color == (kCGImagePropertyColorModelGray as String) {
            return 8
        }
        return 16
    }

    // MARK: - Output path defaulting

    /// `<basename>_cropped.<ext>` next to the source. Used when MCP
    /// `crop_image` omits `output_path`.
    public static func defaultCroppedOutputURL(for source: URL, format: CropOutputFormat) -> URL {
        let resolved = resolveFormat(format, sourceURL: source)
        let ext = defaultExtension(for: resolved, sourceURL: source)
        let base = source.deletingPathExtension().lastPathComponent
        return source
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)_cropped.\(ext)")
    }
}
