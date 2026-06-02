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
    public let lock: MCPLock

    public init(storage: LocalStorage = .shared, lock: MCPLock = .shared) {
        self.storage = storage
        self.lock = lock
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
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
        ]
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
            case "delete_scope":
                return try lock.withLock { try deleteScope(arguments) }
            default:
                return .text("Unknown tool: \(name)", isError: true)
            }
        } catch let e as MCPToolError {
            return .text(e.description, isError: true)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return .text("Scope not found on disk.", isError: true)
        } catch {
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
        let evaluated = ScopeEvaluator.evaluate(scope)
        try storage.saveScope(evaluated)
        let iso = ISO8601DateFormatter().string(from: evaluated.lastEvaluated ?? Date())
        return .text(prettyJSON([
            "name": evaluated.name,
            "lastEvaluated": iso,
            "fileCount": evaluated.resolvedFiles.count,
            "files": evaluated.resolvedFiles,
        ] as [String: Any]))
    }

    private func deleteScope(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let scopeName = try MCPScopeName.validate(try requireString(args, "name"))
        let existed = storage.scopeExists(scopeName)
        try storage.deleteScope(scopeName)
        if existed {
            return .text("Deleted scope '\(scopeName)'.")
        } else {
            return .text("Scope '\(scopeName)' did not exist; nothing to delete.")
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
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
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
