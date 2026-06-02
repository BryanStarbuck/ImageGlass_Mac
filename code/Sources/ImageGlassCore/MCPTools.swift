import Foundation

/// Tool implementations exposed by the MCP server.
///
/// Each tool is a thin wrapper around an edit to Local Storage (spec §6, §7).
/// No GUI dependency: every tool reads and writes plain-text files on disk,
/// and the GUI picks the change up on the next scope evaluation.
///
/// Validation, scope-name policy, and path normalization are layered in via
/// helpers in `MCP/` so this file stays focused on dispatch.
public struct MCPTools {

    public let storage: LocalStorage
    public let toolStorage: ExternalToolStorage
    public let lock: MCPLock
    public let themeTools: ThemeMCPTools
    public let cropTools: CropMCPTools
    public let panelTools: PanelMCPTools
    /// File-tree panel tools from `docs/use_cases/mcp_file.mdx` —
    /// `add_directory`, `remove_directory`, `set_global_filter`,
    /// `update_directory_filter`, `clear_directories`, etc. Writes
    /// `directories.yaml` and structured records to `log.log`.
    public let directoriesTools: DirectoriesMCPTools
    /// GUI-bridge tools (`select_file`, `panel.set_view_mode`) that
    /// route a hint file + a notifications/imageglass/* push event.
    public let bridgeTools: FilePanelBridgeMCPTools

