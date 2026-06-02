import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Frame export helpers — spec §"Animation & Multi-Frame Support":
///   * Save individual frames.
///   * Export all frames to separate files.
///
/// All writes go through ImageIO so the encoder matches the destination
/// extension. The caller picks the destination URL (open-panel etc.).
public enum FrameExporter {

    public enum ExportError: Error, LocalizedError {
        case encoderUnavailable(UTType)
        case writeFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .encoderUnavailable(let t):
                return "No encoder available for \(t.identifier)."
            case .writeFailed(let url):
                return "Failed to write \(url.lastPathComponent)."
            }
        }
    }

    /// Save one frame to `destination`. The destination extension determines
    /// the encoder; PNG is the safe default when the caller doesn't care.
    public static func saveFrame(_ image: CGImage, to destination: URL) throws {
        let type = utType(for: destination) ?? .png
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw ExportError.encoderUnavailable(type)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed(destination)
        }
    }

    /// Save every frame in `source` to `directory`, naming files
    /// `{baseName}-001.{ext}` ... Returns the URLs written.
    @discardableResult
    public static func exportAll(
        _ source: FrameSource,
        to directory: URL,
        baseName: String,
        extension ext: String = "png"
    ) throws -> [URL] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var written: [URL] = []
        let pad = max(3, String(source.frameCount).count)
        for (idx, frame) in source.frames.enumerated() {
            let n = String(format: "%0\(pad)d", idx + 1)
            let url = directory.appendingPathComponent("\(baseName)-\(n).\(ext)")
            try saveFrame(frame.cgImage, to: url)
            written.append(url)
        }
        return written
    }

    private static func utType(for url: URL) -> UTType? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":           return .png
        case "jpg", "jpeg":   return .jpeg
        case "tif", "tiff":   return .tiff
        case "gif":           return .gif
        case "bmp":           return .bmp
        case "heic", "heif":  return .heic
        default:              return UTType(filenameExtension: ext)
        }
    }
}
