import Foundation
import CoreGraphics
import ImageIO

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Output formats the Crop pipeline knows how to write via ImageIO.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, avif, webp, tiff, gif
    case auto

    /// Format inferred from a filename extension. Returns nil for unknown.
    public static func fromExtension(_ ext: String) -> OutputFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg":      return .jpeg
        case "png":              return .png
        case "heic", "heif":     return .heic
        case "avif":             return .avif
        case "webp":             return .webp
        case "tif", "tiff":      return .tiff
        case "gif":              return .gif
        default:                 return nil
        }
    }

    /// CGImageDestination UTI string for this format.
    public var uti: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png:  return "public.png"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .webp: return "org.webmproject.webp"
        case .tiff: return "public.tiff"
        case .gif:  return "com.compuserve.gif"
        case .auto: return "public.jpeg" // fallback; resolver should pick a real one
        }
    }
}

/// Errors thrown by the crop pipeline.
public enum CropPipelineError: Error, CustomStringConvertible {
    case sourceNotFound(String)
    case sourceUnreadable(String)
    case invalidRectangle(String)
    case rectOutOfBounds(rect: CropRect, sourceWidth: Int, sourceHeight: Int)
    case animatedImageNotSupported
    case destinationFailure(String)
    case overwriteRefused(String)

    public var description: String {
        switch self {
        case .sourceNotFound(let p):
            return "Source file not found: \(p)"
        case .sourceUnreadable(let p):
            return "Source file is not a readable image: \(p)"
        case .invalidRectangle(let msg):
            return "Invalid crop rectangle: \(msg)"
        case .rectOutOfBounds(let r, let w, let h):
            return "Crop rectangle (\(r.x),\(r.y),\(r.width),\(r.height)) is outside source bounds \(w)x\(h)."
        case .animatedImageNotSupported:
            return "Crop is not available for animated images. Extract a frame first."
        case .destinationFailure(let msg):
            return "Failed to write output: \(msg)"
        case .overwriteRefused(let p):
            return "Refusing to overwrite existing file: \(p)"
        }
    }
}

/// Result of a single crop operation.
public struct CropResult: Equatable, Sendable {
    public let outputPath: String
    public let width: Int
    public let height: Int
    public let format: OutputFormat
    public let bytesWritten: Int
    /// True iff the JPEG bitstream was preserved (no re-encode). Always
    /// false in v1 — see `JPEGLosslessCrop` doc comment.
    public let losslessUsed: Bool
    /// Present iff the input rectangle was widened to MCU boundaries.
    public let roundedToMCU: CropRect?
}

/// Options applied during one crop call.
public struct CropOptions: Sendable {
    public var format: OutputFormat
    public var quality: Double
    public var losslessJPEG: Bool
    public var stripMetadata: Bool
    public var overwrite: Bool

    public init(
        format: OutputFormat = .auto,
        quality: Double = 0.92,
        losslessJPEG: Bool = true,
        stripMetadata: Bool = false,
        overwrite: Bool = false
    ) {
        self.format = format
        self.quality = quality
        self.losslessJPEG = losslessJPEG
        self.stripMetadata = stripMetadata
        self.overwrite = overwrite
    }
}

/// Pure-Swift crop pipeline. No GUI dependencies; safe to call from MCP.
public enum CropPipeline {

    // MARK: Public API

    /// Read `inputPath`, crop to `rect`, write to `outputPath` (or
    /// overwrite the input when `outputPath == nil`).
    @discardableResult
    public static func cropFile(
        inputPath: String,
        rect: CropRect,
        outputPath: String? = nil,
        options: CropOptions = .init()
    ) throws -> CropResult {
        let expandedIn = AppPaths.expandTilde(inputPath)
        guard FileManager.default.fileExists(atPath: expandedIn) else {
            throw CropPipelineError.sourceNotFound(expandedIn)
        }
        let resolvedOut = AppPaths.expandTilde(outputPath ?? inputPath)

        let inURL = URL(fileURLWithPath: expandedIn)
        let outURL = URL(fileURLWithPath: resolvedOut)

        // Read source to learn dimensions / metadata / animation status.
        guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil) else {
            throw CropPipelineError.sourceUnreadable(expandedIn)
        }
        let count = CGImageSourceGetCount(src)
        if count > 1 {
            // Multi-image containers — HEIC bursts and animated GIF/APNG/WebP.
            // For now, allow HEIC bursts (we just take frame 0) but block GIF/APNG.
            let srcType = CGImageSourceGetType(src) as String? ?? ""
            if srcType.contains("gif") || srcType.contains("png") || srcType.contains("webp") {
                throw CropPipelineError.animatedImageNotSupported
            }
        }

        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pixelW = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelH = props[kCGImagePropertyPixelHeight] as? Int else {
            throw CropPipelineError.sourceUnreadable(expandedIn)
        }

