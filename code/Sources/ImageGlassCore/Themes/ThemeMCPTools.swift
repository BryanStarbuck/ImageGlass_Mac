import Foundation

/// MCP tool descriptors + dispatch for the Themes subsystem.
/// Pattern mirrors the scope tools — surfaced through the top-level `MCPTools`
/// router with a minimal surgical edit.
public struct ThemeMCPTools {

    public static let toolNames: Set<String> = [
        "list_themes",
        "get_current_theme",
        "set_current_theme",
        "get_appearance_mode",
        "set_appearance_mode",
        "install_theme_pack",
        "uninstall_theme_pack",
        "export_theme_pack",
        "validate_theme_pack",
    ]

    private let catalog: ThemeCatalog
    private let installer: ThemeInstaller

    public init(
        catalog: ThemeCatalog = ThemeCatalog(),
        installer: ThemeInstaller = ThemeInstaller()
    ) {
        self.catalog = catalog
        self.installer = installer
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
                description: "Get the currently selected theme — name, colors, dark/light flag, metadata. Reflects the active side (light vs. dark) under the current appearance mode.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_current_theme",
                description: "Switch to a theme by name. The theme is assigned to the light or dark side based on its IsDarkMode flag and persisted under app support.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Theme name (matches list_themes output)."],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_appearance_mode",
                description: "Get the user's appearance mode (light | dark | system). 'system' means ImageGlass follows the macOS Light/Dark setting and auto-switches between the chosen light and dark themes.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_appearance_mode",
                description: "Set the user's appearance mode. Allowed values: 'light', 'dark', 'system'.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["light", "dark", "system"], "description": "Appearance mode token."],
                    ],
                    "required": ["mode"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "install_theme_pack",
                description: "Install a .igtheme pack from a local path. Either a .igtheme archive (zip) or an unpacked folder containing igtheme.json. Replaces an existing theme with the same folder name atomically.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to a .igtheme archive OR a theme folder with igtheme.json."],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "uninstall_theme_pack",
                description: "Uninstall an installed theme by folder name (e.g. 'Kobe.Duong-Dieu-Phap'). Does not affect built-in themes.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "folder_name": ["type": "string", "description": "Folder name of the installed theme."],
                    ],
                    "required": ["folder_name"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "export_theme_pack",
                description: "Export an installed theme to a .igtheme archive on disk. Useful for distributing a theme you authored locally.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "folder_name": ["type": "string", "description": "Folder name of the installed theme to export."],
                        "destination": ["type": "string", "description": "Absolute path where the .igtheme file should be written."],
                    ],
                    "required": ["folder_name", "destination"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "validate_theme_pack",
                description: "Validate an installed theme against the docs/theme-pack.mdx spec. Returns a list of issues (folder-name convention, missing files, non-SVG icons, metadata version, etc.). Empty list means fully compliant.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "folder_name": ["type": "string", "description": "Folder name of the installed theme to validate."],
                    ],
                    "required": ["folder_name"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        let _trace = PerformanceLog.shared.start("MCP.ToolCall.\(name)")
        defer { _trace.finish() }
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
            let mode = readAppearanceMode()
            let lightName = readPersistedName(side: .light) ?? Theme.Builtin.lightName
            let darkName = readPersistedName(side: .dark) ?? Theme.Builtin.darkName
            let activeName: String
            switch mode {
            case .light:  activeName = lightName
            case .dark:   activeName = darkName
            case .system:
                activeName = osIsDarkMode() ? darkName : lightName
            }
            let theme = catalog.theme(named: activeName)
                ?? catalog.theme(named: lightName)
                ?? BuiltinThemes.defaultTheme

            let payload: [String: Any] = [
                "appearanceMode": mode.rawValue,
                "lightTheme": lightName,
                "darkTheme": darkName,
                "active": [
                    "name": theme.name,
                    "displayName": theme.info.name,
                    "isDarkMode": theme.settings.isDarkMode,
                    "colors": [
                        "accent": theme.colors.accent,
                        "viewerBackground": theme.colors.viewerBackground,
                        "toolbarBackground": theme.colors.toolbarBackground,
                        "galleryBackground": theme.colors.galleryBackground,
                        "menuBackground": theme.colors.menuBackground,
                        "foreground": theme.colors.foreground,
                    ],
                ],
            ]
            return .text(prettyJSON(payload))

        case "set_current_theme":
            guard let target = arguments["name"] as? String, !target.isEmpty else {
                throw MCPToolError.missingArgument("name")
            }
            guard let theme = catalog.theme(named: target) else {
                return .text("Unknown theme: '\(target)'.", isError: true)
            }
            let side: Side = theme.settings.isDarkMode ? .dark : .light
            try writePersistedName(theme.name, side: side)
            return .text(prettyJSON([
                "name": theme.name,
                "side": side == .light ? "light" : "dark",
                "applied": true,
            ] as [String: Any]))

        case "get_appearance_mode":
            return .text(prettyJSON(["mode": readAppearanceMode().rawValue]))

        case "set_appearance_mode":
            guard let raw = arguments["mode"] as? String, !raw.isEmpty else {
                throw MCPToolError.missingArgument("mode")
            }
            guard let mode = ThemeAppearanceMode(rawValue: raw) else {
                return .text("Unknown appearance mode: '\(raw)'. Use 'light', 'dark', or 'system'.", isError: true)
            }
            try writeAppearanceMode(mode)
            return .text(prettyJSON(["mode": mode.rawValue, "applied": true] as [String: Any]))

        case "install_theme_pack":
            guard let pathArg = arguments["path"] as? String, !pathArg.isEmpty else {
                throw MCPToolError.missingArgument("path")
            }
            let expanded = AppPaths.expandTilde(pathArg)
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return .text("Path does not exist: \(pathArg)", isError: true)
            }
            let pack: ThemePack
            if isDir.boolValue {
                pack = try installer.install(folder: url)
            } else {
                pack = try installer.install(archive: url)
            }
            return .text(prettyJSON([
                "installed": true,
                "folder_name": pack.folderName,
                "display_name": pack.displayName,
                "is_dark_mode": pack.isDarkMode,
            ] as [String: Any]))

        case "uninstall_theme_pack":
            guard let folder = arguments["folder_name"] as? String, !folder.isEmpty else {
                throw MCPToolError.missingArgument("folder_name")
            }
            try installer.uninstall(folderName: folder)
            return .text(prettyJSON([
                "uninstalled": true,
                "folder_name": folder,
            ] as [String: Any]))

        case "export_theme_pack":
            guard let folder = arguments["folder_name"] as? String, !folder.isEmpty else {
                throw MCPToolError.missingArgument("folder_name")
            }
            guard let dest = arguments["destination"] as? String, !dest.isEmpty else {
                throw MCPToolError.missingArgument("destination")
            }
            let destURL = URL(fileURLWithPath: AppPaths.expandTilde(dest))
            let written = try installer.exportInstalled(folderName: folder, to: destURL)
            return .text(prettyJSON([
                "exported": true,
                "folder_name": folder,
                "path": written.path,
            ] as [String: Any]))

        case "validate_theme_pack":
            guard let folder = arguments["folder_name"] as? String, !folder.isEmpty else {
                throw MCPToolError.missingArgument("folder_name")
            }
            let installedFolder = AppPaths.themesDir.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: installedFolder.path) else {
                return .text("Theme not installed: \(folder)", isError: true)
            }
            let pack = try ThemePack.load(fromFolder: installedFolder)
            let issues = pack.validate()
            let payload: [[String: Any]] = issues.map { issue in
                [
                    "severity": issue.severity.rawValue,
                    "code": issue.code.rawValue,
                    "message": issue.message,
                ]
            }
            return .text(prettyJSON([
                "folder_name": folder,
                "issue_count": issues.count,
                "issues": payload,
            ] as [String: Any]))

        default:
            return .text("Unknown theme tool: \(name)", isError: true)
        }
    }

    // MARK: - Persistence (plain-text, one line)

    private enum Side { case light, dark }

    private func readPersistedName(side: Side) -> String? {
        let url = side == .light ? AppPaths.currentLightThemeFile : AppPaths.currentDarkThemeFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return readLegacyPersistedName(side: side)
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            ErrorLog.log("failed to read persisted theme name from \(url.path)",
                         error: error,
                         class: "ThemeMCPTools")
            return readLegacyPersistedName(side: side)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readLegacyPersistedName(side: Side) -> String? {
        let url = AppPaths.currentThemeFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            ErrorLog.log("failed to read legacy persisted theme name from \(url.path)",
                         error: error,
                         class: "ThemeMCPTools")
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let theme = catalog.theme(named: trimmed) else { return nil }
        let legacySide: Side = theme.settings.isDarkMode ? .dark : .light
        return legacySide == side ? trimmed : nil
    }

    private func writePersistedName(_ name: String, side: Side) throws {
        try AppPaths.ensureThemesDirectory()
        let url = side == .light ? AppPaths.currentLightThemeFile : AppPaths.currentDarkThemeFile
        try (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func readAppearanceMode() -> ThemeAppearanceMode {
        let url = AppPaths.appearanceModeFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .system
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            ErrorLog.log("failed to read appearance mode from \(url.path)",
                         error: error,
                         class: "ThemeMCPTools")
            return .system
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThemeAppearanceMode(rawValue: trimmed) ?? .system
    }

    private func writeAppearanceMode(_ mode: ThemeAppearanceMode) throws {
        try AppPaths.ensureThemesDirectory()
        let url = AppPaths.appearanceModeFile
        try (mode.rawValue + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Best-effort OS-appearance probe for the MCP `get_current_theme` call.
    /// AppKit isn't always linked in the MCP-only target, so we read the
    /// `AppleInterfaceStyle` user default that AppKit itself sets — "Dark"
    /// is present in Dark Mode and absent in Light Mode.
    private func osIsDarkMode() -> Bool {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
            return style.lowercased().contains("dark")
        }
        return false
    }

    // MARK: - JSON helpers (duplicated from MCPTools to avoid coupling)

    private func prettyJSON<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(value)
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("prettyJSON encoded data was not valid UTF-8",
                         class: "ThemeMCPTools")
        } catch {
            ErrorLog.log("prettyJSON encode failed",
                         error: error,
                         class: "ThemeMCPTools")
        }
        return "{}"
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            if let s = String(data: data, encoding: .utf8) {
                return s
            }
            ErrorLog.log("prettyJSON(dict) data was not valid UTF-8",
                         class: "ThemeMCPTools")
        } catch {
            ErrorLog.log("prettyJSON(dict) JSONSerialization failed",
                         error: error,
                         class: "ThemeMCPTools")
        }
        return "{}"
    }
}
