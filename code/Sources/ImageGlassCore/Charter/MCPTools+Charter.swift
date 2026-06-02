import Foundation

/// Charter-goal MCP tools: rule sets, scope chaining, audit log, diff,
/// import/export. Designed as an extension so the original `MCPTools.swift`
/// only needs a one-line "also check here" change.
public extension MCPTools {

    /// All charter tool descriptors. Returned by `descriptors()` after the
    /// base tools list.
    func charterDescriptors() -> [MCP.ToolDescriptor] {
        [
            // -- Rule sets --
            .init(
                name: "list_rule_sets",
                description: "List the names of all reusable rule sets stored in Local Storage.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_rule_set",
                description: "Get the full definition of a named rule set.",
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
                name: "create_rule_set",
                description: "Create a reusable rule set that any scope can attach to. Plain-text JSON on disk.",
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
                        "hidden_files": ["type": "boolean"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "delete_rule_set",
                description: "Delete a named rule set. Scopes referencing it will silently skip it on next evaluation.",
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
                name: "attach_rule_set",
                description: "Add a rule set reference to a scope (idempotent).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "scope": ["type": "string"],
                        "rule_set": ["type": "string"],
                    ],
                    "required": ["scope", "rule_set"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "detach_rule_set",
                description: "Remove a rule set reference from a scope.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "scope": ["type": "string"],
                        "rule_set": ["type": "string"],
                    ],
                    "required": ["scope", "rule_set"],
                    "additionalProperties": false,
                ])
            ),

