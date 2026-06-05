import Foundation

/// Append-only writer for the spec-mandated activity log at
/// `~/Library/Application Support/ImageGlass_Mac/log.log`. Every MCP
/// call and every scope re-evaluation lands here as a single key=value
/// line. See `docs/use_cases/mcp_file.mdx` §0 / §4 / §8 / §10 and
/// `docs/error_handling.mdx` §4.2 for the line grammar this implements.
///
/// Format (one line per record):
///
/// ```
/// ts=<ISO8601-ms> tool=mcp.<name> name=<scope> client=<id> corr=<8> ok=true [extra=…]
/// ts=<ISO8601-ms> app=<event>      name=<scope>            corr=<8> count=<n> elapsed_ms=<n>
/// ts=<ISO8601-ms> app=startup msg="layout=Browser scope=default"
/// ```
///
/// The writer is process-wide (`shared`) and serializes appends behind an
/// internal lock so concurrent MCP calls do not interleave lines.
public final class MCPAuditLogger: @unchecked Sendable {

    public static let shared = MCPAuditLogger()

    /// Set to a non-nil URL to override the default log path (used by
    /// `MacScopeStore` tests so they can write to a temp directory).
    public var overrideLogFile: URL?

    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter

    public init(overrideLogFile: URL? = nil) {
        self.overrideLogFile = overrideLogFile
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = f
    }

    /// Resolve the file path the writer will append to. Honors
    /// `overrideLogFile` (for tests), otherwise the spec-mandated path.
    public var logFileURL: URL {
        overrideLogFile ?? AppPaths.macLogFile
    }

    /// Generate a short correlation id (8 hex chars) so a paired
    /// `tool=mcp.…` and `app=scope.evaluate …` line can be joined.
    public static func newCorrelationId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Write one record. `pairs` is appended after `ts=…` in the order
    /// given so the line stays human-readable (`tool=…` first, then
    /// `name=…`, then everything else).
    public func log(_ pairs: [(String, String)]) {
        var line = "ts=\(dateFormatter.string(from: Date()))"
        for (k, v) in pairs {
            line += " "
            line += k
            line += "="
            line += format(value: v)
        }
        line += "\n"
        guard let data = line.data(using: .utf8) else {
            ErrorLog.log("failed to encode audit log line as UTF-8",
                         class: "MCPAuditLogger")
            return
        }
        appendData(data)
    }

    /// Convenience for a successful MCP call. Records
    /// `tool=mcp.<name> name=<scope> client=<client> corr=<corr> ok=true`
    /// plus any `extra` key/value pairs supplied by the caller.
    public func logMCPCall(
        toolName: String,
        scope: String?,
        client: String,
        corr: String,
        ok: Bool,
        err: String? = nil,
        extra: [(String, String)] = []
    ) {
        var pairs: [(String, String)] = [("tool", "mcp.\(toolName)")]
        if let scope { pairs.append(("name", scope)) }
        pairs.append(("client", client))
        pairs.append(("corr", corr))
        pairs.append(("ok", ok ? "true" : "false"))
        if let err { pairs.append(("err", err)) }
        pairs.append(contentsOf: extra)
        log(pairs)
    }

    /// Convenience for a multi-scope walk (the legacy `scopes/<name>.json`
    /// path; see `list_of_files.mdx` §3). Records
    /// `app=scope.evaluate name=<scope> count=<n> elapsed_ms=<n> corr=<corr>`.
    /// The directory-tree panel uses `logDirectoryWalk` below instead.
    public func logScopeEvaluate(
        scope: String,
        count: Int,
        elapsedMs: Int,
        corr: String
    ) {
        log([
            ("app", "scope.evaluate"),
            ("name", scope),
            ("count", String(count)),
            ("elapsed_ms", String(elapsedMs)),
            ("corr", corr),
        ])
    }

