import Foundation

/// Tool implementations exposed by the MCP server.
/// Each tool reads / writes Local Storage. No GUI dependency.
public struct MCPTools {

    public let storage: LocalStorage
    public let themeTools: ThemeMCPTools
    public let toolStorage: ExternalToolStorage

    public init(
        storage: LocalStorage = .shared,
        themeTools: ThemeMCPTools = ThemeMCPTools(),
        toolStorage: ExternalToolStorage = .shared
    ) {
        self.storage = storage
        self.themeTools = themeTools
        self.toolStorage = toolStorage
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        var base: [MCP.ToolDescriptor] = [
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
        ]
        // Theme subsystem descriptors (list_themes, get/set_current_theme).
        // See Themes/ThemeMCPTools.swift.
        base.append(contentsOf: themeTools.descriptors())
        return base
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
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
            let evaluated = ScopeEvaluator.evaluate(scope)
            try storage.saveScope(evaluated)
            return .text(prettyJSON([
                "name": evaluated.name,
                "lastEvaluated": ISO8601DateFormatter().string(from: evaluated.lastEvaluated ?? Date()),
                "fileCount": evaluated.resolvedFiles.count,
                "files": evaluated.resolvedFiles,
            ] as [String: Any]))

        case "delete_scope":
            let scopeName = try requireString(arguments, "name")
            try storage.deleteScope(scopeName)
            return .text("Deleted scope '\(scopeName)'.")

        // MARK: - External Tools

        case "list_external_tools":
            let list = try toolStorage.listTools()
            return .text(prettyJSON(["tools": list]))

        case "register_external_tool":
            let id = try requireString(arguments, "id")
            try ExternalToolId.validate(id)
            if toolStorage.toolExists(id) {
                return .text("External tool '\(id)' already exists.", isError: true)
            }
            let exe = try requireString(arguments, "executable_path")
            var tool = ExternalTool(
                id: id,
                displayName: (arguments["display_name"] as? String) ?? id,
                executablePath: exe,
                arguments: (arguments["arguments"] as? String) ?? "",
                hotkey: arguments["hotkey"] as? String,
                integration: (arguments["integration"] as? Bool) ?? false
            )
            if tool.displayName.isEmpty { tool.displayName = id }
            try toolStorage.saveTool(tool)
            return .text(prettyJSON(tool))

        case "update_external_tool":
            let id = try requireString(arguments, "id")
            var tool = try toolStorage.loadTool(id)
            if let dn = arguments["display_name"] as? String { tool.displayName = dn }
            if let exe = arguments["executable_path"] as? String { tool.executablePath = exe }
            if let argv = arguments["arguments"] as? String { tool.arguments = argv }
            if arguments.keys.contains("hotkey") {
                tool.hotkey = arguments["hotkey"] as? String
            }
            if let integ = arguments["integration"] as? Bool { tool.integration = integ }
            try toolStorage.saveTool(tool)
            return .text(prettyJSON(tool))

        case "unregister_external_tool":
            let id = try requireString(arguments, "id")
            try toolStorage.deleteTool(id)
            return .text("Unregistered external tool '\(id)'.")

        case "fire_external_tool":
            let id = try requireString(arguments, "id")
            let tool = try toolStorage.loadTool(id)
            let file = arguments["file"] as? String
            let dryRun = (arguments["dry_run"] as? Bool) ?? false
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
                return .text("Failed to launch '\(id)': \(error)", isError: true)
            }
            return .text(prettyJSON([
                "id": tool.id,
                "executable": exe,
                "argv": argv,
                "launched": true,
            ] as [String: Any]))

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