            // -- Scope chaining --
            .init(
                name: "set_inheritance",
                description: "Replace the list of parent scope names this scope inherits rules from. Cycles are auto-broken at evaluation time.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "inherits_from": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["name", "inherits_from"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_effective_rules",
                description: "Return the composed (include, exclude, sources) rules for a scope after rule-set + inheritsFrom chaining, without evaluating files.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),

            // -- Audit / diff --
            .init(
                name: "get_audit_log",
                description: "Return the last N evaluation entries for a scope (JSONL audit log on disk).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 1000],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_last_diff",
                description: "Return the (added, removed) file lists captured on the scope's most recent evaluation.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),

            // -- Import / export --
            .init(
                name: "export_scope",
                description: "Export a scope and its referenced rule sets / parent scopes as a single plain-text JSON bundle.",
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
                name: "import_scope",
                description: "Install a previously-exported ScopeBundle (JSON text) into Local Storage. Pass overwrite=true to replace existing scope.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "bundle_json": ["type": "string"],
                        "overwrite": ["type": "boolean"],
                    ],
                    "required": ["bundle_json"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    /// Returns `nil` when `name` is not a charter tool so the caller can fall
    /// through to the base dispatcher.
    func callCharter(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult? {
        switch name {

        // -- Rule sets --
        case "list_rule_sets":
            let names = try RuleSetStorage.shared.listRuleSets()
            return .text(charterJSON(["rule_sets": names]))

        case "get_rule_set":
            let n = try charterRequireString(arguments, "name")
            let rs = try RuleSetStorage.shared.loadRuleSet(n)
            return .text(charterJSON(rs))

        case "create_rule_set":
            let n = try charterRequireString(arguments, "name")
            if RuleSetStorage.shared.ruleSetExists(n) {
                return .text("Rule set '\(n)' already exists.", isError: true)
            }
            var rs = RuleSet(name: n)
            rs.description = arguments["description"] as? String
            if let dirs = arguments["directories"] as? [Any?] {
                rs.include.directories = dirs.compactMap { $0 as? String }
            }
            if let recursive = arguments["recursive"] as? Bool {
                rs.include.recursive = recursive
            }
            if let exts = arguments["extensions"] as? [Any?] {
                rs.include.extensions = exts.compactMap { $0 as? String }
            }
            if let globs = arguments["include_globs"] as? [Any?] {
                rs.include.globs = globs.compactMap { $0 as? String }
            }
            if let exGlobs = arguments["exclude_globs"] as? [Any?] {
                rs.exclude.globs = exGlobs.compactMap { $0 as? String }
            }
            if let hidden = arguments["hidden_files"] as? Bool {
                rs.exclude.hiddenFiles = hidden
            }
            try RuleSetStorage.shared.saveRuleSet(rs)
            return .text(charterJSON(rs))

        case "delete_rule_set":
            let n = try charterRequireString(arguments, "name")
            try RuleSetStorage.shared.deleteRuleSet(n)
            return .text("Deleted rule set '\(n)'.")

        case "attach_rule_set":
            let scopeName = try charterRequireString(arguments, "scope")
            let rsName = try charterRequireString(arguments, "rule_set")
            var scope = try storage.loadScope(scopeName)
            var refs = scope.ruleSets ?? []
            if !refs.contains(rsName) { refs.append(rsName) }
            scope.ruleSets = refs.isEmpty ? nil : refs
            try storage.saveScope(scope)
            return .text(charterJSON(scope))

        case "detach_rule_set":
            let scopeName = try charterRequireString(arguments, "scope")
            let rsName = try charterRequireString(arguments, "rule_set")
            var scope = try storage.loadScope(scopeName)
            var refs = scope.ruleSets ?? []
            refs.removeAll { $0 == rsName }
            scope.ruleSets = refs.isEmpty ? nil : refs
            try storage.saveScope(scope)
            return .text(charterJSON(scope))

        // -- Scope chaining --
        case "set_inheritance":
            let n = try charterRequireString(arguments, "name")
            let parents = try charterRequireStringArray(arguments, "inherits_from")
            var scope = try storage.loadScope(n)
            scope.inheritsFrom = parents.isEmpty ? nil : parents
            try storage.saveScope(scope)
            return .text(charterJSON(scope))

        case "get_effective_rules":
            let n = try charterRequireString(arguments, "name")
            let scope = try storage.loadScope(n)
            let eff = ScopeChain.compose(scope)
            let payload: [String: Any] = [
                "name": scope.name,
                "sources": eff.sources,
                "include": [
                    "directories": eff.include.directories,
                    "recursive": eff.include.recursive,
                    "globs": eff.include.globs,
                    "extensions": eff.include.extensions,
                ],
                "exclude": [
                    "globs": eff.exclude.globs,
                    "hiddenFiles": eff.exclude.hiddenFiles,
                ],
            ]
            return .text(charterJSON(payload))

        // -- Audit / diff --
        case "get_audit_log":
            let n = try charterRequireString(arguments, "name")
            let limit = (arguments["limit"] as? Int) ?? 50
            let entries = try ScopeAuditLog.shared.tail(scopeName: n, limit: limit)
            // Encode as a Codable wrapper so `ScopeAuditEntry` values render
            // through `JSONEncoder`, not `JSONSerialization`.
            struct Payload: Encodable { let scope: String; let entries: [ScopeAuditEntry] }
            return .text(charterJSON(Payload(scope: n, entries: entries)))

        case "get_last_diff":
            let n = try charterRequireString(arguments, "name")
            let scope = try storage.loadScope(n)
            if let d = scope.lastDiff {
                return .text(charterJSON(d))
            } else {
                return .text(charterJSON([
                    "added": [] as [String],
                    "removed": [] as [String],
                    "previousCount": scope.resolvedFiles.count,
                    "currentCount": scope.resolvedFiles.count,
                    "note": "No prior diff recorded for this scope.",
                ] as [String: Any]))
            }

        // -- Import / export --
        case "export_scope":
            let n = try charterRequireString(arguments, "name")
            let bundle = try ScopeBundleService.export(scopeName: n)
            let json = try ScopeBundleService.encodeJSON(bundle)
            return .text(json)

        case "import_scope":
            let json = try charterRequireString(arguments, "bundle_json")
            let overwrite = (arguments["overwrite"] as? Bool) ?? false
            let bundle = try ScopeBundleService.decodeJSON(json)
            let installed = try ScopeBundleService.install(bundle, overwrite: overwrite)
            return .text(charterJSON([
                "name": installed.name,
                "ruleSetsInstalled": bundle.ruleSets.map { $0.name },
                "parentsInstalled": bundle.parents.map { $0.name },
            ] as [String: Any]))

        default:
            return nil
        }
    }

    // MARK: - Helpers
    // The base type's helpers are `private` — not visible here. We use
    // `charter`-prefixed names so they coexist cleanly inside the same type.

    internal func charterRequireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    internal func charterRequireStringArray(_ args: [String: Any?], _ key: String) throws -> [String] {
        guard let v = args[key] as? [Any?] else {
            throw MCPToolError.missingArgument(key)
        }
        return v.compactMap { $0 as? String }
    }

    internal func charterJSON<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(value)
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("charterJSON: UTF-8 decode of encoded JSON failed",
                         class: "MCPTools+Charter")
        } catch {
            ErrorLog.log("charterJSON: JSONEncoder.encode failed for \(type(of: value))",
                         error: error,
                         class: "MCPTools+Charter")
        }
        return "{}"
    }

    internal func charterJSON(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("charterJSON(dict): UTF-8 decode of serialized JSON failed",
                         class: "MCPTools+Charter")
        } catch {
            ErrorLog.log("charterJSON(dict): JSONSerialization.data failed",
                         error: error,
                         class: "MCPTools+Charter")
        }
        return "{}"
    }
}
