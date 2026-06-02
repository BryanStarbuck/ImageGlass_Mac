import Foundation

/// MCP tool descriptors and dispatch for the panel framework. Spec §9.
///
/// These tools operate on the on-disk `layout.json` via `LayoutStore`. The
/// app picks the change up via `FSEventStream` (spec §6.4) — there is no
/// direct GUI dependency here, which means the MCP server can run as a
/// sidecar process and still drive the layout.
public struct PanelMCPTools: Sendable {

    public let store: LayoutStore

    public init(store: LayoutStore = .shared) {
        self.store = store
    }

    /// Tool names this subsystem owns. The top-level `MCPTools.call` checks
    /// membership and dispatches here so it stays focused on scopes.
    public static let toolNames: Set<String> = [
        "list_panels",
        "show_panel",
        "hide_panel",
        "move_panel",
        "set_panel_size",
        "tab_panels",
        "untab_panel",
        "apply_layout_preset",
        "save_current_layout",
        "delete_layout_preset",
        "list_layout_presets",
        "get_layout_state",
        "set_layout_state",
    ]

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "list_panels",
                description: "List every registered panel with id, title, icon, current position (or 'hidden'), and floating frame if floating. See panels.mdx §9.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "show_panel",
                description: "Show a hidden panel at its last_position and last_size. If never shown, uses preferredSize and the panel's defaultPosition.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "hide_panel",
                description: "Hide a panel and record its current size/position to Layout.hidden. Refuses to hide the last visible panel.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "move_panel",
                description: "Move a panel to a docked position or 'floating'. Position must be one of: left, right, top, bottom, center_overlay, floating.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id":       ["type": "string"],
                        "position": ["enum": ["left", "right", "top", "bottom", "center_overlay", "floating"]],
                    ],
                    "required": ["id", "position"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_panel_size",
                description: "Resize the panel's tab group across-dimension (width for left/right; height for top/bottom). Respects minSize.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id":   ["type": "string"],
                        "size": ["type": "number"],
                    ],
                    "required": ["id", "size"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "tab_panels",
                description: "Make source_id a tab in the same group as target_id.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "target_id": ["type": "string"],
                        "source_id": ["type": "string"],
                    ],
                    "required": ["target_id", "source_id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "untab_panel",
                description: "Break a panel out of its tab group into its own group at the same position.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "apply_layout_preset",
                description: "Switch to a named preset (built-in: 'Viewer only', 'Browser', 'Photographer', 'Power user', 'Slideshow', or any saved user preset).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["name": ["type": "string"]],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "save_current_layout",
                description: "Snapshot the current layout as a user preset. Refuses to overwrite a built-in preset name.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["name": ["type": "string"]],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "delete_layout_preset",
                description: "Delete a user preset. Built-in presets cannot be deleted.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["name": ["type": "string"]],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "list_layout_presets",
                description: "List built-in and user presets.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_layout_state",
                description: "Return the current layout.json contents.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_layout_state",
                description: "Replace layout.json with the supplied object. The framework validates and rejects invalid layouts.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": ["layout": ["type": "object"]],
                    "required": ["layout"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        do {
            switch name {
            case "list_panels":          return try listPanels()
            case "show_panel":           return try showPanel(arguments)
            case "hide_panel":           return try hidePanel(arguments)
            case "move_panel":           return try movePanel(arguments)
            case "set_panel_size":       return try setPanelSize(arguments)
            case "tab_panels":           return try tabPanels(arguments)
            case "untab_panel":          return try untabPanel(arguments)
            case "apply_layout_preset":  return try applyLayoutPreset(arguments)
            case "save_current_layout":  return try saveCurrentLayout(arguments)
            case "delete_layout_preset": return try deleteLayoutPreset(arguments)
            case "list_layout_presets":  return try listLayoutPresets()
            case "get_layout_state":     return try getLayoutState()
            case "set_layout_state":     return try setLayoutState(arguments)
            default:
                return .text("Unknown panel tool: \(name)", isError: true)
            }
        } catch let e as PanelMutationError {
            return .text(e.description, isError: true)
        } catch let e as LayoutStoreError {
            return .text(e.description, isError: true)
        } catch let e as PanelToolError {
            return .text(e.description, isError: true)
        } catch {
            return .text("Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Tool bodies

    private func listPanels() throws -> MCP.CallToolResult {
        let layout = store.load()
        var panels: [[String: Any]] = []
        for d in BuiltInPanelCatalog.all {
            var entry: [String: Any] = [
                "id": d.id,
                "title": d.title,
                "icon": d.icon,
                "supports_floating": d.supportsFloating,
                "default_position": d.defaultPosition.wireValue,
                "min_size":       [d.minSize.width, d.minSize.height],
                "preferred_size": [d.preferredSize.width, d.preferredSize.height],
            ]
            if let pos = layout.position(of: d.id) {
                entry["position"] = pos.wireValue
                entry["visible"] = true
                if pos == .floating, let f = layout.floating.first(where: { $0.id == d.id }) {
                    entry["floating_frame"] = [f.frame.origin.x, f.frame.origin.y, f.frame.width, f.frame.height]
                }
                if let (g, idx) = layout.locate(panelID: d.id) {
                    entry["tab_group_id"] = g.id.uuidString
                    entry["tab_index"]    = idx
                }
            } else if let h = layout.hidden[d.id] {
                entry["visible"] = false
                entry["last_position"] = h.lastPosition.wireValue
                entry["last_size"]     = [h.lastSize.width, h.lastSize.height]
            } else {
                entry["visible"] = false
            }
            panels.append(entry)
        }
        return .text(prettyJSON(["panels": panels]))
    }

    private func showPanel(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        try requireKnownPanel(id)
        let current = store.load()
        let descriptor = BuiltInPanelCatalog.descriptor(for: id)
        let new = PanelLayoutMutations.showPanel(
            current,
            id: id,
            defaultPosition: descriptor?.defaultPosition ?? .right,
            defaultSize: descriptor?.preferredSize ?? .init(width: 280, height: 600)
        )
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func hidePanel(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        try requireKnownPanel(id)
        let current = store.load()
        let new = try PanelLayoutMutations.hidePanel(current, id: id)
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func movePanel(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        let posRaw = try requireString(args, "position")
        guard let pos = DockPosition.fromWire(posRaw) else {
            throw PanelToolError.invalidPosition(posRaw)
        }
        try requireKnownPanel(id)
        let descriptor = BuiltInPanelCatalog.descriptor(for: id)
        if pos == .floating, descriptor?.supportsFloating == false {
            throw PanelToolError.notFloatable(id)
        }
        let current = store.load()
        let new = try PanelLayoutMutations.movePanel(
            current,
            id: id,
            to: pos,
            preferredSize: descriptor?.preferredSize ?? .init(width: 320, height: 600)
        )
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func setPanelSize(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        let size = try requireNumber(args, "size")
        try requireKnownPanel(id)
        let current = store.load()
        let new = try PanelLayoutMutations.setPanelSize(current, id: id, size: CGFloat(size))
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func tabPanels(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let target = try requireString(args, "target_id")
        let source = try requireString(args, "source_id")
        try requireKnownPanel(target)
        try requireKnownPanel(source)
        let current = store.load()
        let new = try PanelLayoutMutations.tabPanels(current, targetID: target, sourceID: source)
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func untabPanel(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let id = try requireString(args, "id")
        try requireKnownPanel(id)
        let current = store.load()
        let new = try PanelLayoutMutations.untabPanel(current, id: id)
        try store.save(new)
        return .text(prettyJSON(new))
    }

    private func applyLayoutPreset(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let name = try requireString(args, "name")
        let layout: PanelLayout
        if let builtIn = PresetCatalog.builtIn(named: name) {
            layout = builtIn.layout()
        } else {
            layout = try store.loadUserPreset(name: name)
        }
        try store.save(layout)
        return .text(prettyJSON(layout))
    }

    private func saveCurrentLayout(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let name = try requireString(args, "name")
        let current = store.load()
        try store.saveUserPreset(name: name, layout: current)
        return .text(prettyJSON(["saved": name, "kind": "user"] as [String: Any]))
    }

    private func deleteLayoutPreset(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let name = try requireString(args, "name")
        try store.deleteUserPreset(name: name)
        return .text(prettyJSON(["deleted": name] as [String: Any]))
    }

    private func listLayoutPresets() throws -> MCP.CallToolResult {
        let user = store.listUserPresets()
        return .text(prettyJSON([
            "built_in": BuiltInPreset.allCases.map { $0.rawValue },
            "user":     user,
        ] as [String: Any]))
    }

    private func getLayoutState() throws -> MCP.CallToolResult {
        let layout = store.load()
        return .text(prettyJSON(layout))
    }

    private func setLayoutState(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        guard let raw = args["layout"] as? [String: Any] else {
            throw PanelToolError.missing("layout")
        }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let parsed = try dec.decode(PanelLayout.self, from: data)
        try store.save(parsed)
        return .text(prettyJSON(parsed))
    }

    // MARK: - Helpers

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let raw = args[key], let v = raw as? String, !v.isEmpty else {
            throw PanelToolError.missing(key)
        }
        return v
    }

    private func requireNumber(_ args: [String: Any?], _ key: String) throws -> Double {
        if let v = args[key] as? Double { return v }
        if let v = args[key] as? Int { return Double(v) }
        if let v = args[key] as? NSNumber { return v.doubleValue }
        throw PanelToolError.missing(key)
    }

    private func requireKnownPanel(_ id: String) throws {
        if BuiltInPanelCatalog.descriptor(for: id) == nil {
            throw PanelToolError.unknownPanel(id)
        }
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

public enum PanelToolError: Error, CustomStringConvertible {
    case missing(String)
    case invalidPosition(String)
    case unknownPanel(String)
    case notFloatable(String)

    public var description: String {
        switch self {
        case .missing(let k):           return "Missing or invalid argument: \(k)"
        case .invalidPosition(let p):   return "Invalid position '\(p)' (expected one of left, right, top, bottom, center_overlay, floating)."
        case .unknownPanel(let id):     return "Unknown panel id: '\(id)'"
        case .notFloatable(let id):     return "Panel '\(id)' does not support floating."
        }
    }
}
