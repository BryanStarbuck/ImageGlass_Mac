import Foundation
import UniformTypeIdentifiers

/// In-memory model for the directory tree panel. Mirrors the schema in
/// `docs/list_of_files.mdx` §3A and the verify-steps in
/// `docs/use_cases/mcp_file.mdx`.
///
/// The walker (Stage D) is the only thing that mutates these structures.
/// The MCP tools (Stage B) operate on a flat YAML projection; the
/// `DirectoriesStore` reads and writes that projection.

/// The three file kinds that the built-in file-kind filter
/// (`list_of_files.mdx` §3A.3) lets through. Everything else is dropped
/// at the walker stage and never enters the in-memory tree.
public enum FileKind: String, Sendable, Codable {
    case image
    case svg
    case video

    /// Classify a UTI. Returns `nil` if the file should be dropped.
    public static func classify(uti: UTType) -> FileKind? {
        if uti.identifier == "public.svg-image" {
            return .svg
        }
        if uti.conforms(to: .movie) {
            return .video
        }
        if uti.conforms(to: .image) {
            return .image
        }
        return nil
    }

    /// Classify by path. Falls back to the extension table when the
    /// system UTI lookup fails (synthetic / test paths that don't exist
    /// on disk).
    public static func classify(path: String) -> FileKind? {
        let url = URL(fileURLWithPath: path)
        if let resolved = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if let k = classify(uti: resolved) { return k }
        }
        let ext = url.pathExtension.lowercased()
        if let uti = UTType(filenameExtension: ext) {
            if let k = classify(uti: uti) { return k }
        }
        return Self.fallbackByExtension(ext)
    }

    private static func fallbackByExtension(_ ext: String) -> FileKind? {
        switch ext {
        case "jpg", "jpeg", "jfif", "png", "heic", "heif", "webp", "avif",
             "jxl", "tif", "tiff", "gif", "bmp", "ico", "icns",
             "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2":
            return .image
        case "svg":
            return .svg
        case "mp4", "mov", "m4v", "hevc", "avi", "mkv":
            return .video
        default:
            return nil
        }
    }
}

/// One item in `filter.items[]` (`list_of_files.mdx` §3A.2).
public struct RootFilterItem: Sendable, Equatable, Codable {
    public enum ItemKind: String, Sendable, Codable {
        case glob, substring, regex
    }

    public var pattern: String
    public var kind: ItemKind
    public var negate: Bool

    public init(pattern: String, kind: ItemKind = .glob, negate: Bool = false) {
        self.pattern = pattern
        self.kind = kind
        self.negate = negate
    }
}

/// Per-root filter. Default (`items` empty) lets everything through.
public struct RootFilter: Sendable, Equatable, Codable {
    public enum Match: String, Sendable, Codable {
        case any, all
    }

    public var match: Match
    public var items: [RootFilterItem]

    public init(match: Match = .any, items: [RootFilterItem] = []) {
        self.match = match
        self.items = items
    }

    public static let empty = RootFilter()

    /// Number of `negate: true` items — used for the `negate_items=N`
    /// log field in §7's verify step.
    public var negateCount: Int {
        items.reduce(0) { $0 + ($1.negate ? 1 : 0) }
    }

    /// Evaluate the filter against a single filename. Returns `true` if
    /// the file passes (would be visible).
    ///
    /// Semantics (mcp_file.mdx §7): negate items are exclusion overrides —
    /// if any `negate: true` item matches the filename, the file is
    /// excluded regardless of how positive items combine. Otherwise the
    /// positive items are combined according to `match` (`any` ORs them,
    /// `all` ANDs them). If only negate items are present, the file
    /// passes unless one of them matches.
    public func evaluate(filename: String) -> Bool {
        if items.isEmpty { return true }
        for item in items where item.negate {
            if Self.itemMatches(item, filename: filename) { return false }
        }
        let positives = items.filter { !$0.negate }
        if positives.isEmpty { return true }
        switch match {
        case .any:
            return positives.contains { Self.itemMatches($0, filename: filename) }
        case .all:
            return positives.allSatisfy { Self.itemMatches($0, filename: filename) }
        }
    }

    private static func itemMatches(_ item: RootFilterItem, filename: String) -> Bool {
        switch item.kind {
        case .glob:
            return Glob.match(item.pattern, filename)
        case .substring:
            return filename.range(of: item.pattern, options: .caseInsensitive) != nil
        case .regex:
            guard let re = try? NSRegularExpression(pattern: item.pattern) else { return false }
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            return re.firstMatch(in: filename, range: range) != nil
        }
    }
}

/// Recursive in-memory mirror of one root's directory hierarchy.
public indirect enum DirectoryNode: Sendable, Equatable {
    case directory(name: String, children: [DirectoryNode])
    case file(name: String, kind: FileKind, passesFilter: Bool)

    public var name: String {
        switch self {
        case .directory(let n, _): return n
        case .file(let n, _, _): return n
        }
    }
}

/// One root in `directories.yaml`. The on-disk shape is a flat
/// projection; the `tree` field is populated by the walker.
public struct RootDirectory: Sendable, Equatable {
    public var path: URL                  // canonical absolute path
    public var filter: RootFilter
    public var lastWalked: Date?
    public var tree: DirectoryNode?       // populated by the walker

    public init(
        path: URL,
        filter: RootFilter = .empty,
        lastWalked: Date? = nil,
        tree: DirectoryNode? = nil
    ) {
        self.path = path
        self.filter = filter
        self.lastWalked = lastWalked
        self.tree = tree
    }
}
