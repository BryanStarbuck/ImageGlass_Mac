import Foundation

/// MCP tools that drive the file panel (the spec scenarios in
/// `docs/use_cases/mcp_file.mdx` §4 – §10). Each tool reads/writes the
/// YAML scope file at `~/Library/Application Support/ImageGlass_Mac/scopes/<name>.yaml`
/// and emits a structured line to `…/logs/log.log` via `MCPAuditLogger`.
///
/// To keep the existing SwiftUI panel in sync (the GUI loads scopes
/// through `LocalStorage` / `AppState`), each successful write is
/// mirrored back into the legacy JSON store. The two on-disk files share
/// the same `Scope` shape.
public struct FilePanelMCPTools {

    public let yamlStore: MacScopeStore
    public let legacyStore: LocalStorage
    public let logger: MCPAuditLogger

    /// Tool names this subsystem owns. The top-level `MCPTools.call`
    /// checks membership and routes here.
    public static let toolNames: Set<String> = [
        "update_scope",
        "list_files_in_scope",
        "select_file",
        "panel.set_view_mode",
    ]

    public init(
        yamlStore: MacScopeStore = .shared,
        legacyStore: LocalStorage = .shared,
        logger: MCPAuditLogger = .shared
    ) {
        self.yamlStore = yamlStore
        self.legacyStore = legacyStore
        self.logger = logger
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "update_scope",
                description: """
                    Apply a patch to a YAML scope file. The patch is a small \
                    set of operations (see docs/use_cases/mcp_file.mdx §4–§7): \
                    `add_criteria`, `remove_criteria_with_root`, \
                    `set_include_exts_global`, `set_exclude_globs_global`, \
                    `clear_criteria`. The scope file is rewritten atomically \
                    and a re-walk is triggered. Returns the new scope.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "client": [
                            "type": "string",
                            "description": "Optional MCP client identifier (claude-code, gui, …) recorded in the log.",
                        ],
                        "patch": [
                            "type": "object",
                            "properties": [
                                "add_criteria": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "required": ["root"],
                                        "properties": [
                                            "root":           ["type": "string"],
                                            "recursive":      ["type": "boolean"],
                                            "max_depth":      ["type": ["integer", "null"]],
                                            "include_exts":   ["type": "array", "items": ["type": "string"]],
                                            "exclude_exts":   ["type": "array", "items": ["type": "string"]],
                                            "include_globs":  ["type": "array", "items": ["type": "string"]],
                                            "exclude_globs":  ["type": "array", "items": ["type": "string"]],
                                            "include_hidden": ["type": "boolean"],
                                        ] as [String: Any],
                                    ] as [String: Any],
                                ] as [String: Any],
                                "remove_criteria_with_root": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                ] as [String: Any],
                                "set_include_exts_global": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Apply this `include_exts` list to every criterion.",
                                ] as [String: Any],
                                "set_exclude_globs_global": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Apply this `exclude_globs` list to every criterion.",
                                ] as [String: Any],
                                "clear_criteria": [
                                    "type": "boolean",
                                    "description": "If true, empty the criteria array.",
                                ] as [String: Any],
                            ] as [String: Any],
                            "additionalProperties": false,
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["name", "patch"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "list_files_in_scope",
                description: """
                    Return the resolved file list for a scope (after the most \
                    recent walk). Returns { files: string[], total: int }.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "select_file",
                description: """
                    Programmatically select a file in the file panel. The \
                    selection persists to `selection.txt` next to the scope \
                    files so the GUI can react. Returns { path: string }.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Scope name. Defaults to 'default'."],
                        "path": ["type": "string"],
                        "client": ["type": "string"],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "panel.set_view_mode",
                description: """
                    Switch the file panel's view mode (strip / grid / details \
                    / tree / scroller). See docs/list_of_files.mdx §4.1. \
                    Returns { mode: string }.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": ["strip", "grid", "details", "tree", "scroller"],
                        ] as [String: Any],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["mode"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        switch name {
        case "update_scope":       return try updateScope(arguments)
        case "list_files_in_scope": return try listFilesInScope(arguments)
        case "select_file":        return try selectFile(arguments)
        case "panel.set_view_mode": return try setPanelViewMode(arguments)
        default:
            return .text("Unknown file-panel tool: \(name)", isError: true)
        }
    }

    // MARK: - update_scope

    private func updateScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "unknown"
        let scopeName: String
        do {
            scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        } catch {
            logger.logMCPCall(
                toolName: "update_scope",
                scope: nil,
                client: client,
                corr: corr,
                ok: false,
                err: "invalid_name"
            )
            return .text("Invalid or missing scope name.", isError: true)
        }

