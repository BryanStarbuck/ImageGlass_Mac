import Foundation

/// A Scope defines which files are in the active file list.
/// Persisted as plain JSON in Local Storage. Spec §3.1.
public struct Scope: Codable, Equatable, Sendable {
    public var name: String
    public var schemaVersion: Int
    public var description: String?
    public var criteria: [SourceCriterion]
    public var sort: ScopeSort
    public var filter: ScopeFilter
    public var lastEvaluated: Date?
    public var resolved: [ResolvedFile]

    public static let currentSchemaVersion = 1

    public init(
        name: String,
        schemaVersion: Int = Scope.currentSchemaVersion,
        description: String? = nil,
        criteria: [SourceCriterion] = [],
        sort: ScopeSort = .init(),
        filter: ScopeFilter = .init(),
        lastEvaluated: Date? = nil,
        resolved: [ResolvedFile] = []
    ) {
        self.name = name
        self.schemaVersion = schemaVersion
        self.description = description
        self.criteria = criteria
        self.sort = sort
        self.filter = filter
        self.lastEvaluated = lastEvaluated
        self.resolved = resolved
    }

    /// Legacy init: accepts the pre-multi-criteria shape (`include:` /
    /// `exclude:` / `resolvedFiles:`) used by tests and earlier callers.
    /// Translates into the canonical `criteria` array.
    public init(
        name: String,
        description: String? = nil,
        include: IncludeRules,
        exclude: ExcludeRules = .init(),
        lastEvaluated: Date? = nil,
        resolvedFiles: [String] = []
    ) {
        self.name = name
        self.schemaVersion = Self.currentSchemaVersion
        self.description = description
        self.sort = .init()
        self.filter = .init()
        self.lastEvaluated = lastEvaluated
        self.resolved = resolvedFiles.map { ResolvedFile(path: $0) }
        if include.directories.isEmpty {
            self.criteria = []
        } else {
            self.criteria = include.directories.map { dir in
                SourceCriterion(
                    root: dir,
                    recursive: include.recursive,
                    includeExts: include.extensions,
                    includeGlobs: include.globs,
                    excludeGlobs: exclude.globs,
                    includeHidden: !exclude.hiddenFiles
                )
            }
        }
    }

    // MARK: - Convenience: flat-shape access

    /// Backward-compatible view of the legacy `include` shape. Mirrors what
    /// callers (UI, MCP, AppState) previously read off of `scope.include`.
    /// Reads from `criteria` if present; writes go through `criteria`.
    /// New callers should prefer `criteria` directly.
    public var include: IncludeRules {
        get {
            guard let first = criteria.first else { return .init() }
            let dirs = criteria.map(\.root).filter { !$0.isEmpty }
            return IncludeRules(
                directories: dirs,
                recursive: first.recursive,
                globs: first.includeGlobs,
                extensions: first.includeExts
            )
        }
        set {
            // Treat each directory as its own criterion so per-directory
            // future edits remain isolated, but the recursive/include flags
            // apply to all of them — matches the legacy single-rules-set model.
            //
            // Even with no directories we keep a single placeholder criterion
            // so callers can stage criteria via setters before assigning
            // directories. This matches the pre-refactor "fields live on the
            // scope" mental model that tests and MCP setters rely on.
            if newValue.directories.isEmpty {
                let first = criteria.first
                criteria = [
                    SourceCriterion(
                        root: "",
                        recursive: newValue.recursive,
                        includeExts: newValue.extensions,
                        includeGlobs: newValue.globs,
                        excludeGlobs: first?.excludeGlobs ?? [],
                        includeHidden: first?.includeHidden ?? false
                    )
                ]
                return
            }
            criteria = newValue.directories.map { dir in
                SourceCriterion(
                    root: dir,
                    recursive: newValue.recursive,
                    includeExts: newValue.extensions,
                    includeGlobs: newValue.globs
                )
            }
        }
    }

    /// Backward-compatible view of the legacy `exclude` shape. The hidden-files
    /// flag is inverted from per-criterion `includeHidden` so the legacy
    /// `exclude.hiddenFiles = true` keeps meaning "hide hidden files".
    public var exclude: ExcludeRules {
        get {
            let first = criteria.first
            return ExcludeRules(
                globs: first?.excludeGlobs ?? [],
                hiddenFiles: !(first?.includeHidden ?? false)
            )
        }
        set {
            if criteria.isEmpty {
                criteria = [
                    SourceCriterion(
                        root: "",
                        excludeGlobs: newValue.globs,
                        includeHidden: !newValue.hiddenFiles
                    )
                ]
                return
            }
            for i in criteria.indices {
                criteria[i].excludeGlobs = newValue.globs
                criteria[i].includeHidden = !newValue.hiddenFiles
            }
        }
    }

