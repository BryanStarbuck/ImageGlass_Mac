import Foundation

/// Hand-rolled YAML serializer for the spec-mandated scope file shape.
/// See `docs/use_cases/mcp_file.mdx` §0 (the YAML layout) and §4.4 for the
/// concrete on-disk example.
///
/// We avoid a YAML library dependency: the schema is small and stable, and
/// the shape we have to round-trip is a small subset (block-style mapping
/// at the top level, lists of small mappings under `criteria` and
/// `resolved`, flow-style `[]` for string arrays inside criteria). The
/// encoder and decoder are coupled to that subset deliberately so the
/// on-disk file stays readable. For any field not covered here the
/// encoder falls back to JSON-string encoding (which is valid YAML).
public enum ScopeYAML {

    // MARK: - Encode

    /// Encode a `Scope` to the YAML layout shown in
    /// `docs/use_cases/mcp_file.mdx` §1.3 / §4.4.
    public static func encode(_ scope: Scope) -> String {
        var out = ""
        out += "name: \(quoteIfNeeded(scope.name))\n"
        out += "schema_version: \(scope.schemaVersion)\n"

        if let description = scope.description, !description.isEmpty {
            out += "description: \(quoteIfNeeded(description))\n"
        }

        if scope.criteria.isEmpty {
            out += "criteria: []\n"
        } else {
            out += "criteria:\n"
            for c in scope.criteria {
                out += encodeCriterion(c)
            }
        }

        if let evaluated = scope.lastEvaluated {
            out += "last_evaluated: \(iso8601(evaluated))\n"
        }

        if scope.resolved.isEmpty {
            out += "resolved: []\n"
        } else {
            out += "resolved:\n"
            for r in scope.resolved {
                out += "  - path: \(quoteIfNeeded(r.path))\n"
                if let s = r.size { out += "    size: \(s)\n" }
                if let m = r.modified { out += "    modified: \(iso8601(m))\n" }
                if let d = r.dim, d.count == 2 {
                    out += "    dim: [\(d[0]), \(d[1])]\n"
                }
            }
        }
        return out
    }