        guard let patch = args["patch"] as? [String: Any?] else {
            logger.logMCPCall(
                toolName: "update_scope",
                scope: scopeName,
                client: client,
                corr: corr,
                ok: false,
                err: "missing_patch"
            )
            return .text("Missing `patch` object.", isError: true)
        }

        // Validate the patch before touching disk so a malformed call
        // does not leave the YAML file half-written.
        if let bad = validatePatch(patch) {
            logger.logMCPCall(
                toolName: "update_scope",
                scope: scopeName,
                client: client,
                corr: corr,
                ok: false,
                err: bad
            )
            return .text("Invalid patch: \(bad)", isError: true)
        }

        // Load existing scope (YAML preferred; fall back to legacy JSON).
        var scope: Scope
        if yamlStore.scopeExists(scopeName) {
            scope = (try? yamlStore.loadScope(scopeName)) ?? Scope(name: scopeName)
        } else if legacyStore.scopeExists(scopeName) {
            scope = (try? legacyStore.loadScope(scopeName)) ?? Scope(name: scopeName)
        } else {
            scope = Scope(name: scopeName)
        }

        // Apply patch operations in a fixed order so concurrent fields are
        // deterministic: clear → add → remove → set_include_exts → set_exclude_globs.
        var fields: [String] = []
        if (patch["clear_criteria"] as? Bool) == true {
            scope.criteria = []
            fields.append("criteria.clear")
        }
        if let adds = patch["add_criteria"] as? [Any?] {
            for raw in adds {
                guard let dict = raw as? [String: Any?] else { continue }
                guard let root = dict["root"] as? String else { continue }
                var c = Scope.SourceCriterion(root: expandTilde(root))
                if let v = dict["recursive"] as? Bool        { c.recursive = v }
                if let v = dict["max_depth"] as? Int          { c.maxDepth = v }
                if let v = dict["include_exts"] as? [Any?]    { c.includeExts = v.compactMap { $0 as? String } }
                if let v = dict["exclude_exts"] as? [Any?]    { c.excludeExts = v.compactMap { $0 as? String } }
                if let v = dict["include_globs"] as? [Any?]   { c.includeGlobs = v.compactMap { $0 as? String } }
                if let v = dict["exclude_globs"] as? [Any?]   { c.excludeGlobs = v.compactMap { $0 as? String } }
                if let v = dict["include_hidden"] as? Bool    { c.includeHidden = v }
                scope.criteria.append(c)
            }
            fields.append("criteria.add")
        }
        if let removes = patch["remove_criteria_with_root"] as? [Any?] {
            let roots = removes.compactMap { ($0 as? String).map(expandTilde) }
            scope.criteria.removeAll { roots.contains($0.root) }
            fields.append("criteria.remove")
        }
        if let exts = patch["set_include_exts_global"] as? [Any?] {
            let list = exts.compactMap { $0 as? String }
            for i in scope.criteria.indices {
                scope.criteria[i].includeExts = list
            }
            fields.append("criteria.include_exts")
        }
        if let globs = patch["set_exclude_globs_global"] as? [Any?] {
            let list = globs.compactMap { $0 as? String }
            for i in scope.criteria.indices {
                scope.criteria[i].excludeGlobs = list
            }
            fields.append("criteria.exclude_globs")
        }

        // Persist the scope. YAML first so a `cat default.yaml` from the
        // spec walkthrough sees the new content; then mirror to JSON so
        // the GUI's FSEventStream picks it up.
        do {
            try yamlStore.saveScope(scope)
        } catch {
            logger.logMCPCall(
                toolName: "update_scope",
                scope: scopeName,
                client: client,
                corr: corr,
                ok: false,
                err: "io_yaml"
            )
            return .text("Failed to write YAML scope: \(error)", isError: true)
        }
        try? legacyStore.saveScope(scope)

