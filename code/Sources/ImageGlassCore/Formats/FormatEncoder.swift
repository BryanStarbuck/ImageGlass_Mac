import Foundation
import CoreGraphics
import ImageIO

/// Errors raised by `FormatEncoder`.
public enum FormatEncoderError: Error, LocalizedError {
    case unwritableFormat(FormatInfo)
    case unknownExtension(String)
    case missingUTI(FormatInfo)
    case destinationCreateFailed(URL, String)
    case finalizeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unwritableFormat(let f):
            return "\(f.displayName) is read-only — saving in this format is not supported."
        case .unknownExtension(let e):
            return "Cannot save: unknown file extension '.\(e)'."
        case .missingUTI(let f):
            return "\(f.displayName) has no system UTI registered for writing."
        case .destinationCreateFailed(let url, let m):
            return "Could not create writer for \(url.lastPathComponent): \(m)"
        case .finalizeFailed(let url, let m):
            return "Could not finalize save to \(url.lastPathComponent): \(m)"
        }
    }
}

/// Options that map onto `CGImageDestination` properties. The spec lists
/// PNG, JPEG, GIF, TIFF, WebP as the save targets; per-format keys vary so
/// this struct collects the common ones and the encoder picks the relevant
/// ones for each output format.
public struct EncoderOptions: Sendable {
    /// Lossy quality from 0.0 (worst, smallest) to 1.0 (best, largest).
    /// Applies to JPEG, HEIC, JPEG 2000, WebP. Ignored by lossless formats.
    public var lossyQuality: Double?

    public init(lossyQuality: Double? = nil) {
        self.lossyQuality = lossyQuality
    }

    public static let `default` = EncoderOptions(lossyQuality: 0.9)
}

/// Save-as router. Picks the correct system UTI from `FormatRegistry`,
/// invokes `CGImageDestination`, and surfaces a clean error if the requested
/// extension can't be written by Image I/O on this OS.
///
/// Spec §"Read vs. Write Support" — save targets ImageGlass commits to:
/// PNG, JPEG, GIF, TIFF, WebP. Additional Image I/O-writable formats
/// (HEIC, BMP, JPEG 2000) are also routed by extension since the registry
/// marks them writable.
public enum FormatEncoder {

    /// Save `image` to `url`, picking the output format from `url`'s
    /// extension. Throws `FormatEncoderError` if the format isn't writable.
    @discardableResult
    public static func save(
        _ image: CGImage,
        to url: URL,
        options: EncoderOptions = .default
    ) throws -> URL {
        guard let format = FormatRegistry.shared.format(forURL: url) else {
            throw FormatEncoderError.unknownExtension(url.pathExtension)
        }
        return try save(image, to: url, format: format, options: options)
    }

    /// Save `image` to `url` using an explicitly chosen format. The URL's
    /// extension does not need to match; callers that build a destination
    /// path from a known format id should use this overload.
    @discardableResult
    public static func save(
        _ image: CGImage,
        to url: URL,
        format: FormatInfo,
        options: EncoderOptions = .default
    ) throws -> URL {
        // §5.2 `Format.Convert` — wraps the actual encode + atomic write.
        // We don't always know a *source* format here (the caller hands us
        // a CGImage), so `from` is "cgimage" unless the URL extension is
        // recognized, in which case we use that as a hint of where this
        // image came from.
        let srcFmt = FormatRegistry.shared.format(forURL: url)?.id ?? "cgimage"
        let _trace = PerformanceLog.shared.start(
            "Format.Convert",
            extra: [
                ("from", srcFmt),
                ("to", format.id),
                ("path", url.path),
                ("pixels", String(image.width * image.height)),
            ]
        )
        defer { _trace.finish() }

        guard format.canWrite else {
            throw FormatEncoderError.unwritableFormat(format)
        }
        guard let utiString = format.uti else {
            throw FormatEncoderError.missingUTI(format)
        }

        let uti = utiString as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            throw FormatEncoderError.destinationCreateFailed(url, "Image I/O refused UTI '\(utiString)' for this OS.")
        }

        var props: [CFString: Any] = [:]
        if let q = options.lossyQuality, formatAcceptsQuality(format) {
            props[kCGImageDestinationLossyCompressionQuality] = clamp01(q)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FormatEncoderError.finalizeFailed(url, "CGImageDestinationFinalize returned false (UTI may be unsupported on this OS).")
        }
        return url
    }

    /// Return every format the registry marks writable. Used by the
    /// "Save As..." UI to populate the format picker.
    public static func writableFormats() -> [FormatInfo] {
        FormatRegistry.shared.all.filter { $0.canWrite && $0.uti != nil }
    }

    // MARK: - Internals

    /// Quality is only meaningful for lossy codecs.
    private static func formatAcceptsQuality(_ f: FormatInfo) -> Bool {
        switch f.id {
        case "jpeg", "jpeg2000", "heic", "webp", "avif":
            return true
        default:
            return false
        }
    }

    private static func clamp01(_ x: Double) -> Double {
        if x.isNaN { return 0.9 }
        return min(1.0, max(0.0, x))
    }
}