    /// Variant used by the directory-tree MCP tools
    /// (`docs/use_cases/mcp_file.mdx` §4.4 / §5.4 / §6.4 / §7.4 /
    /// §10.6). The line carries
    /// `tool=mcp.<name> path=<path> client=<id> corr=<corr> ok=true|false`
    /// — no `name=` scope field, because directories.yaml is not a
    /// scope file.
    public func logDirectoryToolCall(
        toolName: String,
        path: String?,
        client: String,
        corr: String,
        ok: Bool,
        err: String? = nil,
        extra: [(String, String)] = []
    ) {
        var pairs: [(String, String)] = [("tool", "mcp.\(toolName)")]
        if let path { pairs.append(("path", path)) }
        pairs.append(("client", client))
        pairs.append(("corr", corr))
        pairs.append(("ok", ok ? "true" : "false"))
        if let err { pairs.append(("err", err)) }
        pairs.append(contentsOf: extra)
        log(pairs)
    }

    /// `app=directory.walk path=<path> count=<n> elapsed_ms=<n> corr=<corr>`
    /// — paired with every successful `add_directory` /
    /// `refresh_directory` call. See §4.4 / §10.6.
    public func logDirectoryWalk(
        path: String,
        count: Int,
        elapsedMs: Int,
        corr: String
    ) {
        log([
            ("app", "directory.walk"),
            ("path", path),
            ("count", String(count)),
            ("elapsed_ms", String(elapsedMs)),
            ("corr", corr),
        ])
    }

    /// `app=directory.refilter roots=<n> visible_delta=<±n> elapsed_ms=<n> corr=<corr>`
    /// — paired with every successful filter change. See §6.4 / §7.4.
    /// `visibleDelta` is signed: negative if fewer files now visible.
    public func logDirectoryRefilter(
        roots: Int,
        visibleDelta: Int,
        elapsedMs: Int,
        corr: String
    ) {
        let signed = visibleDelta > 0 ? "+\(visibleDelta)" : String(visibleDelta)
        log([
            ("app", "directory.refilter"),
            ("roots", String(roots)),
            ("visible_delta", signed),
            ("elapsed_ms", String(elapsedMs)),
            ("corr", corr),
        ])
    }

    /// `app=panel.auto_select_first path=<path> corr=<corr> reason=<reason>`
    /// — see §10.6. No `scope=` field; `directories.yaml` is the only
    /// source.
    public func logAutoSelectFirst(
        path: String,
        corr: String,
        reason: String
    ) {
        log([
            ("app", "panel.auto_select_first"),
            ("path", path),
            ("corr", corr),
            ("reason", reason),
        ])
    }

    /// `tool=slideshow.toggle on=<bool> interval=<sec> source=<id> corr=<corr> ok=<bool> [err=…]`
    /// — see slideshow.mdx §1.4 / §3.4 / §8.4. `source` is one of
    /// `key:S`, `key:Space`, `menu:View`, `mcp:set_slideshow`, so an
    /// external auditor can trace which surface drove the toggle.
    public func logSlideshowToggle(
        on: Bool,
        interval: Double,
        source: String,
        corr: String,
        ok: Bool,
        err: String? = nil
    ) {
        var pairs: [(String, String)] = [
            ("tool", "slideshow.toggle"),
            ("on", on ? "true" : "false"),
            ("interval", String(format: "%.1f", interval)),
            ("source", source),
            ("corr", corr),
            ("ok", ok ? "true" : "false"),
        ]
        if let err { pairs.append(("err", err)) }
        log(pairs)
    }

    /// `app=slideshow.advance from=<path> to=<path> interval=<sec>
    /// zoom_mode=<mode> [wrap=true] corr=<corr>` — emitted on every
    /// successful advance. See slideshow.mdx §2.4 / §6.6 / §7.4.
    public func logSlideshowAdvance(
        from: String,
        to: String,
        interval: Double,
        zoomMode: String,
        wrap: Bool,
        corr: String
    ) {
        var pairs: [(String, String)] = [
            ("app", "slideshow.advance"),
            ("from", from),
            ("to", to),
            ("interval", String(format: "%.1f", interval)),
            ("zoom_mode", zoomMode),
        ]
        if wrap { pairs.append(("wrap", "true")) }
        pairs.append(("corr", corr))
        log(pairs)
    }

