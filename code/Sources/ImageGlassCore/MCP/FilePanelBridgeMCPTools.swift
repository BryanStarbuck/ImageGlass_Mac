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
        default:
            return .text("Unknown file-panel-bridge tool: \(name)", isError: true)
        }
    }

    // MARK: - select_file

    private func selectFile(_ args: [String: Any?]) -> MCP.CallToolResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "claude-code"
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
        let corr = MCPAuditLogger.newCorrelationId()
        let client = (args["client"] as? String) ?? "mcp"
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
