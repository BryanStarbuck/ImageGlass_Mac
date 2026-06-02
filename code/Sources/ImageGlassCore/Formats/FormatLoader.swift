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
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw FormatLoaderError.fileNotFound(url)
        }

        let format = FormatRegistry.shared.format(forURL: url)

        // Spec §"Special Input Methods": .b64 files contain base64-encoded
        // image bytes. Decode the text, then re-enter the loader with the
        // resulting binary blob.
        if format?.id == "base64" {
            return try Base64Loader.loadFromBase64File(url: url)
        }

        // Hard-fail formats that need a delegate we don't have. We could
        // attempt Image I/O anyway, but the spec asks us to be explicit so
        // the UI layer can show a helpful message instead of a corrupt image.
        if let f = format, f.needsExternalDelegate {
            // Special case: HEIC/HEIF, PSD, AVIF — Image I/O can sometimes
            // produce a flat composite even though the spec marks them as
            // needing a delegate for advanced features. Try Image I/O and
            // fall back to the error if it can't decode.
            if let loaded = try? decodeWithImageIO(url: url, format: format) {
                return loaded
            }
            throw FormatLoaderError.requiresExternalDelegate(f)
        }

        do {
            return try decodeWithImageIO(url: url, format: format)
        } catch {
            throw FormatLoaderError.unreadable(url, underlying: error)
        }
    }

    // MARK: - Data

    /// Load an image from raw bytes (clipboard payload, network blob, ...).
    public static func load(data: Data, hintedExtension: String? = nil) throws -> LoadedImage {
        guard !data.isEmpty else { throw FormatLoaderError.emptyData }

        let sniffedExt = hintedExtension ?? sniffExtension(from: data)
        let format = sniffedExt.flatMap { FormatRegistry.shared.format(forExtension: $0) }

        if let f = format, f.needsExternalDelegate {
            if let loaded = try? decodeWithImageIO(data: data, format: format, sourceURL: nil) {
                return loaded
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
        format: FormatInfo?
    ) throws -> LoadedImage {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw FormatLoaderError.decodingFailed("CGImageSource init failed")
        }
        return try decode(source: source, format: format, sourceURL: url)
    }

    private static func decodeWithImageIO(
        data: Data,
        format: FormatInfo?,
        sourceURL: URL?
    ) throws -> LoadedImage {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            throw FormatLoaderError.decodingFailed("CGImageSource init failed")
        }
        return try decode(source: source, format: format, sourceURL: sourceURL)
    }

    private static func decode(
        source: CGImageSource,
        format: FormatInfo?,
        sourceURL: URL?
    ) throws -> LoadedImage {
        let frameCount = max(1, CGImageSourceGetCount(source))
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FormatLoaderError.decodingFailed("CGImageSourceCreateImageAtIndex returned nil")
        }
        let uti = CGImageSourceGetType(source) as String?
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
