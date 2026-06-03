import Foundation

/// MCP tools that drive the directory tree panel and its YAML store
/// (`docs/use_cases/mcp_file.mdx` §4 – §10, spec in
/// `docs/list_of_files.mdx` §3A.10).
///
/// Every successful mutation is journaled via `MCPAuditLogger` with the
/// new event types (`tool=mcp.add_directory`, `app=directory.walk`,
/// `app=directory.refilter`).
public struct DirectoriesMCPTools: Sendable {

    public let store: DirectoriesStore
    public let logger: MCPAuditLogger
    public let walker: DirectoryTreeWalker

    /// Tool names this subsystem owns. `MCPTools.call` checks membership
    /// and routes here.
    public static let toolNames: Set<String> = [
        "list_directories",
        "get_directory",
        "add_directory",
        "remove_directory",
        "clear_directories",
        "update_directory_filter",
        "set_global_filter",
        "reveal_directory",
        "refresh_directory",
    ]

    public init(
        store: DirectoriesStore = .shared,
        logger: MCPAuditLogger = .shared,
        walker: DirectoryTreeWalker = .shared
    ) {
        self.store = store
        self.logger = logger
        self.walker = walker
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        let filterSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "match": [
                    "type": "string",
                    "enum": ["any", "all"],
                    "description": "'any' (default) ORs the items; 'all' ANDs them.",
                ] as [String: Any],
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["pattern"],
                        "properties": [
                            "pattern": ["type": "string"],
                            "kind": [
                                "type": "string",
                                "enum": ["glob", "substring", "regex"],
                                "description": "Default 'glob' (fnmatch-style: *, ?, [abc]).",
                            ] as [String: Any],
                            "negate": [
                                "type": "boolean",
                                "description": "When true, a match excludes the file.",
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "additionalProperties": false,
        ]

        return [
            .init(
                name: "list_directories",
                description: """
                    Return every root in directories.yaml: path + filter + \
                    last_walked. Used by mcp_file.mdx §9 to verify the empty \
                    state and by external clients to enumerate the panel's \
                    current roots.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_directory",
                description: """
                    Return a single root entry by canonical path. Returns an \
                    error if the path is not a registered root.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "add_directory",
                description: """
                    Append a new root directory to directories.yaml. Triggers \
                    a background walk + recursive FSEventStream watch \
                    (list_of_files.mdx §3A.5.1). Idempotent: if the path is \
                    already a root, returns already_exists=true without \
                    re-writing the file. The optional `filter` argument has \
                    the same shape as the on-disk schema (§3A.2).
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "filter": filterSchema,
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "remove_directory",
                description: """
                    Drop a root entry from directories.yaml, tear down its FS \
                    watcher, and discard its in-memory tree. Does NOT trigger \
                    a walk. See mcp_file.mdx §5.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "clear_directories",
                description: """
                    Remove every root entry. The panel renders its empty \
                    state; the viewer renders 'No image previewed'. See \
                    mcp_file.mdx §9.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["client": ["type": "string"]],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "update_directory_filter",
                description: """
                    Replace the per-root filter on one root. Applied to the \
                    in-memory tree only (§3A.7) — no filesystem walk. See \
                    mcp_file.mdx §7.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "filter": filterSchema,
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["path", "filter"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_global_filter",
                description: """
                    Apply the same filter to every existing root in \
                    directories.yaml. In-memory re-evaluation only \
                    (§3A.7). See mcp_file.mdx §6.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "filter": filterSchema,
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["filter"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "reveal_directory",
                description: """
                    Equivalent to the Directories menu's 'Reveal in Finder'. \
                    Opens the root in Finder. No state change.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "refresh_directory",
                description: """
                    Force a re-walk of one root (when `path` is given) or \
                    every root (when omitted). Resets `last_walked`. \
                    Emits a fresh `app=directory.walk` line per root walked.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        switch name {
        case "list_directories":         return try listDirectories(arguments)
        case "get_directory":            return try getDirectory(arguments)
        case "add_directory":            return try addDirectory(arguments)
        case "remove_directory":         return try removeDirectory(arguments)
        case "clear_directories":        return try clearDirectories(arguments)
        case "update_directory_filter":  return try updateDirectoryFilter(arguments)
        case "set_global_filter":        return try setGlobalFilter(arguments)
        case "reveal_directory":         return try revealDirectory(arguments)
        case "refresh_directory":        return try refreshDirectory(arguments)
        default:
            return .text("Unknown directory tool: \(name)", isError: true)
        }
    }

    // MARK: - Tool implementations

    private func listDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let file = (try? store.load()) ?? DirectoriesFile()
        let body: [String: Any] = [
            "root_directories": file.roots.map(rootJSON),
        ]
        return .text(prettyJSON(body))
    }

    private func getDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let raw = try requireString(args, "path")
        let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
        let file = (try? store.load()) ?? DirectoriesFile()
        guard let r = file.roots.first(where: { $0.path == canonical }) else {
            return .text("Not a registered root: \(canonical.path)", isError: true)
        }
        return .text(prettyJSON(rootJSON(r)))
    }

    private func addDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let raw: String
        do {
            raw = try requireString(args, "path")
        } catch {
            logger.logDirectoryToolCall(
                toolName: "add_directory", path: nil, client: client,
                corr: corr, ok: false, err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }

        // Filter is optional; absent ⇒ empty filter (matches §4.2 prose).
        let filter: RootFilter
        if let rawFilter = args["filter"] as? [String: Any?] {
            do { filter = try parseFilter(rawFilter) } catch let e as DirectoriesStoreError {
                logger.logDirectoryToolCall(
                    toolName: "add_directory", path: raw,
                    client: client, corr: corr, ok: false, err: e.auditCode
                )
                return .text(e.description, isError: true)
            }
        } else {
            filter = .empty
        }

        // Canonicalize + write.
        let canonical: URL
        let already: Bool
        do {
            (canonical, already) = try store.addRoot(path: raw, filter: filter)
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "add_directory", path: raw, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        } catch {
            logger.logDirectoryToolCall(
                toolName: "add_directory", path: raw, client: client,
                corr: corr, ok: false, err: "io"
            )
            return .text("Failed to save directory: \(error.localizedDescription)", isError: true)
        }

        if already {
            logger.logDirectoryToolCall(
                toolName: "add_directory", path: canonical.path, client: client,
                corr: corr, ok: true, extra: [("status", "already_exists")]
            )
            return .text(prettyJSON([
                "path": canonical.path,
                "already_exists": true,
                "corr": corr,
            ] as [String: Any]))
        }

        logger.logDirectoryToolCall(
            toolName: "add_directory", path: canonical.path, client: client,
            corr: corr, ok: true
        )

        // Kick off the walk on a background task. The corr id is forwarded
        // so the eventual `app=directory.walk` line joins back to the MCP
        // request (§4.4).
        walker.scheduleWalk(root: canonical, filter: filter, corr: corr)

        return .text(prettyJSON([
            "path": canonical.path,
            "already_exists": false,
            "corr": corr,
        ] as [String: Any]))
    }

    private func removeDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let raw: String
        do { raw = try requireString(args, "path") } catch {
            logger.logDirectoryToolCall(
                toolName: "remove_directory", path: nil, client: client,
                corr: corr, ok: false, err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }
        let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
        let removed: Bool
        do { removed = try store.removeRoot(path: raw) } catch {
            logger.logDirectoryToolCall(
                toolName: "remove_directory", path: canonical.path, client: client,
                corr: corr, ok: false, err: "io"
            )
            return .text("Failed to remove: \(error)", isError: true)
        }
        // Tear down watcher + drop the in-memory tree even if the path
        // was already gone — the walker treats this as idempotent.
        walker.removeRoot(path: canonical)
        logger.logDirectoryToolCall(
            toolName: "remove_directory", path: canonical.path, client: client,
            corr: corr, ok: true, extra: [("removed", removed ? "true" : "false")]
        )
        return .text(prettyJSON([
            "path": canonical.path,
            "removed": removed,
            "corr": corr,
        ] as [String: Any]))
    }

    private func clearDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let before = ((try? store.load()) ?? DirectoriesFile()).roots
        do { try store.clearAll() } catch {
            logger.logDirectoryToolCall(
                toolName: "clear_directories", path: nil, client: client,
                corr: corr, ok: false, err: "io"
            )
            return .text("Failed to clear: \(error)", isError: true)
        }
        for r in before { walker.removeRoot(path: r.path) }
        logger.logDirectoryToolCall(
            toolName: "clear_directories", path: nil, client: client,
            corr: corr, ok: true, extra: [("removed", String(before.count))]
        )
        return .text(prettyJSON([
            "removed": before.count,
            "corr": corr,
        ] as [String: Any]))
    }

    private func updateDirectoryFilter(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let raw: String
        do { raw = try requireString(args, "path") } catch {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }
        guard let rawFilter = args["filter"] as? [String: Any?] else {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: raw, client: client,
                corr: corr, ok: false, err: "missing_filter"
            )
            return .text("Missing `filter`.", isError: true)
        }
        let filter: RootFilter
        do { filter = try parseFilter(rawFilter) } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: raw, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }
        let ok: Bool
        let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
        do { ok = try store.updateFilter(path: raw, filter: filter) } catch {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: canonical.path, client: client,
                corr: corr, ok: false, err: "io"
            )
            return .text("Failed to update filter: \(error)", isError: true)
        }
        if !ok {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: canonical.path, client: client,
                corr: corr, ok: false, err: "unknown_root"
            )
            return .text("Not a registered root: \(canonical.path)", isError: true)
        }

        // In-memory refilter + audit. §3A.7 — no re-walk.
        let walkStart = Date()
        let delta = walker.refilter(root: canonical, filter: filter)
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)
        logger.logDirectoryToolCall(
            toolName: "update_directory_filter", path: canonical.path, client: client,
            corr: corr, ok: true,
            extra: [
                ("items", String(filter.items.count)),
                ("negate_items", String(filter.negateCount)),
            ]
        )
        logger.logDirectoryRefilter(
            roots: 1, visibleDelta: delta, elapsedMs: elapsedMs, corr: corr
        )
        return .text(prettyJSON([
            "path": canonical.path,
            "items": filter.items.count,
            "negate_items": filter.negateCount,
            "visible_delta": delta,
            "corr": corr,
        ] as [String: Any]))
    }

    private func setGlobalFilter(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        guard let rawFilter = args["filter"] as? [String: Any?] else {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: false, err: "missing_filter"
            )
            return .text("Missing `filter`.", isError: true)
        }
        let filter: RootFilter
        do { filter = try parseFilter(rawFilter) } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }
        let n: Int
        do { n = try store.setGlobalFilter(filter) } catch {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: false, err: "io"
            )
            return .text("Failed to set global filter: \(error)", isError: true)
        }
        let walkStart = Date()
        let delta = walker.refilterAll(filter: filter)
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)
        logger.logDirectoryToolCall(
            toolName: "set_global_filter", path: nil, client: client,
            corr: corr, ok: true, extra: [("items", String(filter.items.count))]
        )
        logger.logDirectoryRefilter(
            roots: n, visibleDelta: delta, elapsedMs: elapsedMs, corr: corr
        )
        return .text(prettyJSON([
            "roots": n,
            "items": filter.items.count,
            "visible_delta": delta,
            "corr": corr,
        ] as [String: Any]))
    }

    private func revealDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let raw: String
        do { raw = try requireString(args, "path") } catch {
            logger.logDirectoryToolCall(
                toolName: "reveal_directory", path: nil, client: "claude-code",
                corr: corr, ok: false, err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }
        let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
        // Best-effort: write a `reveal.txt` hint file the GUI watches so
        // the actual NSWorkspace call happens on the main actor (avoids an
        // AppKit dependency in the core module).
        try? AppPaths.ensureMacDirectories()
        let hint = AppPaths.macAppSupportDir.appendingPathComponent("reveal.txt")
        try? canonical.path.data(using: .utf8)?.write(to: hint, options: .atomic)
        logger.logDirectoryToolCall(
            toolName: "reveal_directory", path: canonical.path, client: "claude-code",
            corr: corr, ok: true
        )
        return .text(prettyJSON([
            "path": canonical.path,
            "corr": corr,
        ] as [String: Any]))
    }

    private func refreshDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let file = (try? store.load()) ?? DirectoriesFile()
        let targets: [RootDirectory]
        if let raw = args["path"] as? String, !raw.isEmpty {
            let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
            guard let r = file.roots.first(where: { $0.path == canonical }) else {
                logger.logDirectoryToolCall(
                    toolName: "refresh_directory", path: canonical.path, client: client,
                    corr: corr, ok: false, err: "unknown_root"
                )
                return .text("Not a registered root: \(canonical.path)", isError: true)
            }
            targets = [r]
        } else {
            targets = file.roots
        }
        for r in targets {
            walker.scheduleWalk(root: r.path, filter: r.filter, corr: corr)
        }
        logger.logDirectoryToolCall(
            toolName: "refresh_directory",
            path: targets.count == 1 ? targets.first!.path.path : nil,
            client: client, corr: corr, ok: true,
            extra: [("roots", String(targets.count))]
        )
        return .text(prettyJSON([
            "roots": targets.count,
            "corr": corr,
        ] as [String: Any]))
    }

    // MARK: - Helpers

    private func rootJSON(_ r: RootDirectory) -> [String: Any] {
        var items: [[String: Any]] = []
        for it in r.filter.items {
            var d: [String: Any] = ["pattern": it.pattern]
            if it.kind != .glob { d["kind"] = it.kind.rawValue }
            if it.negate { d["negate"] = true }
            items.append(d)
        }
        var filter: [String: Any] = ["items": items]
        if r.filter.match != .any { filter["match"] = r.filter.match.rawValue }
        var dict: [String: Any] = [
            "path": r.path.path,
            "filter": filter,
        ]
        if let walked = r.lastWalked {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            dict["last_walked"] = f.string(from: walked)
        }
        return dict
    }

    /// Parse the on-wire filter shape into a `RootFilter`. Throws
    /// `DirectoriesStoreError.invalidFilter` (or one of its more specific
    /// siblings — `invalidRegex`, `pathSeparatorInPattern`) on bad input.
    ///
    /// Pattern normalization at the MCP boundary
    /// (`docs/use_cases/mcp_file.mdx` §10B.1):
    ///
    /// * A leading `.../` is stripped — it conveys "anywhere under the
    ///   root, at any depth," which is already the engine's default.
    ///   The `.../` shorthand never reaches `directories.yaml`.
    /// * After stripping, a remaining `/` in the pattern is a
    ///   filename-vs-path-matching mismatch (§10B.8). v1 supports
    ///   filename matching only, so any leftover `/` triggers
    ///   `pathSeparatorInPattern`.
    /// * `kind: regex` patterns are eagerly compiled so a syntactically
    ///   invalid regex surfaces as `invalid_regex` at MCP-call time
    ///   instead of silently dropping every file at evaluate-time.
    public static func parseFilterDict(_ raw: [String: Any?]) throws -> RootFilter {
        var filter = RootFilter()
        if let m = raw["match"] as? String {
            if let parsed = RootFilter.Match(rawValue: m) {
                filter.match = parsed
            } else {
                throw DirectoriesStoreError.invalidFilter("unknown match=\(m)")
            }
        }
        guard let rawItems = raw["items"] as? [Any?] else {
            // `items` may be absent for an empty filter.
            return filter
        }
        var items: [RootFilterItem] = []
        for entry in rawItems {
            guard let dict = entry as? [String: Any?] else {
                throw DirectoriesStoreError.invalidFilter("item is not an object")
            }
            guard let rawPattern = dict["pattern"] as? String, !rawPattern.isEmpty else {
                throw DirectoriesStoreError.invalidFilter("item missing `pattern`")
            }
            var kind: RootFilterItem.ItemKind = .glob
            if let k = dict["kind"] as? String {
                guard let parsed = RootFilterItem.ItemKind(rawValue: k) else {
                    throw DirectoriesStoreError.invalidFilter("unknown kind=\(k)")
                }
                kind = parsed
            }
            let negate = (dict["negate"] as? Bool) ?? false
            let pattern = try Self.normalizePattern(rawPattern, kind: kind)
            items.append(RootFilterItem(pattern: pattern, kind: kind, negate: negate))
        }
        filter.items = items
        return filter
    }

    /// Apply the §10B.1 boundary normalization to a single pattern.
    /// Exposed `internal` for direct test coverage.
    ///
    /// Steps, in order:
    ///   1. Strip every leading `.../` ("anywhere under the root"
    ///      shorthand — implicit, never stored).
    ///   2. Reject any remaining unescaped `/` separator with
    ///      `pathSeparatorInPattern` (v1 filenames-only — §10B.8).
    ///   3. Eagerly compile `kind: regex` patterns so bad syntax
    ///      surfaces as `invalidRegex` here, not at evaluate-time.
    static func normalizePattern(_ raw: String, kind: RootFilterItem.ItemKind) throws -> String {
        var p = raw
        while p.hasPrefix(".../") {
            p.removeFirst(4)
        }
        if Self.containsUnescapedSlash(p) {
            throw DirectoriesStoreError.pathSeparatorInPattern(raw)
        }
        if kind == .regex {
            do {
                _ = try NSRegularExpression(pattern: p)
            } catch {
                throw DirectoriesStoreError.invalidRegex(
                    pattern: p,
                    reason: String(describing: error)
                )
            }
        }
        return p
    }

    private static func containsUnescapedSlash(_ s: String) -> Bool {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                i = s.index(after: i)
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            if c == "/" { return true }
            i = s.index(after: i)
        }
        return false
    }

    private func parseFilter(_ raw: [String: Any?]) throws -> RootFilter {
        try Self.parseFilterDict(raw)
    }

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let raw = args[key], let v = raw as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return Self.normalizeJSON(s)
        }
        return "{}"
    }

    /// `JSONSerialization` always escapes forward slashes (`\/`) and
    /// renders empty arrays/objects with whitespace inside (`[\n\n  ]`).
    /// The mcp_file.mdx verify steps and audit log entries show plain
    /// `/` and `[]`, so normalize the output to that form. (JSONEncoder
    /// has `withoutEscapingSlashes` but the payloads here are dynamic
    /// `[String: Any]`, not Codable, so post-processing the string is
    /// the simplest faithful path.)
    static func normalizeJSON(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\/", with: "/")
        out = out.replacingOccurrences(
            of: #"\[\s*\]"#, with: "[]", options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\{\s*\}"#, with: "{}", options: .regularExpression
        )
        return out
    }
}