    public init(
        storage: LocalStorage = .shared,
        toolStorage: ExternalToolStorage = .shared,
        lock: MCPLock = .shared,
        themeTools: ThemeMCPTools = ThemeMCPTools(),
        cropTools: CropMCPTools = CropMCPTools(),
        panelTools: PanelMCPTools = PanelMCPTools(),
        directoriesTools: DirectoriesMCPTools = DirectoriesMCPTools(),
        bridgeTools: FilePanelBridgeMCPTools = FilePanelBridgeMCPTools()
    ) {
        self.storage = storage
        self.toolStorage = toolStorage
        self.lock = lock
        self.themeTools = themeTools
        self.cropTools = cropTools
        self.panelTools = panelTools
        self.directoriesTools = directoriesTools
        self.bridgeTools = bridgeTools
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        var base: [MCP.ToolDescriptor] = [
            .init(
                name: "list_scopes",
                description: "List all scope names currently stored in Local Storage. Returns { scopes: string[] }.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_scope",
                description: "Get the full definition of a scope by name: include rules, exclude rules, resolved files, and lastEvaluated timestamp.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Scope name. Must match an existing scope in Local Storage.",
                        ],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "create_scope",
                description: "Create a new named scope. Accepts directories, recursive flag, extensions, include globs, exclude globs. Fails if a scope with that name already exists.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "File-system-safe identifier: [A-Za-z0-9._-], max 64 chars, no leading dot.",
                        ],
                        "description": [
                            "type": "string",
                            "description": "Optional human-readable description of this scope.",
                        ],
                        "directories": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Absolute directory paths. '~' is expanded to $HOME.",
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "If true, walk subdirectories. Defaults to true on a new scope.",
                        ],
                        "extensions": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Extensions like 'png', 'jpg' (with or without leading dot). Case-insensitive.",
                        ],
                        "include_globs": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Glob patterns the filename must match. AND-combined with extensions.",
                        ],
                        "exclude_globs": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Glob patterns; matches are removed from the result.",
                        ],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_directories",
                description: "Replace the include-directories list for the named scope. Does NOT re-evaluate — call evaluate_scope after.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "directories": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Absolute directory paths. '~' is expanded to $HOME.",
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "If provided, also updates the recursive flag on the scope.",
                        ],
                    ],
                    "required": ["name", "directories"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_include_criteria",
                description: "Replace include globs and/or extensions for the named scope. Either or both fields may be supplied; omitted fields are left unchanged.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "globs": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Include glob patterns. Replaces the existing list when present.",
                        ],
                        "extensions": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Extensions. Replaces the existing list when present.",
                        ],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_exclude_criteria",
                description: "Replace exclude globs and/or the hidden-files flag for the named scope. Omitted fields are left unchanged.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "globs": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Exclude glob patterns. Replaces the existing list when present.",
                        ],
                        "hidden_files": [
                            "type": "boolean",
                            "description": "If false, dotfiles are included; if true (default), they're excluded.",
                        ],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "evaluate_scope",
                description: "Walk the scope's directories, apply filters, write the resolved file list and timestamp back to Local Storage. Returns { name, lastEvaluated, fileCount, files }.",
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
                name: "set_criteria",
                description: "Replace the full multi-criteria list for a scope (spec §3.1). Each criterion is one source directory plus its own recursive/max_depth/include_exts/exclude_exts/include_globs/exclude_globs/include_hidden/follow_symlinks/bookmark.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "criteria": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["root"],
                                "properties": [
                                    "root": ["type": "string"],
                                    "recursive": ["type": "boolean"],
                                    "max_depth": ["type": ["integer", "null"]],
                                    "include_exts": ["type": "array", "items": ["type": "string"]],
                                    "exclude_exts": ["type": "array", "items": ["type": "string"]],
                                    "include_globs": ["type": "array", "items": ["type": "string"]],
                                    "exclude_globs": ["type": "array", "items": ["type": "string"]],
                                    "include_hidden": ["type": "boolean"],
                                    "follow_symlinks": ["type": "boolean"],
                                    "bookmark": ["type": ["string", "null"]],
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                    "required": ["name", "criteria"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_sort",
                description: "Set the persisted sort selection on a scope (spec §3.1 / §5.1). `by` is one of name | size | modified | created | exif_date_taken | extension | random | dimensions. `direction` is asc | desc.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "by": ["type": "string"],
                        "direction": ["type": "string"],
                    ],
                    "required": ["name", "by"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_filter",
                description: "Set the persisted filter on a scope (spec §3.1 / §5.2). Any omitted field is left unchanged; pass `null` to clear a field.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "text": ["type": ["string", "null"]],
                        "date_from": ["type": ["string", "null"]],
                        "date_to": ["type": ["string", "null"]],
                        "min_width": ["type": ["integer", "null"]],
                        "min_height": ["type": ["integer", "null"]],
                        "max_size": ["type": ["integer", "null"]],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "delete_scope",
                description: "Delete a scope from Local Storage. Idempotent — deleting a non-existent scope is reported as such but is not an error.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),

            // MARK: - External Tools (see docs/build-tools.mdx)

            .init(
                name: "list_external_tools",
                description: "List all third-party tools registered with ImageGlass (see docs/build-tools.mdx). Returns the full descriptor for each tool.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "register_external_tool",
                description: "Register a third-party tool. The tool descriptor is persisted as plain JSON under ~/Library/Application Support/ImageGlass/tools/<id>.json. 'arguments' supports the <file> placeholder which is replaced with the currently displayed image path when the tool is launched.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Unique tool id (no slashes, no leading dot)."],
                        "display_name": ["type": "string", "description": "Human-readable name."],
                        "executable_path": ["type": "string", "description": "Absolute path to the tool executable. Tilde-expanded at launch."],
                        "arguments": ["type": "string", "description": "Argument template; use <file> for the current image path."],
                        "hotkey": ["type": "string", "description": "Optional hotkey binding string (e.g. cmd+shift+e)."],
                        "integration": ["type": "boolean", "description": "If true, the tool speaks the IPC protocol back to ImageGlass."],
                    ],
                    "required": ["id", "executable_path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "update_external_tool",
                description: "Update fields on an existing third-party tool. Any omitted field is left unchanged.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "display_name": ["type": "string"],
                        "executable_path": ["type": "string"],
                        "arguments": ["type": "string"],
                        "hotkey": ["type": ["string", "null"]],
                        "integration": ["type": "boolean"],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "unregister_external_tool",
                description: "Remove a third-party tool by id.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "fire_external_tool",
                description: "Launch a registered third-party tool, substituting <file> in its argument template with the given image path. Returns the resolved executable and argv that were dispatched.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "file": ["type": "string", "description": "Absolute path of the image to pass to the tool. Optional; if omitted, <file> resolves to empty string."],
                        "dry_run": ["type": "boolean", "description": "If true, do not actually spawn the process — just return what would be launched."],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),

            // MARK: - Charter (see docs/overview.mdx)

            .init(
                name: "charter_status",
                description: "Return a high-level audit of the five fork-charter goals from docs/overview.mdx — MCP support, modular panels, scope controls, Local Storage, and MCP-driven editing. Each goal is reported as implemented / partial / missing with supporting evidence.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),

            // MARK: - Releases & version metadata (see docs/releases.mdx)

            .init(
                name: "app_version",
                description: "Return this Mac fork's version metadata: marketing version, build number, release channel, and the upstream Windows version we currently track as stable.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "list_releases",
                description: "Return all release notes (both this Mac fork and upstream Windows) in reverse-chronological order, with version, date, kind (stable|beta), origin (mac_fork|upstream), and highlights. Sourced from docs/releases.mdx.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "origin": [
                            "type": "string",
                            "description": "Filter: 'mac_fork', 'upstream', or 'all' (default).",
                        ],
                    ],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "check_for_update",
                description: "Query GitHub Releases for a newer Mac fork build. Disabled by default — pass force=true to run the network call when the user explicitly asks (e.g. menu item 'Check for Updates…'). Returns currentVersion, latestVersion, isUpdateAvailable, and the release URL.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "force": [
                            "type": "boolean",
                            "description": "Override the disabled-by-default policy and issue the network call. Default: false.",
                        ],
                    ],
                    "additionalProperties": false,
                ])
            ),
        ]
        // Theme subsystem descriptors (list_themes, get/set_current_theme).
        // See Themes/ThemeMCPTools.swift.
        base.append(contentsOf: themeTools.descriptors())
        // Charter additions: rule sets, scope chains, audit, diff, import/export.
        base.append(contentsOf: charterDescriptors())
        // Crop subsystem (crop_image, get/set_crop_selection).
        base.append(contentsOf: cropTools.descriptors())
        // Panel framework (list_panels, show/hide/move/tab, apply_layout_preset, ...).
        base.append(contentsOf: panelTools.descriptors())
        // File-panel walkthrough tools (mcp_file.mdx §4–§10).
        base.append(contentsOf: directoriesTools.descriptors())
        // GUI-bridge tools (select_file, panel.set_view_mode) — §2 / §3.
        base.append(contentsOf: bridgeTools.descriptors())
        return base
    }

    // MARK: - Dispatch

    /// Spec §9: tool errors are returned as JSON-RPC `result` payloads with
    /// `isError: true` and a human-readable text block, NOT as JSON-RPC
    /// protocol-level errors. We catch every recoverable error inside the
    /// dispatch switch so the only way for this function to throw is a
    /// programming bug — the server then surfaces that as a structured
    /// `isError: true` result rather than as a JSON-RPC error code.
    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        do {
            // Charter tools (rule sets, chaining, audit, diff, import/export)
            // get first chance — see Charter/MCPTools+Charter.swift.
            if let charterResult = try callCharter(name: name, arguments: arguments) {
                return charterResult
            }
            switch name {
            case "list_scopes":
                return try listScopes()
            case "get_scope":
                return try getScope(arguments)
            case "create_scope":
                return try lock.withLock { try createScope(arguments) }
            case "set_directories":
                return try lock.withLock { try setDirectories(arguments) }
            case "set_include_criteria":
                return try lock.withLock { try setIncludeCriteria(arguments) }
            case "set_exclude_criteria":
                return try lock.withLock { try setExcludeCriteria(arguments) }
            case "evaluate_scope":
                return try lock.withLock { try evaluateScope(arguments) }
            case "set_criteria":
                return try lock.withLock { try setCriteria(arguments) }
            case "set_sort":
                return try lock.withLock { try setSort(arguments) }
            case "set_filter":
                return try lock.withLock { try setFilter(arguments) }
            case "delete_scope":
                return try lock.withLock { try deleteScope(arguments) }

            // External tools (see build-tools.mdx)
            case "list_external_tools":
                return try listExternalTools()
            case "register_external_tool":
                return try lock.withLock { try registerExternalTool(arguments) }
            case "update_external_tool":
                return try lock.withLock { try updateExternalTool(arguments) }
            case "unregister_external_tool":
                return try lock.withLock { try unregisterExternalTool(arguments) }
            case "fire_external_tool":
                return try fireExternalTool(arguments)

            // Charter (see overview.mdx)
            case "charter_status":
                return .text(prettyJSON(CharterStatus.report()))

            // Releases & version metadata (see releases.mdx)
            case "app_version":
                return appVersion()
            case "list_releases":
                return listReleases(arguments)
            case "check_for_update":
                return try checkForUpdate(arguments)

            default:
                // Route theme tools (list_themes, get/set_current_theme) through
                // ThemeMCPTools. See Themes/ThemeMCPTools.swift.
                if ThemeMCPTools.toolNames.contains(name) {
                    return try themeTools.call(name: name, arguments: arguments)
                }
                // Route crop tools through CropMCPTools.
                if CropMCPTools.toolNames.contains(name) {
                    return try cropTools.call(name: name, arguments: arguments)
                }
                // Route panel-framework tools through PanelMCPTools.
                if PanelMCPTools.toolNames.contains(name) {
                    return try panelTools.call(name: name, arguments: arguments)
                }
                // Route the file-panel walkthrough tools (mcp_file.mdx).
                if DirectoriesMCPTools.toolNames.contains(name) {
                    return try lock.withLock {
                        try directoriesTools.call(name: name, arguments: arguments)
                    }
                }
                // Route the GUI-bridge tools (select_file, set_view_mode).
                if FilePanelBridgeMCPTools.toolNames.contains(name) {
                    return try bridgeTools.call(name: name, arguments: arguments)
                }
                return .text("Unknown tool: \(name)", isError: true)
            }
        } catch let e as MCPToolError {
            return .text(e.description, isError: true)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            ErrorLog.log("scope file not found while dispatching MCP tool '\(name)'",
                         error: e,
                         class: "MCPTools")
            return .text("Scope not found on disk.", isError: true)
        } catch {
            ErrorLog.log("MCP tool '\(name)' raised unhandled error",
                         error: error,
                         class: "MCPTools")
            return .text("Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Tool bodies

    private func listScopes() throws -> MCP.CallToolResult {
        let scopes = try storage.listScopes()
        return .text(prettyJSON(["scopes": scopes]))
    }

    private func getScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        let scope = try storage.loadScope(scopeName)
        return .text(prettyJSON(scope))
    }

    private func createScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        if storage.scopeExists(scopeName) {
            throw MCPToolError.duplicateScope(scopeName)
        }
        var scope = Scope(name: scopeName)
        scope.description = args["description"] as? String
        if let dirs = args["directories"] as? [Any?] {
            let raw = dirs.compactMap { $0 as? String }
            scope.include.directories = MCPPath.normalizeDirectories(raw)
        }
        if let recursive = args["recursive"] as? Bool {
            scope.include.recursive = recursive
        }
        if let exts = args["extensions"] as? [Any?] {
            scope.include.extensions = exts.compactMap { $0 as? String }
        }
        if let globs = args["include_globs"] as? [Any?] {
            scope.include.globs = globs.compactMap { $0 as? String }
        }
        if let exGlobs = args["exclude_globs"] as? [Any?] {
            scope.exclude.globs = exGlobs.compactMap { $0 as? String }
        }
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func setDirectories(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        let dirs = try requireStringArray(args, "directories")
        scope.include.directories = MCPPath.normalizeDirectories(dirs)
        if let recursive = args["recursive"] as? Bool {
            scope.include.recursive = recursive
        }
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func setIncludeCriteria(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        if let globs = args["globs"] as? [Any?] {
            scope.include.globs = globs.compactMap { $0 as? String }
        }
        if let exts = args["extensions"] as? [Any?] {
            scope.include.extensions = exts.compactMap { $0 as? String }
        }
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func setExcludeCriteria(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        if let globs = args["globs"] as? [Any?] {
            scope.exclude.globs = globs.compactMap { $0 as? String }
        }
        if let hidden = args["hidden_files"] as? Bool {
            scope.exclude.hiddenFiles = hidden
        }
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func evaluateScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        let scope = try storage.loadScope(scopeName)
        // Use the charter-flavored evaluator so rule-set composition,
        // inheritsFrom chaining, diffing, and audit logging all run.
        let evaluated = ScopeEvaluator.evaluateWithProvenance(scope)
        try storage.saveScope(evaluated)
        let iso = ISO8601DateFormatter().string(from: evaluated.lastEvaluated ?? Date())
        var payload: [String: Any] = [
            "name": evaluated.name,
            "lastEvaluated": iso,
            "fileCount": evaluated.resolvedFiles.count,
            "files": evaluated.resolvedFiles,
        ]
        if let d = evaluated.lastDiff {
            payload["added"] = d.added
            payload["removed"] = d.removed
        }
        return .text(prettyJSON(payload))
    }

    private func setCriteria(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        guard let raw = args["criteria"] as? [Any?] else {
            throw MCPToolError.missingArgument("criteria")
        }
        var built: [Scope.SourceCriterion] = []
        for item in raw {
            guard let dict = item as? [String: Any?] else { continue }
            guard let root = (dict["root"] as? String) else { continue }
            let normalizedRoot = MCPPath.normalizeDirectory(root)
            var c = Scope.SourceCriterion(root: normalizedRoot)
            if let v = dict["recursive"] as? Bool { c.recursive = v }
            if let v = dict["max_depth"] as? Int { c.maxDepth = v }
            if let v = dict["include_exts"] as? [Any?] { c.includeExts = v.compactMap { $0 as? String } }
            if let v = dict["exclude_exts"] as? [Any?] { c.excludeExts = v.compactMap { $0 as? String } }
            if let v = dict["include_globs"] as? [Any?] { c.includeGlobs = v.compactMap { $0 as? String } }
            if let v = dict["exclude_globs"] as? [Any?] { c.excludeGlobs = v.compactMap { $0 as? String } }
            if let v = dict["include_hidden"] as? Bool { c.includeHidden = v }
            if let v = dict["follow_symlinks"] as? Bool { c.followSymlinks = v }
            if let v = dict["bookmark"] as? String { c.bookmark = v }
            built.append(c)
        }
        scope.criteria = built
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func setSort(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        let byRaw = try requireString(args, "by")
        guard let by = Scope.ScopeSort.Field(rawValue: byRaw) else {
            let valid = Scope.ScopeSort.Field.allCases.map(\.rawValue).joined(separator: ", ")
            return .text("Unknown sort field '\(byRaw)'. Valid: \(valid).", isError: true)
        }
        var dir = scope.sort.direction
        if let dRaw = args["direction"] as? String {
            switch dRaw {
            case "asc": dir = .asc
            case "desc": dir = .desc
            default:
                return .text("Unknown direction '\(dRaw)'. Valid: asc, desc.", isError: true)
            }
        }
        scope.sort = Scope.ScopeSort(by: by, direction: dir)
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func setFilter(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        guard storage.scopeExists(scopeName) else {
            throw MCPToolError.unknownScope(scopeName)
        }
        var scope = try storage.loadScope(scopeName)
        var f = scope.filter
        let iso = ISO8601DateFormatter()
        if args.keys.contains("text") {
            f.text = args["text"] as? String
        }
        if args.keys.contains("date_from") {
            f.dateFrom = (args["date_from"] as? String).flatMap { iso.date(from: $0) }
        }
        if args.keys.contains("date_to") {
            f.dateTo = (args["date_to"] as? String).flatMap { iso.date(from: $0) }
        }
        if args.keys.contains("min_width") {
            f.minWidth = args["min_width"] as? Int
        }
        if args.keys.contains("min_height") {
            f.minHeight = args["min_height"] as? Int
        }
        if args.keys.contains("max_size") {
            if let i = args["max_size"] as? Int { f.maxSize = Int64(i) }
            else if let i64 = args["max_size"] as? Int64 { f.maxSize = i64 }
            else { f.maxSize = nil }
        }
        scope.filter = f
        try storage.saveScope(scope)
        return .text(prettyJSON(scope))
    }

    private func deleteScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        let existed = storage.scopeExists(scopeName)
        try storage.deleteScope(scopeName)
        // Best-effort: prune the per-scope audit log so deletion is total.
        do {
            try ScopeAuditLog.shared.clear(scopeName: scopeName)
        } catch {
            ErrorLog.log("failed to clear ScopeAuditLog for '\(scopeName)'",
                         error: error,
                         class: "MCPTools")
        }
        if existed {
            return .text("Deleted scope '\(scopeName)'.")
        } else {
            return .text("Scope '\(scopeName)' did not exist; nothing to delete.")
        }
    }

    // MARK: - External tool bodies (see build-tools.mdx)

    private func listExternalTools() throws -> MCP.CallToolResult {
        let list = try toolStorage.listTools()
        return .text(prettyJSON(["tools": list]))
    }

    private func registerExternalTool(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        try ExternalToolId.validate(id)
        if toolStorage.toolExists(id) {
            return .text("External tool '\(id)' already exists.", isError: true)
        }
        let exe = try requireString(args, "executable_path")
        var tool = ExternalTool(
            id: id,
            displayName: (args["display_name"] as? String) ?? id,
            executablePath: exe,
            arguments: (args["arguments"] as? String) ?? "",
            hotkey: args["hotkey"] as? String,
            integration: (args["integration"] as? Bool) ?? false
        )
        if tool.displayName.isEmpty { tool.displayName = id }
        try toolStorage.saveTool(tool)
        return .text(prettyJSON(tool))
    }

    private func updateExternalTool(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        var tool = try toolStorage.loadTool(id)
        if let dn = args["display_name"] as? String { tool.displayName = dn }
        if let exe = args["executable_path"] as? String { tool.executablePath = exe }
        if let argv = args["arguments"] as? String { tool.arguments = argv }
        if args.keys.contains("hotkey") {
            tool.hotkey = args["hotkey"] as? String
        }
        if let integ = args["integration"] as? Bool { tool.integration = integ }
        try toolStorage.saveTool(tool)
        return .text(prettyJSON(tool))
    }

    private func unregisterExternalTool(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        try toolStorage.deleteTool(id)
        return .text("Unregistered external tool '\(id)'.")
    }

    private func fireExternalTool(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        let tool = try toolStorage.loadTool(id)
        let file = args["file"] as? String
        let dryRun = (args["dry_run"] as? Bool) ?? false
        let exe = ExternalToolLauncher.resolvedExecutable(for: tool)
        let argv = ExternalToolLauncher.buildArguments(template: tool.arguments, filePath: file)
        if dryRun {
            return .text(prettyJSON([
                "id": tool.id,
                "executable": exe,
                "argv": argv,
                "dryRun": true,
            ] as [String: Any]))
        }
        do {
            _ = try ExternalToolLauncher().launch(tool, filePath: file)
        } catch {
            ErrorLog.log("ExternalToolLauncher.launch failed for tool '\(id)'",
                         error: error,
                         class: "MCPTools")
            return .text("Failed to launch '\(id)': \(error)", isError: true)
        }
        return .text(prettyJSON([
            "id": tool.id,
            "executable": exe,
            "argv": argv,
            "launched": true,
        ] as [String: Any]))
    }

    // MARK: - Releases & version metadata

    private func appVersion() -> MCP.CallToolResult {
        let payload: [String: Any] = [
            "marketing_version": AppVersion.marketingVersion,
            "build_number": AppVersion.buildNumber,
            "channel": AppVersion.channel.rawValue,
            "display_version": AppVersion.displayVersion,
            "semver": AppVersion.semverString,
            "user_agent": AppVersion.userAgent,
            "current_stable_upstream": ReleasesCatalog.currentStableUpstreamVersion,
        ]
        return .text(prettyJSON(payload))
    }

    private func listReleases(_ args: [String: Any?]) -> MCP.CallToolResult {
        let originFilter = (args["origin"] as? String) ?? "all"
        let entries: [Changelog.Entry]
        switch originFilter.lowercased() {
        case "mac_fork", "macfork", "mac":
            entries = Changelog.macForkEntries
        case "upstream":
            entries = Changelog.upstreamEntries
        default:
            entries = Changelog.entries
        }
        let iso = ISO8601DateFormatter()
        let releases: [[String: Any]] = entries.map { e in
            [
                "version": e.version,
                "title": e.title,
                "date": iso.string(from: e.date),
                "kind": e.kind.rawValue,
                "origin": e.origin == .macFork ? "mac_fork" : "upstream",
                "highlights": e.bullets,
            ] as [String: Any]
        }
        return .text(prettyJSON(["releases": releases] as [String: Any]))
    }

    private func checkForUpdate(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let force = (args["force"] as? Bool) ?? false
        let checker = UpdateChecker()
        // Synchronously dispatch the async check from a non-async tool call.
        // Tools may be invoked from a synchronous JSON-RPC dispatch loop, so
        // we hop onto a dedicated semaphore-gated Task to wait for the result.
        var captured: Result<UpdateCheckResult, Error>!
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let r = try await checker.check(force: force)
                captured = .success(r)
            } catch {
                captured = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch captured! {
        case .success(let r):
            let payload: [String: Any] = [
                "current_version": r.currentVersion,
                "latest_version": r.latestVersion as Any,
                "is_update_available": r.isUpdateAvailable,
                "release_url": r.latestReleaseURL?.absoluteString as Any,
                "channel": r.channel.rawValue,
                "checked_at": ISO8601DateFormatter().string(from: r.checkedAt),
            ]
            return .text(prettyJSON(payload))
        case .failure(let err):
            if let uc = err as? UpdateCheckError {
                switch uc {
                case .disabledByPolicy:
                    return .text(
                        "Update check is disabled by default. Pass force=true to run it.",
                        isError: true
                    )
                case .networkUnavailable:
                    return .text("Network unavailable.", isError: true)
                case .malformedResponse:
                    return .text("Malformed response from GitHub Releases.", isError: true)
                case .httpStatus(let code):
                    return .text("GitHub Releases returned HTTP \(code).", isError: true)
                }
            }
            return .text("Update check failed: \(err.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let raw = args[key], let v = raw as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    private func requireStringArray(_ args: [String: Any?], _ key: String) throws -> [String] {
        guard let raw = args[key], let v = raw as? [Any?] else {
            throw MCPToolError.missingArgument(key)
        }
        return v.compactMap { $0 as? String }
    }

    private func prettyJSON<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(value)
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("prettyJSON UTF-8 decode failed for \(T.self)",
                         class: "MCPTools")
            return "{}"
        } catch {
            ErrorLog.log("prettyJSON encode failed for \(T.self)",
                         error: error,
                         class: "MCPTools")
            return "{}"
        }
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("prettyJSON(dict) UTF-8 decode failed",
                         class: "MCPTools")
            return "{}"
        } catch {
            ErrorLog.log("prettyJSON(dict) JSONSerialization failed",
                         error: error,
                         class: "MCPTools")
            return "{}"
        }
    }
}

/// Errors raised by tool implementations. Surfaced to the MCP client as text
/// blocks inside a `CallToolResult` with `isError: true`, never as a JSON-RPC
/// protocol error. See spec §9.
public enum MCPToolError: Error, CustomStringConvertible {
    case missingArgument(String)
    case invalidScopeName(String)
    case unknownScope(String)
    case duplicateScope(String)

    public var description: String {
        switch self {
        case .missingArgument(let k):
            return "Missing or invalid argument: \(k)"
        case .invalidScopeName(let detail):
            return "Invalid scope name: \(detail)"
        case .unknownScope(let n):
            return "Unknown scope: '\(n)'"
        case .duplicateScope(let n):
            return "Scope '\(n)' already exists."
        }
    }
}