        try validate(rect: rect, sourceWidth: pixelW, sourceHeight: pixelH)

        // Refuse to overwrite a *different* path unless asked.
        if outputPath != nil, outputPath != inputPath,
           FileManager.default.fileExists(atPath: resolvedOut),
           !options.overwrite {
            throw CropPipelineError.overwriteRefused(resolvedOut)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CropPipelineError.sourceUnreadable(expandedIn)
        }
        guard let cropped = cgImage.cropping(to: rect.cgRect) else {
            throw CropPipelineError.invalidRectangle("CGImage.cropping returned nil")
        }

        let format = resolveFormat(
            requested: options.format,
            outputExt: outURL.pathExtension,
            inputExt: inURL.pathExtension
        )

        let metadata: CGImageMetadata? = options.stripMetadata
            ? nil
            : CGImageSourceCopyMetadataAtIndex(src, 0, nil)

        try writeImage(
            cropped,
            to: outURL,
            format: format,
            quality: options.quality,
            metadata: metadata
        )

        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        return CropResult(
            outputPath: outURL.path,
            width: rect.width,
            height: rect.height,
            format: format,
            bytesWritten: bytes,
            losslessUsed: false,
            roundedToMCU: nil
        )
    }

    /// Crop an in-memory `CGImage`. Used by the GUI for the on-screen
    /// "Apply Crop" action where there is no source URL.
    public static func cropCGImage(_ image: CGImage, to rect: CropRect) throws -> CGImage {
        try validate(rect: rect, sourceWidth: image.width, sourceHeight: image.height)
        guard let out = image.cropping(to: rect.cgRect) else {
            throw CropPipelineError.invalidRectangle("CGImage.cropping returned nil")
        }
        return out
    }

    /// Read width × height of an image file without decoding pixels.
    public static func readDimensions(of path: String) throws -> (width: Int, height: Int) {
        let expanded = AppPaths.expandTilde(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CropPipelineError.sourceNotFound(expanded)
        }
        let url = URL(fileURLWithPath: expanded)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw CropPipelineError.sourceUnreadable(expanded)
        }
        return (w, h)
    }

    // MARK: - Helpers

    private static func validate(rect: CropRect, sourceWidth sw: Int, sourceHeight sh: Int) throws {
        guard rect.isValid else {
            throw CropPipelineError.invalidRectangle("width and height must be > 0")
        }
        guard rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= sw,
              rect.y + rect.height <= sh else {
            throw CropPipelineError.rectOutOfBounds(rect: rect, sourceWidth: sw, sourceHeight: sh)
        }
    }

    private static func resolveFormat(requested: OutputFormat, outputExt: String, inputExt: String) -> OutputFormat {
        if requested != .auto { return requested }
        if let outFmt = OutputFormat.fromExtension(outputExt) { return outFmt }
        if let inFmt = OutputFormat.fromExtension(inputExt) { return inFmt }
        return .jpeg
    }

    private static func writeImage(
        _ image: CGImage,
        to url: URL,
        format: OutputFormat,
        quality: Double,
        metadata: CGImageMetadata?
    ) throws {
        // Ensure parent dir exists.
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.uti as CFString,
            1,
            nil
        ) else {
            throw CropPipelineError.destinationFailure("CGImageDestinationCreateWithURL returned nil for \(format)")
        }

        var props: [CFString: Any] = [:]
        switch format {
        case .jpeg, .heic, .avif:
            props[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, quality))
        case .webp:
            props[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, quality))
        case .png, .tiff, .gif, .auto:
            break
        }

        if let metadata = metadata {
            CGImageDestinationAddImageAndMetadata(dest, image, metadata, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }

        if !CGImageDestinationFinalize(dest) {
            throw CropPipelineError.destinationFailure("CGImageDestinationFinalize failed for \(url.path)")
        }
    }
}
