import Foundation

/// On-disk projection of the directory tree panel's state. One file at
/// `~/Library/Application Support/ImageGlass_Mac/directories.yaml`. The
/// schema lives in `docs/list_of_files.mdx` §3A.2 and the use case at
/// `docs/use_cases/mcp_file.mdx` §4.4 / §6.4 / §7.4.
public struct DirectoriesFile: Sendable, Equatable {
    public var schemaVersion: Int
    public var roots: [RootDirectory]

    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int = currentSchemaVersion, roots: [RootDirectory] = []) {
        self.schemaVersion = schemaVersion
        self.roots = roots
    }
}

/// Hand-rolled YAML codec for the subset described in §3A.2. Same
/// philosophy as `ScopeYAML`: no library dependency, the on-disk form
/// stays human-readable for the `cat` verify steps.
public enum DirectoriesYAML {

    public enum DecodeError: Error, CustomStringConvertible {
        case syntax(line: Int, message: String)
        case invalidFilter(String)
        public var description: String {
            switch self {
            case .syntax(let l, let m): return "directories.yaml syntax error at line \(l): \(m)"
            case .invalidFilter(let m): return "invalid filter: \(m)"
            }
        }
    }

    // MARK: - Encode

    public static func encode(_ file: DirectoriesFile) -> String {
        var out = ""
        out += "schema_version: \(file.schemaVersion)\n"
        if file.roots.isEmpty {
            out += "root_directories: []\n"
            return out
        }
        out += "root_directories:\n"
        for r in file.roots {
            out += "  - path: \(quoteIfNeeded(r.path.path))\n"
            out += "    filter:\n"
            // Only emit `match:` if non-default, but ScopeYAML always emitted
            // recursive; the tour's verify steps show `match: any` only in
            // §3A.2 and `items: []` shown verbatim in §3A.9 and §4.4. We
            // emit `items:` unconditionally (empty list → flow style).
            if r.filter.match != .any {
                out += "      match: \(r.filter.match.rawValue)\n"
            }
            if r.filter.items.isEmpty {
                out += "      items: []\n"
            } else {
                out += "      items:\n"
                for it in r.filter.items {
                    out += "        - pattern: \(quoteIfNeeded(it.pattern))\n"
                    if it.kind != .glob {
                        out += "          kind: \(it.kind.rawValue)\n"
                    }
                    if it.negate {
                        out += "          negate: true\n"
                    }
                    // `priority: 0` is the default; only emit when
                    // non-default to keep `schema_version: 1` files
                    // byte-identical (spec §3.6 lazy-upgrade).
                    if it.priority != 0 {
                        out += "          priority: \(it.priority)\n"
                    }
                }
            }
            if let walked = r.lastWalked {
                out += "    last_walked: \(iso8601(walked))\n"
            }
        }
        return out
    }

    // MARK: - Decode

