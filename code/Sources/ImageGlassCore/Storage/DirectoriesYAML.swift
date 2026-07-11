import Foundation

/// On-disk projection of the directory tree panel's state. One file at
/// `~/Library/Application Support/ImageGlass_Mac/directories.yaml`. The
/// schema lives in `docs/list_of_files.mdx` §3A.2 and the use case at
/// `docs/use_cases/mcp_file.mdx` §4.4 / §6.4 / §7.4.
public struct DirectoriesFile: Sendable, Equatable {
    public var schemaVersion: Int
    public var roots: [RootDirectory]

    /// menus.mdx View ▸ Left File Tree ▸ "Only Show Included Items" —
    /// a window-level view filter over the include model
    /// (include_checks.mdx §6). When `true`, the file-tree panel hides
    /// every row whose resolved `effectiveState` is `.exclude`, showing
    /// only rows that are green-checked `include` or inherit-include
    /// with an all-include chain above them. When `false` (the factory
    /// default for every customer) the panel shows the full hierarchy,
    /// red-X rows included. Persisted here — in the same window-scoped
    /// `directories_window_<N>.yaml` as the include overrides it filters
    /// — so the choice survives a relaunch.
    public var onlyShowIncludedItems: Bool

    /// `mcp_and_filters_on_dirs.mdx` §3.2 / §3.6. `1` is the legacy
    /// shape; `2` adds optional `priority` per filter item. New
    /// files stay at `1` until the engine sees a non-default
    /// priority on any item — at which point the writer bumps to 2
    /// (§3.6 lazy upgrade).
    public static let legacySchemaVersion = 1
    public static let prioritySchemaVersion = 2
    public static let currentSchemaVersion = legacySchemaVersion

    public init(
        schemaVersion: Int = currentSchemaVersion,
        roots: [RootDirectory] = [],
        onlyShowIncludedItems: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.roots = roots
        self.onlyShowIncludedItems = onlyShowIncludedItems
    }

