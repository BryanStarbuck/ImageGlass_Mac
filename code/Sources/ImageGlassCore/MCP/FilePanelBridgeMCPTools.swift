import Foundation

/// MCP tools that bridge the file panel UI state to clients —
/// `select_file` (referenced in `docs/use_cases/mcp_file.mdx` §2.4 /
/// §5.3 / §10) and `panel.set_view_mode` (§3). Lives in its own
/// subsystem alongside `DirectoriesMCPTools` so the directory-store
/// surface can evolve independently of the GUI-bridge surface.
///
/// Each tool writes a small hint file under
/// `~/Library/Application Support/ImageGlass_Mac/` so the SwiftUI app
/// can pick the change up via `FileWatcher`, then emits a JSON-RPC
/// `notifications/imageglass/*` push event so MCP clients (Claude Code)
/// can react too.
public struct FilePanelBridgeMCPTools {

    public let logger: MCPAuditLogger
    public let notifier: MCPNotificationBus

    /// Tool names this subsystem owns. The dispatcher in `MCPTools.call`
    /// checks membership and routes here.
    public static let toolNames: Set<String> = [
        "select_file",
        "panel.set_view_mode",
        "set_slideshow",
    ]

    public init(
        logger: MCPAuditLogger = .shared,
        notifier: MCPNotificationBus = .shared
    ) {
        self.logger = logger
        self.notifier = notifier
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "select_file",
                description: """
                    Programmatically select a file in the file panel. The \
                    selection is mirrored to `selection.txt` so the GUI \
                    watcher reacts, and a JSON-RPC \
                    `notifications/imageglass/selection_changed` event is \
                    emitted to every connected MCP client \
                    (mcp_file.mdx §2 / §10).
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path":   ["type": "string"],
                        "client": ["type": "string"],
                    ] as [String: Any],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_slideshow",
                description: """
                    Toggle the slideshow on or off and optionally override \
                    the interval for the current run (slideshow.mdx §12). \
                    Writes a hint to `slideshow.txt` that the GUI watches; \
                    the controller picks it up within ~250 ms and produces \
                    the same `tool=slideshow.toggle source=mcp:set_slideshow` \
                    audit line as the `S` key path. A passed `interval` is \
                    a one-shot override — it is NOT written to settings.json.
                    """,
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "on":       ["type": "boolean"],
                        "interval": [
                            "type":    "number",
                            "minimum": 1,
                            "maximum": 600,
                        ] as [String: Any],
                        "client":   ["type": "string"],
                    ] as [String: Any],
                    "required": ["on"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "panel.set_view_mode",
                description: """
                    Switch the file panel's view mode (mcp_file.mdx §3). \
                    Valid: strip, grid, details, tree, scroller. Persists \
                    to `panel_view_mode.txt`; the GUI's view-mode watcher \
                    picks it up within ~250 ms.
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
        case "select_file":         return selectFile(arguments)
        case "panel.set_view_mode": return setPanelViewMode(arguments)
        case "set_slideshow":       return setSlideshow(arguments)
        default:
            return .text("Unknown file-panel-bridge tool: \(name)", isError: true)
        }
    }

    // MARK: - set_slideshow

    private func setSlideshow(_ args: [String: Any?]) -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.set_slideshow",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let on = args["on"] as? Bool else {
            logger.logDirectoryToolCall(
                toolName: "set_slideshow", path: nil,
                client: client, corr: corr, ok: false, err: "missing_on"
            )
            return .text("Missing required boolean `on`.", isError: true)
        }
        // Optional one-shot interval override. Validated here so the GUI
        // side can trust the parsed file.
        var interval: Double? = nil
        if let raw = args["interval"] {
            if let d = raw as? Double {
                interval = d
            } else if let i = raw as? Int {
                interval = Double(i)
            } else if let s = raw as? String, let d = Double(s) {
                interval = d
            }
            if let i = interval, !(i >= 1 && i <= 600) {
                logger.logDirectoryToolCall(
                    toolName: "set_slideshow", path: nil,
                    client: client, corr: corr, ok: false, err: "invalid_interval"
                )
                return .text(
                    "Invalid `interval`: must be a number between 1 and 600.",
                    isError: true
                )
            }
        }

        try? AppPaths.ensureMacDirectories()
        let file = AppPaths.macAppSupportDir
            .appendingPathComponent("slideshow.txt")
        // Plain-text format the GUI watcher parses: one or two
        // whitespace-separated `key=value` tokens.
        var body = "on=\(on ? "true" : "false") corr=\(corr)"
        if let i = interval {
            body += String(format: " interval=%.1f", i)
        }
        body += "\n"
        try? body.data(using: .utf8)?.write(to: file, options: .atomic)

        var extra: [(String, String)] = [
            ("on", on ? "true" : "false"),
        ]
        if let i = interval {
            extra.append(("interval", String(format: "%.1f", i)))
            extra.append(("persisted", "false"))
        }
        logger.logDirectoryToolCall(
            toolName: "set_slideshow", path: nil,
            client: client, corr: corr, ok: true,
            extra: extra
        )
        var responseDict: [String: Any] = ["on": on, "corr": corr]
        if let i = interval { responseDict["interval"] = i }
        return .text(prettyJSON(responseDict))
    }

    // MARK: - select_file

    private func selectFile(_ args: [String: Any?]) -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "claude-code"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.select_file",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            logger.logDirectoryToolCall(
                toolName: "select_file", path: nil,
                client: client, corr: corr, ok: false, err: "missing_path"
            )
            return .text("Missing `path`.", isError: true)
        }
        let path = AppPaths.expandTilde(raw)
        try? AppPaths.ensureMacDirectories()
        let selectionFile = AppPaths.macAppSupportDir
            .appendingPathComponent("selection.txt")
        try? path.data(using: .utf8)?.write(to: selectionFile, options: .atomic)
        notifier.emitSelectionChanged(path: path, corr: corr)
        logger.logDirectoryToolCall(
            toolName: "select_file", path: path,
            client: client, corr: corr, ok: true
        )
        return .text(prettyJSON(["path": path, "corr": corr] as [String: Any]))
    }

    // MARK: - panel.set_view_mode

    private static let validViewModes: Set<String> = [
        "strip", "grid", "details", "tree", "scroller",
    ]

    private func setPanelViewMode(_ args: [String: Any?]) -> MCP.CallToolResult {
        let client = (args["client"] as? String) ?? "mcp"
        let _trace = PerformanceLog.shared.start(
            "MCP.ToolCall.panel.set_view_mode",
            extra: [("client", client)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let mode = args["mode"] as? String,
              Self.validViewModes.contains(mode) else {
            logger.logDirectoryToolCall(
                toolName: "panel.set_view_mode", path: nil,
                client: client, corr: corr, ok: false, err: "invalid_mode"
            )
            return .text(
                "Invalid `mode`. Valid: strip, grid, details, tree, scroller.",
                isError: true
            )
        }
        try? AppPaths.ensureMacDirectories()
        let modeFile = AppPaths.macAppSupportDir
            .appendingPathComponent("panel_view_mode.txt")
        try? mode.data(using: .utf8)?.write(to: modeFile, options: .atomic)
        notifier.emitViewModeChanged(mode: mode, corr: corr)
        logger.logDirectoryToolCall(
            toolName: "panel.set_view_mode", path: nil,
            client: client, corr: corr, ok: true,
            extra: [("mode", mode)]
        )
        return .text(prettyJSON(["mode": mode, "corr": corr] as [String: Any]))
    }

    // MARK: - Helpers

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
