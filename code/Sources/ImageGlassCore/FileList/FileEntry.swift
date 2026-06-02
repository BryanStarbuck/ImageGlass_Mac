import Foundation

/// Value type representing a single file in the resolved file list.
/// Mirrors upstream `ImageGalleryItem.cs` but is a Swift value type — see spec §10.7.
public struct FileEntry: Identifiable, Hashable, Sendable {
    /// Original resolved-file path (may contain leading `~`). Used as identity.
    public let path: String

    /// Filesystem URL with tilde expanded.
    public let url: URL

    /// Last path component (filename).
    public let name: String

    /// Lowercase extension without dot, or empty string.
    public let ext: String

    /// File size in bytes (nil if not yet measured).
    public var size: Int64?

    /// Modification time (nil if not yet measured).
    public var mtime: Date?

    /// EXIF date taken (nil if not yet measured or no EXIF).
    public var dateTaken: Date?

    /// Pixel dimensions (nil if not yet measured).
    public var dimensions: CGSize?

    /// User-visible rating, 0–5 (nil if unset). EXIF Windows rating tag — spec §5.1.
    public var rating: Int?

    /// Index of the `SourceCriterion` / source directory that produced this file.
    /// Spec §3.2 and tree-mode §2.5.
    public var sourceIndex: Int

    /// Source directory string this file was discovered under (the canonical
    /// scope `include.directories` entry — may be tilde-relative).
    public var sourceDirectory: String

    public var id: String { path }

    public init(
        path: String,
        sourceIndex: Int = 0,
        sourceDirectory: String = ""
    ) {
        self.path = path
        let expanded = AppPaths.expandTilde(path)
        self.url = URL(fileURLWithPath: expanded)
        self.name = self.url.lastPathComponent
        let pext = self.url.pathExtension.lowercased()
        self.ext = pext
        self.sourceIndex = sourceIndex
        self.sourceDirectory = sourceDirectory
    }

    // MARK: - Convenience

    /// Heuristic: extension is in the RAW whitelist. Spec §4.2.
    public var isRAW: Bool {
        Self.rawExtensions.contains(ext)
    }

    /// Heuristic: extension is animated by default.
    public var isAnimated: Bool {
        Self.animatedExtensions.contains(ext)
    }

    /// True when the extension likely needs an image-decoder thumbnail
    /// (vs. a file-type icon fallback). Spec §4.2.
    public var isImageLike: Bool {
        Self.imageExtensions.contains(ext)
    }

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif",
        "webp", "bmp", "svg", "avif", "jxl",
        "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "srw",
        "ico", "exr",
    ]

    public static let rawExtensions: Set<String> = [
        "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "srw",
    ]

    public static let animatedExtensions: Set<String> = [
        "gif", "apng", "webp",
    ]
}

extension FileEntry {
    /// Populate `size`, `mtime`, and `type` from URL resource values.
    /// Used by sort fields that need cheap (non-image) data.
    public mutating func loadCheapMetadata() {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .typeIdentifierKey,
        ]
        let vals = try? url.resourceValues(forKeys: keys)
        if let s = vals?.fileSize { self.size = Int64(s) }
        if let m = vals?.contentModificationDate { self.mtime = m }
    }
}