    /// Flattened list of resolved file paths (back-compat with old callers that
    /// only saw `resolvedFiles: [String]`). Reads from `resolved`; writing
    /// reshapes `resolved` to skeleton entries (path only, metadata nil).
    public var resolvedFiles: [String] {
        get { resolved.map(\.path) }
        set { resolved = newValue.map { ResolvedFile(path: $0) } }
    }

    // MARK: - Nested types

    /// One include-directory rule with per-directory criteria. Spec §3.1.
    public struct SourceCriterion: Codable, Equatable, Sendable {
        public var root: String
        public var recursive: Bool
        public var maxDepth: Int?
        public var includeExts: [String]
        public var excludeExts: [String]
        public var includeGlobs: [String]
        public var excludeGlobs: [String]
        public var includeHidden: Bool
        public var followSymlinks: Bool
        /// Base64-encoded NSURL bookmark blob. Required in sandboxed builds.
        /// Spec §3.4.
        public var bookmark: String?

        public init(
            root: String,
            recursive: Bool = true,
            maxDepth: Int? = nil,
            includeExts: [String] = [],
            excludeExts: [String] = [],
            includeGlobs: [String] = [],
            excludeGlobs: [String] = [],
            includeHidden: Bool = false,
            followSymlinks: Bool = false,
            bookmark: String? = nil
        ) {
            self.root = root
            self.recursive = recursive
            self.maxDepth = maxDepth
            self.includeExts = includeExts
            self.excludeExts = excludeExts
            self.includeGlobs = includeGlobs
            self.excludeGlobs = excludeGlobs
            self.includeHidden = includeHidden
            self.followSymlinks = followSymlinks
            self.bookmark = bookmark
        }

