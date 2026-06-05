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
        let ext = url.pathExtension.lowercased()
        // Hard deny first. `.ts` (TypeScript) otherwise resolves to
        // `public.mpeg-2-transport-stream` → `.video`, so node_modules and
        // HTML-export folders flood the tree with code files wearing a film
        // icon. These extensions are never design assets we preview.
        if Self.nonMediaExtensions.contains(ext) { return nil }
        if let resolved = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if let k = classify(uti: resolved) { return k }
        }
        if let uti = UTType(filenameExtension: ext) {
            if let k = classify(uti: uti) { return k }
        }
        return Self.fallbackByExtension(ext)
    }

    /// Extensions that are never previewable design assets — code, text,
    /// data, fonts, sourcemaps. Excluded before UTType lookup so e.g. `.ts`
    /// isn't mistaken for MPEG transport-stream video.
    static let nonMediaExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "json", "map",
        "css", "scss", "sass", "less", "html", "htm", "xml", "yml", "yaml",
        "md", "markdown", "txt", "csv", "log", "lock",
        "woff", "woff2", "ttf", "otf", "eot",
        "wasm", "node", "d", "sh", "py", "rb", "go", "rs", "swift", "c", "h",
        "cpp", "java", "kt", "php", "sql", "env", "gitignore", "npmignore"
    ]

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

/// One item in `filter.items[]` (`list_of_files.mdx` §3A.2;
/// `mcp_and_filters_on_dirs.mdx` §3 adds `priority`).
public struct RootFilterItem: Sendable, Equatable, Codable {
    public enum ItemKind: String, Sendable, Codable {
        case glob, substring, regex
    }

    public var pattern: String
    public var kind: ItemKind
    public var negate: Bool
    /// Priority tier. Higher tiers decide before lower tiers
    /// (`mcp_and_filters_on_dirs.mdx` §3.3). Default `0`. Range
    /// `-1000…1000` (the engine clamps silently to this range to
    /// keep the resolution algorithm O(items)).
    public var priority: Int

    public init(
        pattern: String,
        kind: ItemKind = .glob,
        negate: Bool = false,
        priority: Int = 0
    ) {
        self.pattern = pattern
        self.kind = kind
        self.negate = negate
        self.priority = max(-1000, min(1000, priority))
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
    /// Semantics (`mcp_and_filters_on_dirs.mdx` §3.3, refined):
    ///
    ///   1. Group items by `priority`, walk groups highest-first.
    ///   2. Within a tier, negative match always wins (excluded).
    ///      Otherwise, positive match commits the verdict (included,
    ///      per `match`). Neither matching = the tier abstains.
    ///   3. Higher-priority tiers that abstain fall through to the
    ///      next lower tier. They are pure **overrides** — they only
    ///      commit a verdict when a positive or negative item
    ///      actually matches.
    ///   4. The **lowest** priority tier additionally applies the
    ///      `mcp_file.mdx` §7.0 narrowing rule: if it carries
    ///      positive items and none of them match (and no negative
    ///      matched), the file is excluded. A lowest tier consisting
    ///      only of negate items (or no items) and no match includes
    ///      the file.
    ///
    /// This split preserves the §7.0.1 cookbook exactly when no
    /// priorities are used (single-tier filter ⇒ lowest tier), while
    /// allowing a high-priority positive to express "always include
    /// this file" without forcing unrelated files to also match a
    /// positive in order to remain visible.
    public func evaluate(filename: String) -> Bool {
        if items.isEmpty { return true }

        // Group by priority, descending.
        let grouped: [(Int, [RootFilterItem])] = Dictionary(grouping: items, by: { $0.priority })
            .map { ($0.key, $0.value) }
            .sorted(by: { $0.0 > $1.0 })

        for (i, (_, tier)) in grouped.enumerated() {
            let isLowest = (i == grouped.count - 1)
            let positives = tier.filter { !$0.negate }
            let negatives = tier.filter { $0.negate }

            if negatives.contains(where: { Self.itemMatches($0, filename: filename) }) {
                return false
            }

            let positiveMatched = positives.contains { Self.itemMatches($0, filename: filename) }
            if positiveMatched {
                switch match {
                case .any:
                    return true
                case .all:
                    if positives.allSatisfy({ Self.itemMatches($0, filename: filename) }) {
                        return true
                    }
                    // Partial match under AND: this tier's override
                    // did not fully apply. Fall through.
                    continue
                }
            }

            // No match in this tier.
            if isLowest {
                // §7.0 narrowing: positives present + none match
                // ⇒ excluded. negate-only or empty ⇒ included.
                return positives.isEmpty
            }
            // Non-lowest tier abstains — try the next-lower tier.
        }
        // Unreachable in normal use: the lowest-tier branch above
        // always returns. Defensive return preserves total func.
        return true
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
