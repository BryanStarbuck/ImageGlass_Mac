import Foundation

/// Tool implementations exposed by the MCP server.
/// Each tool reads / writes Local Storage. No GUI dependency.
public struct MCPTools {

    public let storage: LocalStorage

    public init(storage: LocalStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "list_scopes",
                description: "List all scope names currently stored in Local Storage.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_scope",
                description: "Get the full definition of a scope by name (include rules, exclude rules, resolved files, lastEvaluated).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Scope name."],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "create_scope",
                description: "Create a new scope with optional include rules. Returns the saved scope.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "description": ["type": "string"],
                        "directories": ["type": "array", "items": ["type": "string"]],
                        "recursive": ["type": "boolean"],
                        "extensions": ["type": "array", "items": ["type": "string"]],
                        "include_globs": ["type": "array", "items": ["type": "string"]],
                        "exclude_globs": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_directories",
                description: "Replace the include directories list for the named scope. Does NOT re-evaluate; call evaluate_scope after.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "directories": ["type": "array", "items": ["type": "string"]],
                        "recursive": ["type": "boolean"],
                    ],
                    "required": ["name", "directories"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_include_criteria",
                description: "Replace include globs and/or extensions on a scope.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "globs": ["type": "array", "items": ["type": "string"]],
                        "extensions": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_exclude_criteria",
                description: "Replace exclude globs / hidden-file behavior on a scope.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "globs": ["type": "array", "items": ["type": "string"]],
                        "hidden_files": ["type": "boolean"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "evaluate_scope",
                description: "Walk the scope's directories, apply filters, write the resolved file list and timestamp back to Local Storage. Returns the resolved file list.",
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
                description: "Delete a scope from Local Storage.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
        ] + charterDescriptors()
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        // Charter tools (rule sets, chaining, audit, diff, import/export)
        // get first chance to handle the call.
        if let charterResult = try callCharter(name: name, arguments: arguments) {
            return charterResult
        }
        switch name {
        case "list_scopes":
            let scopes = try storage.listScopes()
            return .text(prettyJSON(["scopes": scopes]))

        case "get_scope":
            let scopeName = try requireString(arguments, "name")
            let scope = try storage.loadScope(scopeName)
            return .text(prettyJSON(scope))

        case "create_scope":
            let scopeName = try requireString(arguments, "name")
            if storage.scopeExists(scopeName) {
                return .text("Scope '\(scopeName)' already exists.", isError: true)
            }
            var scope = Scope(name: scopeName)
            scope.description = arguments["description"] as? String
            if let dirs = arguments["directories"] as? [Any?] {
                scope.include.directories = dirs.compactMap { $0 as? String }
            }
            if let recursive = arguments["recursive"] as? Bool {
                scope.include.recursive = recursive
            }
            if let exts = arguments["extensions"] as? [Any?] {
                scope.include.extensions = exts.compactMap { $0 as? String }
            }
            if let globs = arguments["include_globs"] as? [Any?] {
                scope.include.globs = globs.compactMap { $0 as? String }
            }
            if let exGlobs = arguments["exclude_globs"] as? [Any?] {
                scope.exclude.globs = exGlobs.compactMap { $0 as? String }
            }
            try storage.saveScope(scope)
            return .text(prettyJSON(scope))

        case "set_directories":
            let scopeName = try requireString(arguments, "name")
            var scope = try storage.loadScope(scopeName)
            let dirs = try requireStringArray(arguments, "directories")
            scope.include.directories = dirs
            if let recursive = arguments["recursive"] as? Bool {
                scope.include.recursive = recursive
            }
            try storage.saveScope(scope)
            return .text(prettyJSON(scope))

        case "set_include_criteria":
            let scopeName = try requireString(arguments, "name")
            var scope = try storage.loadScope(scopeName)
            if let globs = arguments["globs"] as? [Any?] {
                scope.include.globs = globs.compactMap { $0 as? String }
            }
            if let exts = arguments["extensions"] as? [Any?] {
                scope.include.extensions = exts.compactMap { $0 as? String }
            }
            try storage.saveScope(scope)
            return .text(prettyJSON(scope))

        case "set_exclude_criteria":
            let scopeName = try requireString(arguments, "name")
            var scope = try storage.loadScope(scopeName)
            if let globs = arguments["globs"] as? [Any?] {
                scope.exclude.globs = globs.compactMap { $0 as? String }
            }
            if let hidden = arguments["hidden_files"] as? Bool {
                scope.exclude.hiddenFiles = hidden
            }
            try storage.saveScope(scope)
            return .text(prettyJSON(scope))

        case "evaluate_scope":
            let scopeName = try requireString(arguments, "name")
            let scope = try storage.loadScope(scopeName)
            // Use the charter-flavored evaluator so rule-set composition,
            // inheritsFrom chaining, diffing, and audit logging all run.
            let evaluated = ScopeEvaluator.evaluateWithProvenance(scope)
            try storage.saveScope(evaluated)
            var payload: [String: Any] = [
                "name": evaluated.name,
                "lastEvaluated": ISO8601DateFormatter().string(from: evaluated.lastEvaluated ?? Date()),
                "fileCount": evaluated.resolvedFiles.count,
                "files": evaluated.resolvedFiles,
            ]
            if let d = evaluated.lastDiff {
                payload["added"] = d.added
                payload["removed"] = d.removed
            }
            return .text(prettyJSON(payload))

        case "delete_scope":
            let scopeName = try requireString(arguments, "name")
            try storage.deleteScope(scopeName)
            // Best-effort: prune the per-scope audit log so deletion is total.
            try? ScopeAuditLog.shared.clear(scopeName: scopeName)
            return .text("Deleted scope '\(scopeName)'.")

        default:
            return .text("Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - Helpers

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    private func requireStringArray(_ args: [String: Any?], _ key: String) throws -> [String] {
        guard let v = args[key] as? [Any?] else {
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

public enum MCPToolError: Error, CustomStringConvertible {
    case missingArgument(String)
    public var description: String {
        switch self {
        case .missingArgument(let k): return "Missing or invalid argument: \(k)"
        }
    }
}