        enum CodingKeys: String, CodingKey {
            case root
            case recursive
            case maxDepth = "max_depth"
            case includeExts = "include_exts"
            case excludeExts = "exclude_exts"
            case includeGlobs = "include_globs"
            case excludeGlobs = "exclude_globs"
            case includeHidden = "include_hidden"
            case followSymlinks = "follow_symlinks"
            case bookmark
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.root = try c.decode(String.self, forKey: .root)
            self.recursive = (try c.decodeIfPresent(Bool.self, forKey: .recursive)) ?? true
            self.maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth)
            self.includeExts = (try c.decodeIfPresent([String].self, forKey: .includeExts)) ?? []
            self.excludeExts = (try c.decodeIfPresent([String].self, forKey: .excludeExts)) ?? []
            self.includeGlobs = (try c.decodeIfPresent([String].self, forKey: .includeGlobs)) ?? []
            self.excludeGlobs = (try c.decodeIfPresent([String].self, forKey: .excludeGlobs)) ?? []
            self.includeHidden = (try c.decodeIfPresent(Bool.self, forKey: .includeHidden)) ?? false
            self.followSymlinks = (try c.decodeIfPresent(Bool.self, forKey: .followSymlinks)) ?? false
            self.bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark)
        }
    }

    /// Persistent sort selection. Spec §3.1 / §5.1.
    public struct ScopeSort: Codable, Equatable, Sendable {
        public enum Field: String, Codable, Sendable, CaseIterable {
            case name
            case size
            case modified
            case created
            case exifDateTaken = "exif_date_taken"
            case extension_  = "extension"
            case random
            case dimensions
        }
        public enum Direction: String, Codable, Sendable {
            case asc, desc
        }
        public var by: Field
        public var direction: Direction

        public init(by: Field = .name, direction: Direction = .asc) {
            self.by = by
            self.direction = direction
        }
    }

    /// Persistent filter selection. Spec §3.1 / §5.2.
    public struct ScopeFilter: Codable, Equatable, Sendable {
        public var text: String?
        public var dateFrom: Date?
        public var dateTo: Date?
        public var minWidth: Int?
        public var minHeight: Int?
        public var maxSize: Int64?

        public init(
            text: String? = nil,
            dateFrom: Date? = nil,
            dateTo: Date? = nil,
            minWidth: Int? = nil,
            minHeight: Int? = nil,
            maxSize: Int64? = nil
        ) {
            self.text = text
            self.dateFrom = dateFrom
            self.dateTo = dateTo
            self.minWidth = minWidth
            self.minHeight = minHeight
            self.maxSize = maxSize
        }

        enum CodingKeys: String, CodingKey {
            case text
            case dateFrom = "date_from"
            case dateTo = "date_to"
            case minWidth = "min_width"
            case minHeight = "min_height"
            case maxSize = "max_size"
        }

        public var isEmpty: Bool {
            text == nil && dateFrom == nil && dateTo == nil
                && minWidth == nil && minHeight == nil && maxSize == nil
        }
    }

    /// One row of the persisted `resolved` array. Spec §3.1.
    public struct ResolvedFile: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64?
        public var modified: Date?
        public var dim: [Int]?

        public init(path: String, size: Int64? = nil, modified: Date? = nil, dim: [Int]? = nil) {
            self.path = path
            self.size = size
            self.modified = modified
            self.dim = dim
        }
    }

    /// Legacy include-rules shape — preserved as a view onto `criteria` for
    /// existing callers (UI, AppState, MCP). New code should use
    /// `criteria` directly.
    public struct IncludeRules: Codable, Equatable, Sendable {
        public var directories: [String]
        public var recursive: Bool
        public var globs: [String]
        public var extensions: [String]

        public init(
            directories: [String] = [],
            recursive: Bool = true,
            globs: [String] = [],
            extensions: [String] = []
        ) {
            self.directories = directories
            self.recursive = recursive
            self.globs = globs
            self.extensions = extensions
        }
    }

    /// Legacy exclude-rules shape — preserved as a view onto `criteria`.
    public struct ExcludeRules: Codable, Equatable, Sendable {
        public var globs: [String]
        public var hiddenFiles: Bool

        public init(globs: [String] = [], hiddenFiles: Bool = true) {
            self.globs = globs
            self.hiddenFiles = hiddenFiles
        }
    }

    // MARK: - Custom Codable
    //
    // Reads two on-disk shapes:
    //  1) the canonical schema (spec §3.1) — { criteria: [...], sort, filter,
    //     resolved: [...], schema_version }.
    //  2) the legacy shape used by builds before the multi-criteria refactor —
    //     { include: { directories, recursive, globs, extensions },
    //       exclude: { globs, hiddenFiles },
    //       resolvedFiles: [String] }.
    //
    // Always writes the canonical shape. The legacy fallback exists only to
    // upgrade old user files without losing their data.

    enum CodingKeys: String, CodingKey {
        case name
        case schemaVersion = "schema_version"
        case description
        case criteria
        case sort
        case filter
        case lastEvaluated = "last_evaluated"
        case resolved
        // Legacy keys (decode-only fallback).
        case include
        case exclude
        case resolvedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.schemaVersion = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.sort = (try c.decodeIfPresent(ScopeSort.self, forKey: .sort)) ?? .init()
        self.filter = (try c.decodeIfPresent(ScopeFilter.self, forKey: .filter)) ?? .init()
        self.lastEvaluated = try c.decodeIfPresent(Date.self, forKey: .lastEvaluated)

        if let cri = try c.decodeIfPresent([SourceCriterion].self, forKey: .criteria) {
            self.criteria = cri
        } else if let legacyInclude = try c.decodeIfPresent(IncludeRules.self, forKey: .include) {
            let legacyExclude = (try c.decodeIfPresent(ExcludeRules.self, forKey: .exclude)) ?? .init()
            self.criteria = legacyInclude.directories.map { dir in
                SourceCriterion(
                    root: dir,
                    recursive: legacyInclude.recursive,
                    includeExts: legacyInclude.extensions,
                    excludeExts: [],
                    includeGlobs: legacyInclude.globs,
                    excludeGlobs: legacyExclude.globs,
                    includeHidden: !legacyExclude.hiddenFiles
                )
            }
        } else {
            self.criteria = []
        }

        if let res = try c.decodeIfPresent([ResolvedFile].self, forKey: .resolved) {
            self.resolved = res
        } else if let legacy = try c.decodeIfPresent([String].self, forKey: .resolvedFiles) {
            self.resolved = legacy.map { ResolvedFile(path: $0) }
        } else {
            self.resolved = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(criteria, forKey: .criteria)
        try c.encode(sort, forKey: .sort)
        if !filter.isEmpty {
            try c.encode(filter, forKey: .filter)
        }
        try c.encodeIfPresent(lastEvaluated, forKey: .lastEvaluated)
        try c.encode(resolved, forKey: .resolved)
    }
}

/// Default scope that ships with first launch.
public extension Scope {
    static var starter: Scope {
        // Pull the default extension list from the central format registry so
        // the on-disk story stays in sync with what the loader can actually
        // decode (see `docs/supported-formats.mdx`).
        Scope(
            name: "default",
            description: "Default scope — your Pictures folder.",
            criteria: [
                SourceCriterion(
                    root: "~/Pictures",
                    recursive: true,
                    includeExts: FormatRegistry.shared.defaultScopeExtensions(),
                    includeHidden: false
                )
            ]
        )
    }
}
