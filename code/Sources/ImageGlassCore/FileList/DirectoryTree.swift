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
/// `mcp_and_filters_on_dirs.mdx` §3 adds `priority`, §4.5 adds the
/// stable id).
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

    /// Stable id derived from `pattern + kind + negate + priority`.
    /// Spec `mcp_and_filters_on_dirs.mdx` §4.5: SHA1 over those four
    /// fields, first 6 hex chars. Re-writing the same item yields the
    /// same id, so `remove_filter_item` can reference items by id
    /// even when the LLM has not seen the YAML.
    ///
    /// Computed (not stored) so the id stays consistent if the item
    /// is mutated in place and re-saved — the id moves with the
    /// item's identity.
    public var id: String {
        var seed = pattern
        seed += "\u{1F}" + kind.rawValue
        seed += "\u{1F}" + (negate ? "1" : "0")
        seed += "\u{1F}" + String(priority)
        return RootFilterItem.sha1Hex6(seed)
    }

    /// First 6 hex chars of SHA-1(s). Pure-Swift Foundation-only
    /// implementation so the core target keeps a minimal dependency
    /// surface.
    static func sha1Hex6(_ s: String) -> String {
        let bytes = [UInt8](s.utf8)
        let digest = sha1(bytes)
        let hex = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        return hex
    }

    /// Minimal SHA-1 over a byte buffer. The standard library does
    /// not expose SHA-1 without CryptoKit (which we'd otherwise have
    /// to import for one call). 20-byte digest, big-endian per FIPS
    /// 180-4.
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var msg = message
        let originalBitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0x00) }
        for i in (0..<8).reversed() {
            msg.append(UInt8((originalBitLength >> (UInt64(i) * 8)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(msg[base]) << 24)
                     | (UInt32(msg[base + 1]) << 16)
                     | (UInt32(msg[base + 2]) << 8)
                     |  UInt32(msg[base + 3])
            }
            for i in 16..<80 {
                let v = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16]
                w[i] = (v << 1) | (v >> 31)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:  f = (b & c) | ((~b) & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d;            k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default:      f = b ^ c ^ d;            k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c
                c = (b << 30) | (b >> 2)
                b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c
            h3 = h3 &+ d; h4 = h4 &+ e
        }

        var out: [UInt8] = []
        for h in [h0, h1, h2, h3, h4] {
            out.append(UInt8((h >> 24) & 0xff))
            out.append(UInt8((h >> 16) & 0xff))
            out.append(UInt8((h >> 8) & 0xff))
            out.append(UInt8(h & 0xff))
        }
        return out
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

    /// Total count of nodes (directories + files) reachable from this
    /// node, including the node itself. O(N) single pass.
    ///
    /// Used by `logTraversalSummary(rootPath:corr:)` to populate the
    /// `node_count` field of the single per-walk
    /// `Tree.Traverse.Log` event. Callers that want the split between
    /// directory and file counts should call `nodeCountSplit` instead
    /// (one pass, both numbers).
    public var nodeCount: Int {
        let s = nodeCountSplit
        return s.directories + s.files
    }

    /// Directory and file counts in one pass. `directories` includes
    /// `self` when `self` is `.directory`.
    public var nodeCountSplit: (directories: Int, files: Int) {
        switch self {
        case .file:
            return (0, 1)
        case .directory(_, let children):
            var d = 1
            var f = 0
            for c in children {
                let s = c.nodeCountSplit
                d += s.directories
                f += s.files
            }
            return (d, f)
        }
    }

    /// Emit exactly ONE `Tree.Traverse.Log` event summarizing a
    /// just-completed traversal of this subtree. Carries `path`,
    /// `node_count`, `dir_count`, `file_count`, and `corr`.
    ///
    /// This replaces the historical `DirectoryTreeWalker.traverseAndLog`
    /// pattern that emitted one start/finish pair per node (~888K
    /// emissions per JFK/UX-scale walk in the June 2026 capture). The
    /// summary form runs the counter once and emits a single event
    /// line — see `perf/plans/Tree.Traverse.Log.plan`.
    ///
    /// Callers: any traversal entry point that finishes a full walk of
    /// a `DirectoryNode` subtree (walker post-walk hook, panel debug
    /// dump, MCP audit). Call ONCE per traversal, not per recursion
    /// frame.
    public func logTraversalSummary(rootPath: String, corr: String) {
        let split = nodeCountSplit
        let total = split.directories + split.files
        PerformanceLog.shared.event(
            "Tree.Traverse.Log",
            extra: [
                ("path", rootPath),
                ("node_count", String(total)),
                ("dir_count", String(split.directories)),
                ("file_count", String(split.files)),
                ("corr", corr),
            ]
        )
    }
}

/// docs/use_cases/include_checks.mdx §1 / §4.3 — three-state per-row
/// "include" decision attached to every visible row in the directory
/// panel. The user manipulates only these three values; the runtime
/// inheritance resolver in `RootDirectory.effectiveState(for:)`
/// collapses `inherit` to one of `include` / `exclude` at render time.
///
/// The on-disk identifier for `dontInclude` is `exclude` so the YAML
/// stays one unambiguous token and matches the existing `include` /
/// `exclude` vocabulary used elsewhere in the project.
public enum IncludeState: String, Sendable, Codable, CaseIterable {
    case include
    case inherit
    case exclude

    /// Cycle order from §3 — the order a swatch click or the `I`
    /// hotkey advances through on a sub-directory or file row.
    public var next: IncludeState {
        switch self {
        case .include: return .inherit
        case .inherit: return .exclude
        case .exclude: return .include
        }
    }

    /// include_checks.mdx §1.0 / §3 header / §4.3 — two-step cycle
    /// for ROOT rows. A root has no ancestor and so cannot inherit;
    /// the cycle is the binary flip `include ↔ exclude`. A root
    /// that somehow holds `.inherit` (corrupt YAML / unmigrated v1
    /// row) is coerced to `.include` on the first press.
    public var nextForRoot: IncludeState {
        switch self {
        case .include: return .exclude
        case .exclude: return .include
        case .inherit: return .include
        }
    }
}

/// One entry in the per-root `include_overrides[]` block
/// (include_checks.mdx §5.3). `path` is stored **relative** to the
/// root using forward slashes; `state` is one of `include` /
/// `exclude` (a row whose effective state is `inherit` has no
/// entry — §5.5).
public struct IncludeOverrideEntry: Sendable, Equatable, Codable {
    public var path: String
    public var state: IncludeState

    public init(path: String, state: IncludeState) {
        self.path = path
        self.state = state
    }
}

/// One root in `directories.yaml`. The on-disk shape is a flat
/// projection; the `tree` field is populated by the walker.
public struct RootDirectory: Sendable, Equatable {
    public var path: URL                  // canonical absolute path
    public var filter: RootFilter
    public var lastWalked: Date?
    public var tree: DirectoryNode?       // populated by the walker
    /// include_checks.mdx §5.2 — root-level default applied when no
    /// ancestor in the override walk is explicit. Allowed values:
    /// `.include` / `.exclude`. `.inherit` would leave the walk with
    /// no answer and is rejected at the store layer.
    public var defaultIncludeState: IncludeState
    /// include_checks.mdx §5.3 — flat list of per-path overrides. A
    /// row whose effective state is `inherit` has **no** entry; the
    /// absence of an entry IS `inherit`.
    public var includeOverrides: [IncludeOverrideEntry]

    public init(
        path: URL,
        filter: RootFilter = .empty,
        lastWalked: Date? = nil,
        tree: DirectoryNode? = nil,
        defaultIncludeState: IncludeState = .include,
        includeOverrides: [IncludeOverrideEntry] = []
    ) {
        self.path = path
        self.filter = filter
        self.lastWalked = lastWalked
        self.tree = tree
        self.defaultIncludeState = defaultIncludeState
        self.includeOverrides = includeOverrides
    }

    /// include_checks.mdx §6.1 — inheritance resolver. Walks up the
    /// supplied **relative** path looking for the nearest explicit
    /// ancestor override. Returns the root default when no ancestor
    /// is explicit. Never returns `.inherit`.
    public func effectiveState(for relativePath: String) -> IncludeState {
        // Build the lookup once per call. Cheap on JFK/UX-scale
        // (few-hundred overrides). The non-cached path in §6.3 is
        // the explicit design choice.
        var map: [String: IncludeState] = [:]
        for o in includeOverrides {
            map[Self.normalize(o.path)] = o.state
        }
        let normalized = Self.normalize(relativePath)
        // Walk up: row itself, then each ancestor, then the root ("").
        var current = normalized
        while true {
            if let s = map[current], s != .inherit { return s }
            if current.isEmpty { break }
            if let slash = current.lastIndex(of: "/") {
                current = String(current[..<slash])
            } else {
                current = ""
            }
        }
        return defaultIncludeState == .inherit ? .include : defaultIncludeState
    }

    /// include_checks.mdx §6.2 — the panel's two-pass render value.
    public func decision(for relativePath: String) -> EffectiveIncludeDecision {
        let explicit = explicitState(for: relativePath)
        let resolved = effectiveState(for: relativePath)
        return EffectiveIncludeDecision(explicit: explicit, resolved: resolved)
    }

    /// The row's own stored state — `.inherit` when no override entry
    /// matches the path. Distinct from the resolver, which always
    /// returns include/exclude.
    public func explicitState(for relativePath: String) -> IncludeState {
        let normalized = Self.normalize(relativePath)
        for o in includeOverrides where Self.normalize(o.path) == normalized {
            return o.state
        }
        return .inherit
    }

    /// Normalize a relative path: drop leading/trailing slashes,
    /// collapse runs of `/`. The walker hands the panel relative
    /// paths in a known shape so this is mostly defensive.
    static func normalize(_ raw: String) -> String {
        var s = raw
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        while s.contains("//") {
            s = s.replacingOccurrences(of: "//", with: "/")
        }
        return s
    }

    /// moves_and_reconciliation.mdx §4.4 / §5.3 / include_checks.mdx §12A.1
    /// — carry the include state forward across an **in-tree move**.
    /// When an item at root-relative path `oldRel` (and everything under
    /// it) moves to `newRel`, every `include_overrides[]` entry whose
    /// key is `oldRel` or a descendant of it is **reprefixed** to sit
    /// under `newRel`; the `state` is untouched, so a green check stays
    /// a green check at the new location. Entries outside the moved
    /// subtree are left alone.
    ///
    /// A pure root relocation (§4.5 / §12A.2) passes `oldRel == newRel`,
    /// which is a no-op here — the payoff of storing overrides relative
    /// to the root. Returns the number of override entries rewritten.
    @discardableResult
    public mutating func rewriteOverridePaths(
        fromRelative oldRel: String,
        toRelative newRel: String
    ) -> Int {
        let from = Self.normalize(oldRel)
        let to = Self.normalize(newRel)
        if from == to { return 0 }
        let fromPrefix = from + "/"
        var rewritten = 0
        for i in includeOverrides.indices {
            let key = Self.normalize(includeOverrides[i].path)
            if key == from {
                includeOverrides[i].path = to
                rewritten += 1
            } else if key.hasPrefix(fromPrefix) {
                let suffix = key.dropFirst(fromPrefix.count)
                includeOverrides[i].path = to.isEmpty
                    ? String(suffix)
                    : to + "/" + suffix
                rewritten += 1
            }
        }
        return rewritten
    }

    /// moves_and_reconciliation.mdx §5.4 / include_checks.mdx §12A.3 —
    /// an item that moved **out of scope** loses its explicit check.
    /// Deletes the override for `relativePath` and every descendant so
    /// nothing survives as a floating orphan. Returns the count deleted.
    @discardableResult
    public mutating func dropOverrides(under relativePath: String) -> Int {
        let base = Self.normalize(relativePath)
        let prefix = base + "/"
        let before = includeOverrides.count
        includeOverrides.removeAll { entry in
            let key = Self.normalize(entry.path)
            return key == base || key.hasPrefix(prefix)
        }
        return before - includeOverrides.count
    }
}

/// moves_and_reconciliation.mdx §5.6 / local_storage.mdx §5.6 — a
/// volume-scoped, move-stable identity for a file or directory. The
/// `inode` is the durable primary key on a single volume (stable
/// across a move/rename, **not** across volumes); `documentID` is the
/// corroborating key that survives an APFS safe-save and distinguishes
/// a moved document from a copy (nil when the volume does not supply
/// it). Persisted alongside each cached path so a move that happened
/// while the app was closed can be reconciled at next launch.
///
/// `fileResourceIdentifier` is intentionally **not** modeled here: it
/// is not durable across restarts and is used only for in-session
/// equality, so it never reaches disk.
public struct FileIdentity: Sendable, Equatable, Hashable, Codable {
    public var volumeID: String
    public var inode: UInt64
    public var documentID: UInt64?

    public init(volumeID: String, inode: UInt64, documentID: UInt64? = nil) {
        self.volumeID = volumeID
        self.inode = inode
        self.documentID = documentID
    }

    /// Read the move-stable identity for a URL, or nil if the file
    /// system does not supply the required keys (some network volumes).
    /// The inode comes from `FileManager` attributes (`.systemFileNumber`
    /// is a `FileAttributeKey`, not a URL resource key); the volume and
    /// document identifiers come from URL resource values.
    public static func read(for url: URL) -> FileIdentity? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let inodeNum = attrs[.systemFileNumber] as? Int
        else { return nil }
        let vals = try? url.resourceValues(
            forKeys: [.volumeIdentifierKey, .documentIdentifierKey]
        )
        // `volumeIdentifier` is an opaque NSCopying; its description is
        // stable within a boot and adequate as a persisted discriminator
        // (the FSEvents volume-UUID cursor is the authoritative cross-boot
        // check — local_storage.mdx §5.8).
        let volString = (vals?.volumeIdentifier).map { String(describing: $0) } ?? ""
        let doc = (vals?.documentIdentifier).map { UInt64(bitPattern: Int64($0)) }
        return FileIdentity(volumeID: volString, inode: UInt64(inodeNum), documentID: doc)
    }
}

/// include_checks.mdx §6.2 — render-time view-model bundling the
/// explicit state (what the row itself says) with the resolved state
/// (what the inheritance walk produced).
public struct EffectiveIncludeDecision: Sendable, Equatable {
    public let explicit: IncludeState
    public let resolved: IncludeState

    public init(explicit: IncludeState, resolved: IncludeState) {
        self.explicit = explicit
        self.resolved = resolved
    }

    /// True iff the row's own state is `.inherit` and the panel
    /// should render one of the muted-gray "Inherit" variants.
    public var isInherited: Bool { explicit == .inherit }
}

/// Utility for resolving the *absolute* path of a `DirectoryNode` row
/// against its root, then projecting it into the root-relative form
/// the include-override map keys on. Used by the panel and the
/// slideshow to ask `root.effectiveState(for: relativePath)`.
public enum IncludePath {
    /// `absolutePath` must already be a fully-resolved path under
    /// `root.path`; returns an empty string when they are equal
    /// (the root itself).
    public static func relative(absolutePath: String, root: URL) -> String {
        let rp = root.path
        if absolutePath == rp { return "" }
        if absolutePath.hasPrefix(rp + "/") {
            return String(absolutePath.dropFirst(rp.count + 1))
        }
        return absolutePath
    }
}