    /// True if any filter item carries a non-default priority. Used
    /// by the writer to lazily upgrade `schema_version` to 2 (§3.6).
    public var anyItemHasNonDefaultPriority: Bool {
        for r in roots {
            for it in r.filter.items where it.priority != 0 {
                return true
            }
        }
        return false
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
        let _trace = PerformanceLog.shared.start("LocalStorage.DirectoriesYAMLEncode")
        defer { _trace.finish() }
        var out = ""
        // §3.6 lazy upgrade: bump to v2 if any item uses a non-default
        // priority, otherwise keep the file at v1 so a no-priority
        // round-trip is byte-identical.
        let effectiveVersion: Int = {
            if file.anyItemHasNonDefaultPriority {
                return max(file.schemaVersion, DirectoriesFile.prioritySchemaVersion)
            }
            return file.schemaVersion
        }()
        out += "schema_version: \(effectiveVersion)\n"
        // View ▸ Left File Tree ▸ "Only Show Included Items". Off by
        // default; emitted only when on so a fresh file (and every
        // customer who never touches the toggle) stays byte-identical.
        if file.onlyShowIncludedItems {
            out += "only_show_included_items: true\n"
        }
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
                    // `id` (spec §4.5) is NOT emitted — it is a pure
                    // function of `pattern + kind + negate + priority`
                    // and is derived on demand via `RootFilterItem.id`.
                    // Skipping it keeps existing v1 YAML byte-stable
                    // through a no-op round-trip.
                }
            }
            if let walked = r.lastWalked {
                out += "    last_walked: \(iso8601(walked))\n"
            }
            // include_checks.mdx §5.2 — only emit when non-default
            // so v1 → v2 upgrades stay byte-identical until the user
            // touches an include override.
            if r.defaultIncludeState != .include {
                out += "    default_include_state: \(r.defaultIncludeState.rawValue)\n"
            }
            // include_checks.mdx §5.3 — flat list of overrides;
            // `inherit` is never written. Empty list omits the
            // block entirely (matching the §5.5 "absence is inherit"
            // rule for whole-root emptiness too).
            if !r.includeOverrides.isEmpty {
                out += "    include_overrides:\n"
                for o in r.includeOverrides where o.state != .inherit {
                    out += "      - path: \(quoteIfNeeded(o.path))\n"
                    out += "        state: \(o.state.rawValue)\n"
                }
            }
        }
        return out
    }

    // MARK: - Decode

    public static func decode(_ text: String) throws -> DirectoriesFile {
        let _trace = PerformanceLog.shared.start("LocalStorage.DirectoriesYAMLDecode")
        defer { _trace.finish() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var schemaVersion = DirectoriesFile.currentSchemaVersion
        var roots: [RootDirectory] = []
        // View ▸ Left File Tree ▸ "Only Show Included Items" — top-level
        // flag; absent means off (the default for every customer).
        var onlyShowIncludedItems = false

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
        // include_checks.mdx §5 — per-root include block.
        var currentDefaultInclude: IncludeState = .include
        var currentOverrides: [IncludeOverrideEntry] = []
        var inOverrides = false
        var currentOverride: IncludeOverrideEntry?

        func flushCurrentOverride() {
            if let o = currentOverride {
                currentOverrides.append(o)
                currentOverride = nil
            }
        }
        func flushCurrentItem() {
            if let it = currentItem { items.append(it); currentItem = nil }
        }
        func flushCurrentRoot() {
            flushCurrentItem()
            flushCurrentOverride()
            guard let p = currentRootPath else { return }
            currentRootFilter.match = match
            currentRootFilter.items = items
            let url = URL(fileURLWithPath: p)
            roots.append(RootDirectory(
                path: url,
                filter: currentRootFilter,
                lastWalked: currentLastWalked,
                tree: nil,
                defaultIncludeState: currentDefaultInclude,
                includeOverrides: currentOverrides
            ))
            currentRootPath = nil
            currentRootFilter = .empty
            currentLastWalked = nil
            items = []
            match = .any
            inFilter = false
            inItems = false
            currentDefaultInclude = .include
            currentOverrides = []
            inOverrides = false
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
                    } else if k == "only_show_included_items" {
                        onlyShowIncludedItems = (v == "true")
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
                    inOverrides = false
                    flushCurrentOverride()
                    continue
                }
                if body == "filter: {}" {
                    inFilter = false
                    continue
                }
                if body == "include_overrides:" {
                    inFilter = false
                    inOverrides = true
                    flushCurrentOverride()
                    continue
                }
                if body == "include_overrides: []" {
                    inFilter = false
                    inOverrides = false
                    flushCurrentOverride()
                    currentOverrides = []
                    continue
                }
                inFilter = false
                flushCurrentOverride()
                inOverrides = false
                if let (k, v) = parseKeyValue(body) {
                    switch k {
                    case "path":
                        currentRootPath = v
                    case "last_walked":
                        currentLastWalked = parseISO8601(v)
                    case "default_include_state":
                        if let s = IncludeState(rawValue: v), s != .inherit {
                            currentDefaultInclude = s
                        }
                    default: break
                    }
                }
                continue
            }

            // include_overrides items at indent 6.
            if inOverrides, indent == 6, body.hasPrefix("- ") {
                flushCurrentOverride()
                let after = String(body.dropFirst(2))
                var entry = IncludeOverrideEntry(path: "", state: .inherit)
                if let (k, v) = parseKeyValue(after) {
                    applyOverride(key: k, value: v, into: &entry)
                }
                currentOverride = entry
                continue
            }
            if inOverrides, indent >= 8, var entry = currentOverride {
                if let (k, v) = parseKeyValue(body) {
                    applyOverride(key: k, value: v, into: &entry)
                    currentOverride = entry
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

        return DirectoriesFile(
            schemaVersion: schemaVersion,
            roots: roots,
            onlyShowIncludedItems: onlyShowIncludedItems
        )
    }

    // MARK: - Helpers

    /// include_checks.mdx §5.3 — `path` and `state` fields on one
    /// `include_overrides[]` entry.
    private static func applyOverride(
        key: String,
        value: String,
        into entry: inout IncludeOverrideEntry
    ) {
        switch key {
        case "path":  entry.path = value
        case "state":
            if let s = IncludeState(rawValue: value) { entry.state = s }
        default: break
        }
    }

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