    /// `app=slideshow.stop reason=<reason> advances=<n> elapsed_s=<n.n>
    /// corr=<corr>` — emitted exactly once per slideshow run. Reasons:
    /// `user_toggle` (S key, Space, menu, or MCP off-call),
    /// `end_of_list` (loop=false reached the end),
    /// `no_files_available` (start was attempted with an empty list,
    /// paired only with the matching toggle line of the same `corr`).
    public func logSlideshowStop(
        reason: String,
        advances: Int,
        elapsedSeconds: Double,
        corr: String
    ) {
        log([
            ("app", "slideshow.stop"),
            ("reason", reason),
            ("advances", String(advances)),
            ("elapsed_s", String(format: "%.1f", elapsedSeconds)),
            ("corr", corr),
        ])
    }

    /// `app=settings.write key=<dotted-key> old=<value> new=<value>
    /// source=<id> corr=<corr>` — settle-only audit per
    /// slideshow.mdx §4.5. Live slider drags are debounced; only the
    /// final committed value reaches this line.
    public func logSettingsWrite(
        key: String,
        old: String,
        new: String,
        source: String,
        corr: String
    ) {
        log([
            ("app", "settings.write"),
            ("key", key),
            ("old", old),
            ("new", new),
            ("source", source),
            ("corr", corr),
        ])
    }

    /// `app=startup msg="layout=Browser directories=<n>"` — see §1.3.
    public func logStartup(layout: String, directoryCount: Int) {
        log([
            ("app", "startup"),
            ("msg", "layout=\(layout) directories=\(directoryCount)"),
        ])
    }

    /// `app=tree.walk_start path=<path> corr=<corr>` — emitted immediately
    /// before each background walk begins. Paired with `app=directory.walk`
    /// on completion so walk duration and any gap between start and the
    /// notification post are visible in the log.
    public func logTreeWalkStart(path: String, corr: String) {
        log([
            ("app", "tree.walk_start"),
            ("path", path),
            ("corr", corr),
        ])
    }

    /// `app=tree.node type=<type> path=<full_path> corr=<corr>` — one line
    /// per node added to the in-memory tree during a walk. `type` is
    /// `directory`, `image`, `svg`, or `video`. Written after the walk
    /// completes so concurrent root walks don't interleave their node lines.
    public func logTreeNode(type: String, path: String, corr: String) {
        log([
            ("app", "tree.node"),
            ("type", type),
            ("path", path),
            ("corr", corr),
        ])
    }

    /// `app=tree.walk_failed path=<path> corr=<corr>` — emitted when
    /// `walkSync` returns a nil tree, meaning the root path did not exist
    /// or was not a directory at walk time.
    public func logTreeWalkFailed(path: String, corr: String) {
        log([
            ("app", "tree.walk_failed"),
            ("path", path),
            ("corr", corr),
        ])
    }

    // MARK: - File I/O

    private func appendData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let url = logFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // If the parent directory cannot be created (sandbox, read-only
            // volume) the log line is silently dropped — the writer must
            // never throw, because MCP tool callers treat logging as a
            // best-effort audit trail rather than part of the call's
            // correctness contract.
            ErrorLog.log("could not create audit log parent directory \(url.deletingLastPathComponent().path)",
                         error: error,
                         class: "MCPAuditLogger")
            return
        }
        if !fm.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                ErrorLog.log("failed to create audit log at \(url.path)",
                             error: error,
                             class: "MCPAuditLogger")
            }
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            ErrorLog.log("failed to append to audit log at \(url.path)",
                         error: error,
                         class: "MCPAuditLogger")
            return
        }
    }

    /// Quote a value if it contains whitespace or `=` so the grep-able
    /// `tool=mcp.update_scope` form stays parseable.
    private func format(value: String) -> String {
        if value.contains(" ") || value.contains("=") || value.contains("\t") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