    public static func decode(_ text: String) throws -> DirectoriesFile {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var schemaVersion = DirectoriesFile.currentSchemaVersion
        var roots: [RootDirectory] = []

        // State machine — we step through the indented blocks under
        // `root_directories:`.
        var currentRootPath: String?
        var currentRootFilter: RootFilter = .empty
        var currentLastWalked: Date?

        var currentItem: RootFilterItem?
        var items: [RootFilterItem] = []
        var match: RootFilter.Match = .any
        var inRootDirs = false
        var inFilter = false
        var inItems = false

        func flushCurrentItem() {
            if let it = currentItem { items.append(it); currentItem = nil }
        }
        func flushCurrentRoot() {
            flushCurrentItem()
            guard let p = currentRootPath else { return }
            currentRootFilter.match = match
            currentRootFilter.items = items
            let url = URL(fileURLWithPath: p)
            roots.append(RootDirectory(
                path: url,
                filter: currentRootFilter,
                lastWalked: currentLastWalked,
                tree: nil
            ))
            currentRootPath = nil
            currentRootFilter = .empty
            currentLastWalked = nil
            items = []
            match = .any
            inFilter = false
            inItems = false
        }

        for (idx, rawLine) in lines.enumerated() {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let stripped = stripComment(rawLine)
            let indent = leadingSpaces(stripped)
            let body = String(stripped.dropFirst(indent))

            if indent == 0 {
                flushCurrentRoot()
                inRootDirs = false
                if body == "root_directories:" {
                    inRootDirs = true
                    continue
                }
                if body == "root_directories: []" {
                    inRootDirs = false
                    continue
                }
                if let (k, v) = parseKeyValue(body) {
                    if k == "schema_version" {
                        schemaVersion = Int(v) ?? DirectoriesFile.currentSchemaVersion
                    }
                }
                continue
            }

            guard inRootDirs else { continue }

            // `  - path: …` opens a new root.
            if indent == 2, body.hasPrefix("- ") {
                flushCurrentRoot()
                let after = String(body.dropFirst(2))
                if let (k, v) = parseKeyValue(after), k == "path" {
                    currentRootPath = v
                }
                continue
            }

            // Sub-keys of the current root at indent 4.
            if indent == 4 {
                inItems = false
                if body == "filter:" {
                    inFilter = true
                    continue
                }
                if body == "filter: {}" {
                    inFilter = false
                    continue
                }
                inFilter = false
                if let (k, v) = parseKeyValue(body) {
                    switch k {
                    case "path":
                        currentRootPath = v
                    case "last_walked":
                        currentLastWalked = parseISO8601(v)
                    default: break
                    }
                }
                continue
            }

            // Filter block at indent 6.
            if indent == 6, inFilter {
                if body == "items:" {
                    inItems = true
                    flushCurrentItem()
                    continue
                }
                if body == "items: []" {
                    inItems = false
                    items = []
                    continue
                }
                if let (k, v) = parseKeyValue(body), k == "match" {
                    match = RootFilter.Match(rawValue: v) ?? .any
                }
                continue
            }

            // Filter item rows.
            if inFilter, inItems {
                if indent == 8, body.hasPrefix("- ") {
                    flushCurrentItem()
                    let after = String(body.dropFirst(2))
                    var it = RootFilterItem(pattern: "")
                    if let (k, v) = parseKeyValue(after) {
                        applyItem(key: k, value: v, into: &it, line: idx)
                    }
                    currentItem = it
                    continue
                }
                if indent >= 10, var it = currentItem {
                    if let (k, v) = parseKeyValue(body) {
                        applyItem(key: k, value: v, into: &it, line: idx)
                        currentItem = it
                    }
                    continue
                }
            }
        }
        flushCurrentRoot()

        return DirectoriesFile(schemaVersion: schemaVersion, roots: roots)
    }

    // MARK: - Helpers

    private static func applyItem(
        key: String,
        value: String,
        into it: inout RootFilterItem,
        line: Int
    ) {
        switch key {
        case "pattern": it.pattern = value
        case "kind":
            if let k = RootFilterItem.ItemKind(rawValue: value) { it.kind = k }
        case "negate":
            it.negate = (value == "true")
        case "priority":
            // `mcp_and_filters_on_dirs.mdx` §3.2 — clamped to
            // -1000…1000 by `RootFilterItem.init`. Unparseable input
            // silently falls back to the existing priority (0 by
            // default for new items).
            if let p = Int(value.trimmingCharacters(in: .whitespaces)) {
                it.priority = max(-1000, min(1000, p))
            }
        default: break
        }
    }

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s { if ch == " " { n += 1 } else { break } }
        return n
    }

    private static func stripComment(_ s: String) -> String {
        var inQuote = false
        var out = ""
        for ch in s {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            out.append(ch)
        }
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

    private static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needs = s.contains(":") || s.contains("#") || s.contains("\n")
            || s.contains("\"")
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.hasPrefix("-") || s.hasPrefix("?")
            || s.hasPrefix("[") || s.hasPrefix("{")
            || s.hasPrefix("&") || s.hasPrefix("*")
            || s.hasPrefix("!") || s.hasPrefix("|")
            || s.hasPrefix(">") || s.hasPrefix("'")
            || s.hasPrefix("%") || s.hasPrefix("@") || s.hasPrefix("`")
        if !needs { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
