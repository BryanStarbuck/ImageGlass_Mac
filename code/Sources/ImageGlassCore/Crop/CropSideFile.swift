import Foundation
import CoreGraphics

/// On-disk per-image crop side-file (`docs/crop.mdx §5.5`).
///
/// Path: `<dir>/.imageglass/crop/<basename>.json`
///
/// Opt-in via `tools.crop.write_side_files`. Lets an MCP-driven batch
/// worker resume where it left off without re-reading the image.
public struct CropSideFile: Codable, Sendable, Equatable {
    public var rect: [Int]            // [x, y, w, h]
    public var applied: Bool
    public var savedTo: String?       // path the cropped output landed at, if any
    public var updatedAt: Date

    public init(rect: CGRect, applied: Bool, savedTo: String?, updatedAt: Date = Date()) {
        self.rect = [
            Int(rect.minX), Int(rect.minY),
            Int(rect.width), Int(rect.height),
        ]
        self.applied = applied
        self.savedTo = savedTo
        self.updatedAt = updatedAt
    }

    public var cgRect: CGRect {
        guard rect.count == 4 else { return .zero }
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }

    private enum CodingKeys: String, CodingKey {
        case rect
        case applied
        case savedTo = "saved_to"
        case updatedAt = "updated_at"
    }
}

public enum CropSideFileStore {

    /// Directory holding per-image side files for a given image. The
    /// hidden-by-default `.imageglass` folder lives next to the image
    /// so it travels with the source files when they're moved.
    public static func sideFileDir(for imageURL: URL) -> URL {
        imageURL
            .deletingLastPathComponent()
            .appendingPathComponent(".imageglass", isDirectory: true)
            .appendingPathComponent("crop", isDirectory: true)
    }

    public static func sideFileURL(for imageURL: URL) -> URL {
        let base = imageURL.deletingPathExtension().lastPathComponent
        return sideFileDir(for: imageURL).appendingPathComponent("\(base).json")
    }

    @discardableResult
    public static func write(_ entry: CropSideFile, for imageURL: URL) throws -> URL {
        let dir = sideFileDir(for: imageURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = sideFileURL(for: imageURL)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(entry)
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func read(for imageURL: URL) -> CropSideFile? {
        let url = sideFileURL(for: imageURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CropSideFile.self, from: data)
    }
}