    private static func encodeCriterion(_ c: Scope.SourceCriterion) -> String {
        var lines: [String] = []
        lines.append("  - root: \(quoteIfNeeded(c.root))")
        lines.append("    recursive: \(c.recursive ? "true" : "false")")
        if let depth = c.maxDepth {
            lines.append("    max_depth: \(depth)")
        }
        if !c.includeExts.isEmpty {
            lines.append("    include_exts: \(encodeStringFlow(c.includeExts))")
        }
        if !c.excludeExts.isEmpty {
            lines.append("    exclude_exts: \(encodeStringFlow(c.excludeExts))")
        }
        if !c.includeGlobs.isEmpty {
            lines.append("    include_globs: \(encodeStringFlow(c.includeGlobs))")
        }
        if !c.excludeGlobs.isEmpty {
            lines.append("    exclude_globs: \(encodeStringFlow(c.excludeGlobs))")
        }
        if c.includeHidden {
            lines.append("    include_hidden: true")
        }
        if c.followSymlinks {
            lines.append("    follow_symlinks: true")
        }
        if let b = c.bookmark {
            lines.append("    bookmark: \(quoteIfNeeded(b))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func encodeStringFlow(_ items: [String]) -> String {
        let body = items.map { quoteIfNeeded($0) }.joined(separator: ", ")
        return "[\(body)]"
    }

    private static func quoteIfNeeded(_ s: String) -> String {
        // YAML reserves a few characters at the start of a scalar (#, &,
        // *, !, |, >, ', ", %, @, `) and any colon-space inside the value
        // is ambiguous. The simple rule: quote if it contains anything
        // non-trivial.
        if s.isEmpty { return "\"\"" }
        let needs = s.contains(":") || s.contains("#")
            || s.contains("\n") || s.contains("\"")
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.hasPrefix("-") || s.hasPrefix("?")
            || s.hasPrefix("[") || s.hasPrefix("{")
            || s.hasPrefix("&") || s.hasPrefix("*")
            || s.hasPrefix("!") || s.hasPrefix("|")
            || s.hasPrefix(">") || s.hasPrefix("'")
            || s.hasPrefix("%") || s.hasPrefix("@")
            || s.hasPrefix("`")
        if !needs { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: - Decode

    public enum DecodeError: Error, CustomStringConvertible {
        case syntax(line: Int, message: String)
        case missingName
        public var description: String {
            switch self {
            case .syntax(let l, let m): return "YAML syntax error at line \(l): \(m)"
            case .missingName: return "YAML scope is missing `name`."
            }
        }
    }

    /// Decode the subset of YAML used by `encode`. Robust enough to round-
    /// trip files written by `encode`, plus loosely-edited variants where
    /// users hand-fixed a quoted/unquoted value. Not a general YAML parser.
    public static func decode(_ text: String) throws -> Scope {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var name: String?
        var schemaVersion = Scope.currentSchemaVersion
        var description: String?
        var criteria: [Scope.SourceCriterion] = []
        var lastEvaluated: Date?
        var resolved: [Scope.ResolvedFile] = []

        // Parser is a tiny indentation-aware state machine. Two block
        // forms are recognised: top-level `key: value` and the two list
        // sections `criteria:` and `resolved:` whose items are mappings.
        enum Section { case top, criteria, resolved }
        var section: Section = .top
        var currentCriterion: Scope.SourceCriterion?
        var currentResolved: Scope.ResolvedFile?

        func flushPending() {
            if let c = currentCriterion { criteria.append(c); currentCriterion = nil }
            if let r = currentResolved { resolved.append(r); currentResolved = nil }
        }

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // Strip `#` comments outside quoted strings — small subset.
            let stripped = stripComment(line)

            let indent = leadingSpaces(stripped)
            let body = String(stripped.dropFirst(indent))

            // Section heading at top level.
            if indent == 0 {
                flushPending()
                if body == "criteria:" || body == "criteria: []" {
                    section = body == "criteria:" ? .criteria : .top
                    continue
                }
                if body == "resolved:" || body == "resolved: []" {
                    section = body == "resolved:" ? .resolved : .top
                    continue
                }
                section = .top
                if let (k, v) = parseKeyValue(body) {
                    switch k {
                    case "name":           name = v
                    case "schema_version": schemaVersion = Int(v) ?? Scope.currentSchemaVersion
                    case "description":    description = v
                    case "last_evaluated": lastEvaluated = parseISO8601(v)
                    default: break
                    }
                }
                continue
            }

            switch section {
            case .top:
                continue
            case .criteria:
                // Items begin with `  - root: …` (indent 2). Sub-keys are
                // at indent 4.
                if indent == 2, body.hasPrefix("- ") {
                    if let c = currentCriterion { criteria.append(c) }
                    let after = String(body.dropFirst(2))
                    currentCriterion = Scope.SourceCriterion(root: "")
                    if let (k, v) = parseKeyValue(after) {
                        apply(key: k, value: v, into: &currentCriterion!, line: idx)
                    }
                } else if indent >= 4, currentCriterion != nil {
                    if let (k, v) = parseKeyValue(body) {
                        apply(key: k, value: v, into: &currentCriterion!, line: idx)
                    }
                }
            case .resolved:
                if indent == 2, body.hasPrefix("- ") {
                    if let r = currentResolved { resolved.append(r) }
                    let after = String(body.dropFirst(2))
                    currentResolved = Scope.ResolvedFile(path: "")
                    if let (k, v) = parseKeyValue(after) {
                        apply(key: k, value: v, into: &currentResolved!)
                    }
                } else if indent >= 4, currentResolved != nil {
                    if let (k, v) = parseKeyValue(body) {
                        apply(key: k, value: v, into: &currentResolved!)
                    }
                }
            }
        }
        flushPending()

        guard let resolvedName = name else { throw DecodeError.missingName }

        return Scope(
            name: resolvedName,
            schemaVersion: schemaVersion,
            description: description,
            criteria: criteria,
            sort: .init(),
            filter: .init(),
            lastEvaluated: lastEvaluated,
            resolved: resolved
        )
    }

    // MARK: - Parser helpers

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }

    private static func stripComment(_ s: String) -> String {
        var inQuote = false
        var out = ""
        for ch in s {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote {
                break
            }
            out.append(ch)
        }
        // Trim trailing whitespace only — leading whitespace is the indent.
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return out
    }

    private static func parseKeyValue(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        var rest = String(s[s.index(after: colon)...])
        rest = rest.trimmingCharacters(in: .whitespaces)
        rest = unquote(rest)
        return (key, rest)
    }

    private static func unquote(_ s: String) -> String {
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return s
    }

    private static func parseFlowStringList(_ s: String) -> [String]? {
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        let inner = String(s.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        // Split respecting "quoted, items"
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        for ch in inner {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if ch == "," && !inQuote {
                parts.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(cur.trimmingCharacters(in: .whitespaces))
        }
        return parts.map { unquote($0) }
    }

    private static func parseFlowIntList(_ s: String) -> [Int]? {
        guard let strings = parseFlowStringList(s) else { return nil }
        let ints = strings.compactMap { Int($0) }
        return ints.count == strings.count ? ints : nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func apply(
        key: String,
        value: String,
        into c: inout Scope.SourceCriterion,
        line: Int
    ) {
        switch key {
        case "root":            c.root = value
        case "recursive":       c.recursive = (value == "true")
        case "max_depth":       c.maxDepth = Int(value)
        case "include_exts":    c.includeExts = parseFlowStringList(value) ?? []
        case "exclude_exts":    c.excludeExts = parseFlowStringList(value) ?? []
        case "include_globs":   c.includeGlobs = parseFlowStringList(value) ?? []
        case "exclude_globs":   c.excludeGlobs = parseFlowStringList(value) ?? []
        case "include_hidden":  c.includeHidden = (value == "true")
        case "follow_symlinks": c.followSymlinks = (value == "true")
        case "bookmark":        c.bookmark = value.isEmpty ? nil : value
        default: break
        }
    }

    private static func apply(
        key: String,
        value: String,
        into r: inout Scope.ResolvedFile
    ) {
        switch key {
        case "path":     r.path = value
        case "size":     r.size = Int64(value)
        case "modified": r.modified = parseISO8601(value)
        case "dim":      r.dim = parseFlowIntList(value)
        default: break
        }
    }
}