        // Walk the scope and capture the resolved list + elapsed time.
        let walkStart = Date()
        let evaluated = ScopeEvaluator.evaluate(scope)
        let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)

        // Persist the walked result so the YAML on disk matches the spec's
        // §4.4 "verify by cat" expectation.
        try? yamlStore.saveScope(evaluated)
        try? legacyStore.saveScope(evaluated)

        // First the request line, then the matching evaluate line.
        let fieldList = "[\(fields.joined(separator: ","))]"
        logger.logMCPCall(
            toolName: "update_scope",
            scope: scopeName,
            client: client,
            corr: corr,
            ok: true,
            extra: [("fields", fieldList)]
        )
        logger.logScopeEvaluate(
            scope: scopeName,
            count: evaluated.resolved.count,
            elapsedMs: elapsedMs,
            corr: corr
        )

        return .text(prettyJSON([
            "name": evaluated.name,
            "corr": corr,
            "count": evaluated.resolved.count,
            "elapsed_ms": elapsedMs,
            "files": evaluated.resolved.map(\.path),
        ] as [String: Any]))
    }

    // MARK: - list_files_in_scope

    private func listFilesInScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let rawName = (args["name"] as? String) ?? "default"
        let scopeName: String
        do {
            scopeName = try MCPScopeName.validate(rawName)
        } catch {
            logger.logMCPCall(
                toolName: "list_files_in_scope",
                scope: nil,
                client: "mcp",
                corr: corr,
                ok: false,
                err: "invalid_name"
            )
            return .text("Invalid scope name.", isError: true)
        }
        var files: [String] = []
        if yamlStore.scopeExists(scopeName),
           let s = try? yamlStore.loadScope(scopeName) {
            files = s.resolved.map(\.path)
        } else if legacyStore.scopeExists(scopeName),
                  let s = try? legacyStore.loadScope(scopeName) {
            files = s.resolvedFiles
        }
        logger.logMCPCall(
            toolName: "list_files_in_scope",
            scope: scopeName,
            client: "mcp",
            corr: corr,
            ok: true,
            extra: [("count", String(files.count))]
        )
        return .text(prettyJSON([
            "files": files,
            "total": files.count,
        ] as [String: Any]))
    }

    // MARK: - select_file

    private func selectFile(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
        let scopeName = (args["name"] as? String) ?? "default"
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            logger.logMCPCall(
                toolName: "select_file",
                scope: scopeName,
                client: client,
                corr: corr,
                ok: false,
                err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }
        let path = expandTilde(raw)

        // Persist the selection hint so a GUI watcher can react.
        let selectionFile = AppPaths.macAppSupportDir.appendingPathComponent("selection.txt")
        try? AppPaths.ensureMacDirectories()
        try? path.data(using: .utf8)?.write(to: selectionFile, options: .atomic)

        logger.logMCPCall(
            toolName: "select_file",
            scope: scopeName,
            client: client,
            corr: corr,
            ok: true,
            extra: [("path", path)]
        )
        return .text(prettyJSON([
            "path": path,
        ] as [String: Any]))
    }

    // MARK: - panel.set_view_mode

    private static let validViewModes: Set<String> = [
        "strip", "grid", "details", "tree", "scroller",
    ]

    private func setPanelViewMode(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "mcp"
        guard let mode = args["mode"] as? String,
              Self.validViewModes.contains(mode) else {
            logger.logMCPCall(
                toolName: "panel.set_view_mode",
                scope: nil,
                client: client,
                corr: corr,
                ok: false,
                err: "invalid_mode"
            )
            return .text("Invalid `mode`. Valid: strip, grid, details, tree, scroller.", isError: true)
        }
        // Persist a tiny hint file the GUI can read on next launch /
        // FSEvents tick. The actual switch is wired in AppState.
        try? AppPaths.ensureMacDirectories()
        let modeFile = AppPaths.macAppSupportDir.appendingPathComponent("panel_view_mode.txt")
        try? mode.data(using: .utf8)?.write(to: modeFile, options: .atomic)

        logger.logMCPCall(
            toolName: "panel.set_view_mode",
            scope: nil,
            client: client,
            corr: corr,
            ok: true,
            extra: [("mode", mode)]
        )
        return .text(prettyJSON(["mode": mode] as [String: Any]))
    }

    // MARK: - Helpers

    private func validatePatch(_ patch: [String: Any?]) -> String? {
        for (k, _) in patch {
            switch k {
            case "add_criteria", "remove_criteria_with_root",
                 "set_include_exts_global", "set_exclude_globs_global",
                 "clear_criteria":
                continue
            default:
                return "unknown_field:\(k)"
            }
        }
        if let v = patch["add_criteria"], !(v is [Any?]) {
            return "add_criteria_not_array"
        }
        if let v = patch["remove_criteria_with_root"], !(v is [Any?]) {
            return "remove_criteria_with_root_not_array"
        }
        if let v = patch["set_include_exts_global"], !(v is [Any?]) {
            return "set_include_exts_global_not_array"
        }
        if let v = patch["set_exclude_globs_global"], !(v is [Any?]) {
            return "set_exclude_globs_global_not_array"
        }
        if let v = patch["clear_criteria"], !(v is Bool) {
            return "clear_criteria_not_bool"
        }
        return nil
    }

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let raw = args[key], let v = raw as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    private func expandTilde(_ s: String) -> String {
        AppPaths.expandTilde(s)
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

