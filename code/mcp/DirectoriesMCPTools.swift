import Foundation

/// MCP tools that drive the directory tree panel and its YAML store
/// (`docs/use_cases/mcp_file.mdx` §4 – §10, spec in
/// `docs/list_of_files.mdx` §3A.10).
///
/// Every successful mutation is journaled via `MCPAuditLogger` with the
/// new event types (`tool=mcp.add_directory`, `app=directory.walk`,
/// `app=directory.refilter`).
public struct DirectoriesMCPTools: Sendable {

    /// Optional explicit store, used by tests to inject an isolated
    /// `DirectoriesStore`. Production callers pass nil so that
    /// `store` resolves to `DirectoriesStore.shared` at every call —
    /// which the multi-window resolver (multi_window.mdx §6) routes
    /// to the frontmost window's per-window store.
    public let injectedStore: DirectoriesStore?

    /// The store every tool method routes mutations through. When an
    /// explicit store was injected at init time it is used unchanged;
    /// otherwise `DirectoriesStore.shared` is resolved at access
    /// time so multi-window retargeting takes effect.
    public var store: DirectoriesStore {
        injectedStore ?? .shared
    }

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
        // `mcp_and_filters_on_dirs.mdx` §4.1 — per-item tools that let
        // voice intents like "also exclude _WIP_" land as a single
        // append rather than re-issuing the whole filter.
        "add_filter_item",
        "remove_filter_item",
        "list_filter_items",
        // §6 — hide-empty-directories UI preference.
        "set_hide_empty_directories",
        "get_hide_empty_directories",
    ]

    public init(
        store: DirectoriesStore? = nil,
        logger: MCPAuditLogger = .shared,
        walker: DirectoryTreeWalker = .shared
    ) {
        self.injectedStore = store
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
                            "priority": [
                                "type": "integer",
                                "description": "Priority tier; higher wins (mcp_and_filters_on_dirs.mdx §3). Default 0. Use 10 for a single-step override.",
                                "minimum": -1000,
                                "maximum": 1000,
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
                    Replace the per-root filter. Either supply legacy \
                    `path` (one root) or new `targets` (mcp_and_filters_on_dirs.mdx \
                    §4.3): "all" / single path / array of paths. The two \
                    forms are mutually exclusive — sending both returns \
                    err=conflicting_arguments. In-memory re-evaluation \
                    only (list_of_files.mdx §3A.7) — no filesystem walk.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path":   ["type": "string"],
                        "targets": [
                            "description": "'all', a single absolute path, or an array of absolute paths.",
                        ] as [String: Any],
                        "filter": filterSchema,
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["filter"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_global_filter",
                description: """
                    Apply the same filter to every existing root (legacy), \
                    or — when `targets` (mcp_and_filters_on_dirs.mdx §4.3) \
                    is supplied — to just those roots. In-memory \
                    re-evaluation only (§3A.7). See mcp_file.mdx §6.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "filter": filterSchema,
                        "targets": [
                            "description": "Optional. 'all' (default), single path, or array of paths.",
                        ] as [String: Any],
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
            .init(
                name: "add_filter_item",
                description: """
                    APPEND one filter item to the targeted root(s) without \
                    clobbering existing items. `targets` is "all" (every \
                    root, default), a single canonical path, or an array \
                    of paths. Use this for voice "also exclude X" / \
                    "always keep Y" intents. See \
                    mcp_and_filters_on_dirs.mdx §4.2 / §5B / §5C. \
                    Idempotent: an identical (pattern + kind + negate + \
                    priority) item is not duplicated.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "targets": [
                            "description": "'all', a single absolute path, or an array of absolute paths.",
                        ] as [String: Any],
                        "item": [
                            "type": "object",
                            "required": ["pattern"],
                            "properties": [
                                "pattern":  ["type": "string"],
                                "kind": [
                                    "type": "string",
                                    "enum": ["glob", "substring", "regex"],
                                ] as [String: Any],
                                "negate":   ["type": "boolean"],
                                "priority": [
                                    "type": "integer",
                                    "minimum": -1000,
                                    "maximum": 1000,
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["item"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "list_filter_items",
                description: """
                    Return the filter items currently in effect, grouped \
                    by root and sorted highest-priority-first. Each item \
                    carries its derived 6-char `id` (§4.5) so a follow-up \
                    `remove_filter_item` can target it unambiguously. \
                    `targets` defaults to "all" (every root). See \
                    mcp_and_filters_on_dirs.mdx §4.2 / §5E.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "targets": [
                            "description": "'all', a single absolute path, or an array of absolute paths.",
                        ] as [String: Any],
                    ] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "remove_filter_item",
                description: """
                    REMOVE filter items matching the criterion from the \
                    targeted root(s). `match` accepts one of `id` (exact \
                    match against the §4.5 derived id), `pattern` (exact \
                    pattern string), or `regex` (regex over each item's \
                    pattern). `targets` is "all" (default), a single \
                    canonical path, or an array of paths. Atomic across \
                    targets (§4.6). See mcp_and_filters_on_dirs.mdx §4.2 / \
                    §5D.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "targets": [
                            "description": "'all', a single absolute path, or an array of absolute paths.",
                        ] as [String: Any],
                        "match": [
                            "type": "object",
                            "description": "Exactly one of `id`, `pattern`, or `regex` must be supplied.",
                            "properties": [
                                "id":      ["type": "string"],
                                "pattern": ["type": "string"],
                                "regex":   ["type": "string"],
                            ] as [String: Any],
                        ] as [String: Any],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["match"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_hide_empty_directories",
                description: """
                    Toggle the panel's "Hide Empty Directories" UI \
                    preference (mcp_and_filters_on_dirs.mdx §6). When \
                    enabled, directory rows whose recursive descendants \
                    contain zero `passesFilter == true` files are skipped \
                    in the tree view. Root rows always render. The \
                    preference is stored in a plain-text flag file under \
                    the app-support dir and synced to the running app via \
                    the same Darwin notification + kqueue path used by \
                    `directories.yaml`.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"],
                        "client":  ["type": "string"],
                    ] as [String: Any],
                    "required": ["enabled"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_hide_empty_directories",
                description: """
                    Read the current `hide_empty_directories` preference. \
                    Returns `{ enabled: true|false }`.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
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
        case "add_filter_item":          return try addFilterItem(arguments)
        case "remove_filter_item":       return try removeFilterItem(arguments)
        case "list_filter_items":        return try listFilterItems(arguments)
        case "set_hide_empty_directories":  return try setHideEmptyDirectories(arguments)
        case "get_hide_empty_directories":  return try getHideEmptyDirectories(arguments)
        default:
            return .text("Unknown directory tool: \(name)", isError: true)
        }
    }

    // MARK: - Tool implementations

    private func listDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.list_directories")
        defer { _trace.finish() }
        let file = (try? store.load()) ?? DirectoriesFile()
        let body: [String: Any] = [
            "root_directories": file.roots.map(rootJSON),
        ]
        return .text(prettyJSON(body))
    }

    private func getDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.get_directory")
        defer { _trace.finish() }
        let raw = try requireString(args, "path")
        let canonical = try DirectoriesStore.canonicalize(raw, mustExist: false)
        let file = (try? store.load()) ?? DirectoriesFile()
        guard let r = file.roots.first(where: { $0.path == canonical }) else {
            return .text("Not a registered root: \(canonical.path)", isError: true)
        }
        return .text(prettyJSON(rootJSON(r)))
    }

    private func addDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.add_directory",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
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
                "app_running": appIsRunning(),
                "corr": corr,
            ] as [String: Any]))
        }

        logger.logDirectoryToolCall(
            toolName: "add_directory", path: canonical.path, client: client,
            corr: corr, ok: true
        )

        // Notify the running desktop app immediately via a Darwin distributed
        // notification. The kqueue FileWatcher in AppState is the fallback;
        // this is the fast path (no 250 ms debounce). The MCP server's own
        // walker.scheduleWalk() was removed — that walked in the MCP process's
        // memory and never reached the desktop app. The desktop app's own
        // DirectoryTreeWalker picks up the new root from directories.yaml when
        // it receives this notification (or the kqueue event).
        postDirectoriesChanged()

        return .text(prettyJSON([
            "path": canonical.path,
            "already_exists": false,
            "app_running": appIsRunning(),
            "corr": corr,
        ] as [String: Any]))
    }

    private func removeDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.remove_directory",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
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
        walker.removeRoot(path: canonical)
        logger.logDirectoryToolCall(
            toolName: "remove_directory", path: canonical.path, client: client,
            corr: corr, ok: true, extra: [("removed", removed ? "true" : "false")]
        )
        postDirectoriesChanged()
        return .text(prettyJSON([
            "path": canonical.path,
            "removed": removed,
            "app_running": appIsRunning(),
            "corr": corr,
        ] as [String: Any]))
    }

    private func clearDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.clear_directories",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
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
        postDirectoriesChanged()
        return .text(prettyJSON([
            "removed": before.count,
            "app_running": appIsRunning(),
            "corr": corr,
        ] as [String: Any]))
    }

    private func updateDirectoryFilter(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.update_directory_filter",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()

        // Spec §4.3: mixing legacy `path` and new `targets` is a hard
        // error so the LLM can't get surprising behavior from a half-
        // migrated payload. Either one is fine on its own.
        let hasPath    = (args["path"]    as? String).map { !$0.isEmpty } ?? false
        let hasTargets = args["targets"] != nil
        if hasPath && hasTargets {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: "conflicting_arguments"
            )
            return .text(
                "`path` and `targets` are mutually exclusive (§4.3).",
                isError: true
            )
        }
        if !hasPath && !hasTargets {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: "missing_path"
            )
            return .text(
                "Either `path` or `targets` is required.", isError: true
            )
        }

        guard let rawFilter = args["filter"] as? [String: Any?] else {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: "missing_filter"
            )
            return .text("Missing `filter`.", isError: true)
        }
        let filter: RootFilter
        do { filter = try parseFilter(rawFilter) } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }

        // Resolve the targeted roots. Legacy `path` is rewritten as
        // a single-target call so the rest of the dispatch is uniform.
        var file = (try? store.load()) ?? DirectoriesFile()
        let targets: [URL]
        do {
            if hasPath {
                let canonical = try DirectoriesStore.canonicalize(
                    args["path"] as! String, mustExist: false
                )
                guard file.roots.contains(where: { $0.path == canonical }) else {
                    logger.logDirectoryToolCall(
                        toolName: "update_directory_filter",
                        path: canonical.path, client: client,
                        corr: corr, ok: false, err: "unknown_root"
                    )
                    return .text("Not a registered root: \(canonical.path)", isError: true)
                }
                targets = [canonical]
            } else {
                targets = try resolveTargets(args["targets"] as Any?, file: file)
            }
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }

        if targets.isEmpty {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: true, extra: [("status", "no_roots")]
            )
            return .text(prettyJSON([
                "ok": true,
                "corr": corr,
                "app_running": appIsRunning(),
                "targets_applied": [] as [String],
                "items": filter.items.count,
                "visible_delta": 0,
            ] as [String: Any]))
        }

        // Apply the filter to every targeted root, save once
        // (atomic — §4.6), then refilter each.
        for url in targets {
            guard let idx = file.roots.firstIndex(where: { $0.path == url }) else {
                logger.logDirectoryToolCall(
                    toolName: "update_directory_filter",
                    path: url.path, client: client,
                    corr: corr, ok: false, err: "unknown_root"
                )
                return .text("Not a registered root: \(url.path)", isError: true)
            }
            file.roots[idx].filter = filter
        }
        do { try store.save(file) } catch {
            logger.logDirectoryToolCall(
                toolName: "update_directory_filter", path: nil, client: client,
                corr: corr, ok: false, err: "storage_write_failed"
            )
            return .text("Failed to save filter: \(error)", isError: true)
        }

        let walkStart = Date()
        var totalDelta = 0
        for url in targets {
            totalDelta += walker.refilter(root: url, filter: filter)
        }
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)

        logger.logDirectoryToolCall(
            toolName: "update_directory_filter",
            path: targets.count == 1 ? targets[0].path : nil, client: client,
            corr: corr, ok: true,
            extra: [
                ("items", String(filter.items.count)),
                ("negate_items", String(filter.negateCount)),
                ("roots", String(targets.count)),
            ]
        )
        logger.logDirectoryRefilter(
            roots: targets.count, visibleDelta: totalDelta,
            elapsedMs: elapsedMs, corr: corr
        )
        postDirectoriesChanged()
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "app_running": appIsRunning(),
            "targets_applied": targets.map { $0.path },
            "items": filter.items.count,
            "negate_items": filter.negateCount,
            "visible_delta": totalDelta,
        ] as [String: Any]))
    }

    private func setGlobalFilter(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.set_global_filter",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
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

        // Spec §4.3: legacy `set_global_filter()` without targets ⇒
        // every root. With targets ⇒ narrow to those. We never accept
        // both `targets` and (the absence of `targets`); that
        // combinatoric does not exist on this tool.
        var file = (try? store.load()) ?? DirectoriesFile()
        let targets: [URL]
        do {
            targets = try resolveTargets(args["targets"] as Any?, file: file)
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }

        if targets.isEmpty {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: true, extra: [("status", "no_roots")]
            )
            return .text(prettyJSON([
                "ok": true,
                "corr": corr,
                "app_running": appIsRunning(),
                "targets_applied": [] as [String],
                "items": filter.items.count,
                "visible_delta": 0,
            ] as [String: Any]))
        }

        // Apply to every targeted root + save once (atomic — §4.6).
        for url in targets {
            guard let idx = file.roots.firstIndex(where: { $0.path == url }) else {
                logger.logDirectoryToolCall(
                    toolName: "set_global_filter", path: url.path,
                    client: client, corr: corr, ok: false, err: "unknown_root"
                )
                return .text("Not a registered root: \(url.path)", isError: true)
            }
            file.roots[idx].filter = filter
        }
        do { try store.save(file) } catch {
            logger.logDirectoryToolCall(
                toolName: "set_global_filter", path: nil, client: client,
                corr: corr, ok: false, err: "storage_write_failed"
            )
            return .text("Failed to set global filter: \(error)", isError: true)
        }

        let walkStart = Date()
        var totalDelta = 0
        for url in targets {
            totalDelta += walker.refilter(root: url, filter: filter)
        }
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)

        logger.logDirectoryToolCall(
            toolName: "set_global_filter", path: nil, client: client,
            corr: corr, ok: true,
            extra: [
                ("items", String(filter.items.count)),
                ("roots", String(targets.count)),
            ]
        )
        logger.logDirectoryRefilter(
            roots: targets.count, visibleDelta: totalDelta,
            elapsedMs: elapsedMs, corr: corr
        )
        postDirectoriesChanged()
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "app_running": appIsRunning(),
            "targets_applied": targets.map { $0.path },
            "items": filter.items.count,
            "visible_delta": totalDelta,
        ] as [String: Any]))
    }

    private func revealDirectory(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.reveal_directory")
        defer { _trace.finish() }
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
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.refresh_directory",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
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
        postDirectoriesChanged()
        logger.logDirectoryToolCall(
            toolName: "refresh_directory",
            path: targets.count == 1 ? targets.first!.path.path : nil,
            client: client, corr: corr, ok: true,
            extra: [("roots", String(targets.count))]
        )
        return .text(prettyJSON([
            "roots": targets.count,
            "app_running": appIsRunning(),
            "corr": corr,
        ] as [String: Any]))
    }

    // MARK: - Helpers

    private func rootJSON(_ r: RootDirectory) -> [String: Any] {
        var items: [[String: Any]] = []
        for it in r.filter.items {
            // `id` is always included in the JSON projection (spec
            // §4.5) so the LLM has a stable handle for follow-up
            // `remove_filter_item(match: { id })` calls.
            var d: [String: Any] = [
                "id":      it.id,
                "pattern": it.pattern,
            ]
            if it.kind != .glob { d["kind"] = it.kind.rawValue }
            if it.negate { d["negate"] = true }
            // mcp_and_filters_on_dirs.mdx §3.6 — non-default priority
            // is surfaced on read; default 0 is omitted to keep the
            // JSON payload small for the common case.
            if it.priority != 0 { d["priority"] = it.priority }
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

    // MARK: - targets resolver (mcp_and_filters_on_dirs.mdx §4.3)

    /// Resolve the `targets` argument to a list of canonical root URLs
    /// from `directories.yaml`. The three accepted shapes are:
    ///   * `"all"` (or absent) → every root in the file.
    ///   * String → exactly one root, canonicalized via
    ///     `DirectoriesStore.canonicalize`. Must be a registered root.
    ///   * Array of strings → each canonicalized; every entry must be
    ///     a registered root. Per §4.6, partial application is not
    ///     allowed — any unknown root fails the whole call.
    ///
    /// Throws `DirectoriesStoreError.pathNotFound(path)` for unknown
    /// roots so the dispatching tool can log `err=unknown_root`.
    private func resolveTargets(_ raw: Any?, file: DirectoriesFile) throws -> [URL] {
        let allRoots = file.roots.map { $0.path }
        guard let raw = raw else { return allRoots }

        if let s = raw as? String {
            if s == "all" { return allRoots }
            let canonical = try DirectoriesStore.canonicalize(s, mustExist: false)
            guard allRoots.contains(canonical) else {
                throw DirectoriesStoreError.pathNotFound(canonical.path)
            }
            return [canonical]
        }
        if let arr = raw as? [Any?] {
            var out: [URL] = []
            for entry in arr {
                guard let p = entry as? String, !p.isEmpty else {
                    throw DirectoriesStoreError.invalidFilter(
                        "targets array entry is not a non-empty string"
                    )
                }
                let canonical = try DirectoriesStore.canonicalize(p, mustExist: false)
                guard allRoots.contains(canonical) else {
                    throw DirectoriesStoreError.pathNotFound(canonical.path)
                }
                out.append(canonical)
            }
            return out
        }
        if let arr = raw as? [String] {
            var out: [URL] = []
            for p in arr {
                let canonical = try DirectoriesStore.canonicalize(p, mustExist: false)
                guard allRoots.contains(canonical) else {
                    throw DirectoriesStoreError.pathNotFound(canonical.path)
                }
                out.append(canonical)
            }
            return out
        }
        throw DirectoriesStoreError.invalidFilter(
            "`targets` must be 'all', a path string, or an array of paths"
        )
    }

    // MARK: - add_filter_item / list_filter_items
    // (mcp_and_filters_on_dirs.mdx §4.1 / §4.2 / §5)

    private func addFilterItem(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.add_filter_item",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()

        guard let rawItem = args["item"] as? [String: Any?] else {
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "missing_item"
            )
            return .text("Missing `item`.", isError: true)
        }

        // Parse the single item by wrapping it in a single-element
        // filter and re-using parseFilterDict's validation +
        // normalization. This routes invalid_regex /
        // path_separator_in_pattern uniformly with the bulk tools.
        let parsed: RootFilter
        do {
            parsed = try Self.parseFilterDict([
                "items": [rawItem] as Any
            ])
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }
        guard let newItem = parsed.items.first else {
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "invalid_filter"
            )
            return .text("Item parse produced zero items.", isError: true)
        }

        var file = (try? store.load()) ?? DirectoriesFile()
        let targets: [URL]
        do {
            targets = try resolveTargets(args["targets"] as Any?, file: file)
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }

        if targets.isEmpty {
            // `targets: "all"` against an empty directories.yaml — the
            // call succeeds as a no-op so the LLM's response can say
            // "no roots yet — add one with add_directory first."
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: true,
                extra: [("status", "no_roots")]
            )
            return .text(prettyJSON([
                "ok": true,
                "corr": corr,
                "app_running": appIsRunning(),
                "targets_applied": [] as [String],
                "items_added": 0,
            ] as [String: Any]))
        }

        // Atomic across roots (§4.6): build the new file, then save once.
        var itemsAddedPerRoot: [Int] = []
        for url in targets {
            guard let idx = file.roots.firstIndex(where: { $0.path == url }) else {
                logger.logDirectoryToolCall(
                    toolName: "add_filter_item", path: url.path, client: client,
                    corr: corr, ok: false, err: "unknown_root"
                )
                return .text("Not a registered root: \(url.path)", isError: true)
            }
            if file.roots[idx].filter.items.contains(where: { sameItem($0, newItem) }) {
                itemsAddedPerRoot.append(0)
                continue
            }
            file.roots[idx].filter.items.append(newItem)
            itemsAddedPerRoot.append(1)
        }
        do { try store.save(file) } catch {
            logger.logDirectoryToolCall(
                toolName: "add_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "storage_write_failed"
            )
            return .text("Failed to save filter item: \(error)", isError: true)
        }

        // Refilter each affected root in memory. The desktop app's
        // watcher will pick the YAML change up too, but a same-process
        // call (tests, embedded use) needs the in-memory tree updated
        // here. The walker is a no-op when the root isn't loaded.
        var totalDelta = 0
        for (i, url) in targets.enumerated() where itemsAddedPerRoot[i] > 0 {
            let f = file.roots.first(where: { $0.path == url })?.filter ?? .empty
            totalDelta += walker.refilter(root: url, filter: f)
        }

        let totalAdded = itemsAddedPerRoot.reduce(0, +)
        logger.logDirectoryToolCall(
            toolName: "add_filter_item",
            path: targets.count == 1 ? targets[0].path : nil,
            client: client, corr: corr, ok: true,
            extra: [
                ("targets", targets.count == 1 ? targets[0].path : "\(targets.count)"),
                ("items_added", String(totalAdded)),
                ("negate", newItem.negate ? "true" : "false"),
                ("priority", String(newItem.priority)),
            ]
        )
        if totalAdded > 0 {
            logger.logDirectoryRefilter(
                roots: targets.count, visibleDelta: totalDelta,
                elapsedMs: 0, corr: corr
            )
        }
        postDirectoriesChanged()
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "app_running": appIsRunning(),
            "targets_applied": targets.map { $0.path },
            "items_added": totalAdded,
            "visible_delta": totalDelta,
        ] as [String: Any]))
    }

    private func listFilterItems(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.list_filter_items")
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        let file = (try? store.load()) ?? DirectoriesFile()
        let targets: [URL]
        do {
            targets = try resolveTargets(args["targets"] as Any?, file: file)
        } catch let e as DirectoriesStoreError {
            return .text(e.description, isError: true)
        }

        var itemsByRoot: [String: [[String: Any]]] = [:]
        for url in targets {
            guard let r = file.roots.first(where: { $0.path == url }) else { continue }
            // Sort highest-priority-first for LLM convenience
            // (mcp_and_filters_on_dirs.mdx §4.2 — list_filter_items).
            let sorted = r.filter.items.sorted(by: { $0.priority > $1.priority })
            itemsByRoot[r.path.path] = sorted.map { it in
                // Spec §4.5 — every item carries its derived id so a
                // follow-up `remove_filter_item(match: { id })` can
                // pick it out unambiguously.
                var d: [String: Any] = [
                    "id":      it.id,
                    "pattern": it.pattern,
                ]
                if it.kind != .glob { d["kind"] = it.kind.rawValue }
                if it.negate { d["negate"] = true }
                if it.priority != 0 { d["priority"] = it.priority }
                return d
            }
        }
        // Log read-only call too so the audit chain captures the LLM's
        // "what's in scope?" calls alongside its mutations.
        logger.logDirectoryToolCall(
            toolName: "list_filter_items", path: nil, client: "claude-code",
            corr: corr, ok: true,
            extra: [("roots", String(targets.count))]
        )
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "items_by_root": itemsByRoot,
        ] as [String: Any]))
    }

    /// Equality of two filter items for the §4.2 "idempotent" guarantee.
    /// Two items are the same if their `pattern`, `kind`, `negate`, and
    /// `priority` are all equal.
    private func sameItem(_ a: RootFilterItem, _ b: RootFilterItem) -> Bool {
        a.pattern == b.pattern
            && a.kind == b.kind
            && a.negate == b.negate
            && a.priority == b.priority
    }

    // MARK: - remove_filter_item (mcp_and_filters_on_dirs.mdx §4.2 / §5D)

    private func removeFilterItem(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.remove_filter_item",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()

        guard let rawMatch = args["match"] as? [String: Any?] else {
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "missing_match"
            )
            return .text("Missing `match`.", isError: true)
        }

        // Build the predicate. Exactly one of id / pattern / regex
        // must be supplied (spec §4.2). We validate exclusivity
        // strictly so an LLM that sends both can't get surprising
        // behavior.
        let idMatch     = rawMatch["id"]      as? String
        let patternMatch = rawMatch["pattern"] as? String
        let regexMatch  = rawMatch["regex"]   as? String
        let supplied    = [idMatch, patternMatch, regexMatch].compactMap { $0 }
        if supplied.count != 1 {
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "invalid_match"
            )
            return .text(
                "`match` must contain exactly one of `id`, `pattern`, or `regex`.",
                isError: true
            )
        }

        // Pre-compile the regex when that's the discriminator so the
        // failure shape matches `add_filter_item` (err=invalid_regex).
        var compiledRegex: NSRegularExpression?
        if let rx = regexMatch {
            do { compiledRegex = try NSRegularExpression(pattern: rx) }
            catch {
                logger.logDirectoryToolCall(
                    toolName: "remove_filter_item", path: nil, client: client,
                    corr: corr, ok: false, err: "invalid_regex"
                )
                return .text(
                    "Invalid match regex \"\(rx)\": \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        var file = (try? store.load()) ?? DirectoriesFile()
        let targets: [URL]
        do {
            targets = try resolveTargets(args["targets"] as Any?, file: file)
        } catch let e as DirectoriesStoreError {
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: e.auditCode
            )
            return .text(e.description, isError: true)
        }

        if targets.isEmpty {
            // `targets: "all"` against an empty directories.yaml ⇒
            // nothing to do. Same response shape as add_filter_item.
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item", path: nil, client: client,
                corr: corr, ok: true, extra: [("status", "no_roots")]
            )
            return .text(prettyJSON([
                "ok": true,
                "corr": corr,
                "app_running": appIsRunning(),
                "targets_applied": [] as [String],
                "items_removed": 0,
            ] as [String: Any]))
        }

        // Build the predicate as a closure so the same logic applies
        // across every target. Each branch is one of id, pattern,
        // regex — exactly one is non-nil per the validation above.
        let predicate: (RootFilterItem) -> Bool = { item in
            if let id = idMatch        { return item.id == id }
            if let p  = patternMatch   { return item.pattern == p }
            if let re = compiledRegex {
                let range = NSRange(item.pattern.startIndex..<item.pattern.endIndex,
                                    in: item.pattern)
                return re.firstMatch(in: item.pattern, range: range) != nil
            }
            return false
        }

        var perRootRemoved: [Int] = []
        var rootsTouched: [URL] = []
        for url in targets {
            guard let idx = file.roots.firstIndex(where: { $0.path == url }) else {
                logger.logDirectoryToolCall(
                    toolName: "remove_filter_item", path: url.path,
                    client: client, corr: corr, ok: false, err: "unknown_root"
                )
                return .text("Not a registered root: \(url.path)", isError: true)
            }
            let before = file.roots[idx].filter.items.count
            file.roots[idx].filter.items.removeAll(where: predicate)
            let removed = before - file.roots[idx].filter.items.count
            perRootRemoved.append(removed)
            if removed > 0 { rootsTouched.append(url) }
        }
        let totalRemoved = perRootRemoved.reduce(0, +)
        if totalRemoved == 0 {
            // Pure no-op — no YAML write, no refilter, no
            // notification. The LLM still gets a clean ok=true so it
            // can say "nothing matched."
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item",
                path: targets.count == 1 ? targets[0].path : nil,
                client: client, corr: corr, ok: true,
                extra: [
                    ("items_removed", "0"),
                    ("status", "no_match"),
                ]
            )
            return .text(prettyJSON([
                "ok": true,
                "corr": corr,
                "app_running": appIsRunning(),
                "targets_applied": targets.map { $0.path },
                "items_removed": 0,
            ] as [String: Any]))
        }

        do { try store.save(file) } catch {
            logger.logDirectoryToolCall(
                toolName: "remove_filter_item", path: nil, client: client,
                corr: corr, ok: false, err: "storage_write_failed"
            )
            return .text("Failed to save filter: \(error)", isError: true)
        }

        var visibleDelta = 0
        for url in rootsTouched {
            let f = file.roots.first(where: { $0.path == url })?.filter ?? .empty
            visibleDelta += walker.refilter(root: url, filter: f)
        }

        logger.logDirectoryToolCall(
            toolName: "remove_filter_item",
            path: targets.count == 1 ? targets[0].path : nil,
            client: client, corr: corr, ok: true,
            extra: [
                ("targets", targets.count == 1 ? targets[0].path : "\(targets.count)"),
                ("items_removed", String(totalRemoved)),
                ("roots_touched", String(rootsTouched.count)),
            ]
        )
        logger.logDirectoryRefilter(
            roots: rootsTouched.count, visibleDelta: visibleDelta,
            elapsedMs: 0, corr: corr
        )
        postDirectoriesChanged()
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "app_running": appIsRunning(),
            "targets_applied": targets.map { $0.path },
            "items_removed": totalRemoved,
            "visible_delta": visibleDelta,
        ] as [String: Any]))
    }

    // MARK: - hide_empty_directories prefs (§6)

    /// Path to the plain-text flag file the preference is stored in.
    /// One line, literal "true" or "false". Lives in
    /// `~/Library/Application Support/ImageGlass_Mac/`.
    static func hideEmptyDirsFile() -> URL {
        AppPaths.macAppSupportDir.appendingPathComponent("hide_empty_directories.txt")
    }

    private func readHideEmptyDirs() -> Bool {
        let url = Self.hideEmptyDirsFile()
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func writeHideEmptyDirs(_ enabled: Bool) throws {
        try? AppPaths.ensureMacDirectories()
        let url = Self.hideEmptyDirsFile()
        let s = enabled ? "true" : "false"
        try Data(s.utf8).write(to: url, options: .atomic)
    }

    private func setHideEmptyDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.set_hide_empty_directories",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let enabled = args["enabled"] as? Bool else {
            logger.logDirectoryToolCall(
                toolName: "set_hide_empty_directories", path: nil,
                client: client, corr: corr, ok: false, err: "missing_enabled"
            )
            return .text("Missing `enabled` (boolean).", isError: true)
        }
        do { try writeHideEmptyDirs(enabled) } catch {
            logger.logDirectoryToolCall(
                toolName: "set_hide_empty_directories", path: nil,
                client: client, corr: corr, ok: false, err: "storage_write_failed"
            )
            return .text("Failed to write preference: \(error)", isError: true)
        }
        logger.logDirectoryToolCall(
            toolName: "set_hide_empty_directories", path: nil,
            client: client, corr: corr, ok: true,
            extra: [("enabled", enabled ? "true" : "false")]
        )
        // Same notification path as YAML changes — the app's kqueue
        // watcher is already listening to the same directory, so
        // the flag file lands in the same reconcile loop.
        postDirectoriesChanged()
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "app_running": appIsRunning(),
            "enabled": enabled,
        ] as [String: Any]))
    }

    private func getHideEmptyDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.get_hide_empty_directories")
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        let enabled = readHideEmptyDirs()
        logger.logDirectoryToolCall(
            toolName: "get_hide_empty_directories", path: nil,
            client: "claude-code", corr: corr, ok: true,
            extra: [("enabled", enabled ? "true" : "false")]
        )
        return .text(prettyJSON([
            "ok": true,
            "corr": corr,
            "enabled": enabled,
        ] as [String: Any]))
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
            // mcp_and_filters_on_dirs.mdx §3.2 — priority is optional;
            // default 0. Accept Int and Double (Claude often serializes
            // small integers as doubles).
            let priority: Int
            if let p = dict["priority"] as? Int { priority = p }
            else if let p = dict["priority"] as? Double { priority = Int(p) }
            else { priority = 0 }
            let pattern = try Self.normalizePattern(rawPattern, kind: kind)
            items.append(RootFilterItem(
                pattern: pattern,
                kind: kind,
                negate: negate,
                priority: priority
            ))
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

    // MARK: - App liveness + cross-process push

    /// Post a Darwin distributed notification so the running desktop app is
    /// woken up immediately instead of waiting for the kqueue 250 ms debounce.
    /// `deliverImmediately: true` bypasses the run-loop coalescing that would
    /// otherwise batch rapid-fire writes into a single callback.
    private func postDirectoriesChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .init(MCPNotificationBus.directoriesChangedNotificationName),
            object: nil,
            deliverImmediately: true
        )
    }

    /// Return `true` when the desktop app is running. The app writes its PID
    /// to `heartbeat.txt` at launch and every 30 s; `kill(pid, 0)` probes
    /// liveness without sending a signal. Returns `false` when the file is
    /// absent, unparseable, or the PID is no longer alive.
    private func appIsRunning() -> Bool {
        let url = AppPaths.macAppSupportDir.appendingPathComponent("heartbeat.txt")
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8),
              let pid = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
