import Foundation

/// MCP tool descriptors + dispatch for the Themes subsystem.
/// Pattern mirrors the scope tools — surfaced through the top-level `MCPTools`
/// router with a minimal surgical edit.
public struct ThemeMCPTools {

    public static let toolNames: Set<String> = [
        "list_themes",
        "get_current_theme",
        "set_current_theme",
    ]

    private let catalog: ThemeCatalog

    public init(catalog: ThemeCatalog = ThemeCatalog()) {
        self.catalog = catalog
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "list_themes",
                description: "List all themes available to ImageGlass — built-in themes plus any .igtheme packs installed under ~/Library/Application Support/ImageGlass/themes/.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_current_theme",
                description: "Get the currently selected theme — name, colors, dark/light flag, metadata.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_current_theme",
                description: "Switch to a theme by name. The name must match an entry returned by list_themes. Persists the selection to a plain-text file under app support.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Theme name (matches list_themes output)."],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        switch name {
        case "list_themes":
            let themes = catalog.installedThemes()
            let summaries: [[String: Any]] = themes.map { t in
                [
                    "name": t.name,
                    "displayName": t.info.name,
                    "author": t.info.author,
                    "version": t.info.version,
                    "isDarkMode": t.settings.isDarkMode,
                    "isBuiltin": t.folderURL == nil,
                ]
            }
            return .text(prettyJSON(["themes": summaries]))

        case "get_current_theme":
            let currentName = readPersistedName()
            let theme = catalog.theme(named: currentName) ?? BuiltinThemes.defaultTheme
            return .text(prettyJSON(theme))

        case "set_current_theme":
            guard let target = arguments["name"] as? String, !target.isEmpty else {
                throw MCPToolError.missingArgument("name")
            }
            guard let theme = catalog.theme(named: target) else {
                return .text("Unknown theme: '\(target)'.", isError: true)
            }
            try writePersistedName(theme.name)
            return .text(prettyJSON([
                "name": theme.name,
                "applied": true,
            ] as [String: Any]))

        default:
            return .text("Unknown theme tool: \(name)", isError: true)
        }
    }

    // MARK: - Persistence (plain-text, one line)

    private func readPersistedName() -> String {
        let url = AppPaths.currentThemeFile
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return BuiltinThemes.defaultTheme.name
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? BuiltinThemes.defaultTheme.name : trimmed
    }

    private func writePersistedName(_ name: String) throws {
        try AppPaths.ensureThemesDirectory()
        let url = AppPaths.currentThemeFile
        try (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - JSON helpers (duplicated from MCPTools to avoid coupling)

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
