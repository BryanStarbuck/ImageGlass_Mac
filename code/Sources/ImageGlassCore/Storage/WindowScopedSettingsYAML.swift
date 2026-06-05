import Foundation

/// Hand-rolled YAML codec for `WindowScopedSettings`
/// (multi_window.mdx §3.2). Same philosophy as `DirectoriesYAML`: no
/// library dependency, the on-disk form stays human-readable for the
/// `cat` verify steps in the use case docs.
public enum WindowScopedSettingsYAML {

    public enum DecodeError: Error, CustomStringConvertible {
        case syntax(line: Int, message: String)
        case missingWindowID
        case windowIDMismatch(inFile: Int, expected: Int)

        public var description: String {
            switch self {
            case .syntax(let l, let m):
                return "settings_window_<N>.yaml syntax error at line \(l): \(m)"
            case .missingWindowID:
                return "settings_window_<N>.yaml is missing required 'window_id' key"
            case .windowIDMismatch(let inFile, let expected):
                return "settings_window_\(expected).yaml content says window_id=\(inFile) (multi_window.mdx §14.2)"
            }
        }
    }

    // MARK: - Encode

    public static func encode(_ s: WindowScopedSettings) -> String {
        var out = ""
        out += "schema_version: \(s.schemaVersion)\n"
        out += "window_id: \(s.windowID)\n"
        if let name = s.windowName {
            out += "window_name: \(yamlQuote(name))\n"
        }
        if let scope = s.activeScope {
            out += "active_scope: \(yamlQuote(scope))\n"
        }

        // ui:
        out += "ui:\n"
        emitOptBool(&out, "  show_directory_panel", s.ui.showDirectoryPanel)
        emitOptBool(&out, "  show_preview_panel", s.ui.showPreviewPanel)
        emitOptBool(&out, "  show_metadata_panel", s.ui.showMetadataPanel)
        emitOptBool(&out, "  show_toolbar", s.ui.showToolbar)
        emitOptBool(&out, "  show_status_bar", s.ui.showStatusBar)
        emitOptBool(&out, "  show_file_info_overlay", s.ui.showFileInfoOverlay)

        // viewer:
        out += "viewer:\n"
        out += "  default_zoom_mode: \(s.viewer.defaultZoomMode)\n"
        out += "  interpolation: \(s.viewer.interpolation)\n"
        out += "  lock_zoom: \(s.viewer.lockZoom)\n"
        out += "  frameless_window: \(s.viewer.framelessWindow)\n"

        // navigation:
        out += "navigation:\n"
        out += "  sort_panel_by: \(s.navigation.sortPanelBy)\n"
        out += "  sort_ascending: \(s.navigation.sortAscending)\n"
        out += "  loop_at_ends: \(s.navigation.loopAtEnds)\n"

        // slideshow:
        out += "slideshow:\n"
        out += "  was_running_on_quit: \(s.slideshow.wasRunningOnQuit)\n"
        out += "  current_index: \(s.slideshow.currentIndex)\n"

        // session:
        out += "session:\n"
        out += "  was_open_on_quit: \(s.session.wasOpenOnQuit)\n"
        out += "  window:\n"
        out += "    frame: [\(s.session.window.frame.map { String($0) }.joined(separator: ", "))]\n"
        out += "    screen_id: \(yamlQuote(s.session.window.screenID))\n"
        out += "    full_screen: \(s.session.window.fullScreen)\n"
        out += "    frameless: \(s.session.window.frameless)\n"
        out += "  panels:\n"
        emitPanel(&out, "file_panel", s.session.panels.filePanel)
        emitPanel(&out, "scope_editor", s.session.panels.scopeEditor)
        emitPanel(&out, "metadata", s.session.panels.metadata)
        emitPanel(&out, "histogram", s.session.panels.histogram)
        emitPanel(&out, "mcp_activity", s.session.panels.mcpActivity)
        emitPanel(&out, "gallery_strip", s.session.panels.galleryStrip)
        out += "  viewer:\n"
        out += "    zoom_mode: \(s.session.viewer.zoomMode)\n"
        if let p = s.session.viewer.customZoomPercent {
            out += "    custom_zoom_percent: \(p)\n"
        } else {
            out += "    custom_zoom_percent: null\n"
        }
        out += "    pan_offset: [\(s.session.viewer.panOffset.map { String($0) }.joined(separator: ", "))]\n"
        out += "  selection:\n"
        if let f = s.session.selection.currentFile {
            out += "    current_file: \(yamlQuote(f))\n"
        } else {
            out += "    current_file: null\n"
        }
        out += "    panel_focus: \(s.session.selection.panelFocus)\n"
        out += "  directory_panel:\n"
        if s.session.directoryPanel.expandedPaths.isEmpty {
            out += "    expanded_paths: {}\n"
        } else {
            out += "    expanded_paths:\n"
            // Sort keys so round-trip diffs are stable.
            for k in s.session.directoryPanel.expandedPaths.keys.sorted() {
                let v = s.session.directoryPanel.expandedPaths[k]!
                out += "      \(yamlQuote(k)): \(v)\n"
            }
        }
        return out
    }

    private static func emitOptBool(_ out: inout String, _ key: String, _ v: Bool?) {
        if let v = v {
            out += "\(key): \(v)\n"
        }
    }

    private static func emitPanel(_ out: inout String, _ name: String, _ p: PanelPlacement) {
        out += "    \(name): { dock: \(p.dock), visible: \(p.visible), collapsed: \(p.collapsed) }\n"
    }

    private static func yamlQuote(_ s: String) -> String {
        // Quote if it contains anything that would confuse the parser.
        let special = #":{}[],&*#?|<>=!%@`"#
        let needsQuote = s.isEmpty || s.contains(where: { special.contains($0) }) ||
            s.first == " " || s.last == " " || s == "null" || s == "true" || s == "false" ||
            Double(s) != nil
        if needsQuote {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    // MARK: - Decode
    //
    // Permissive parser sufficient for the schema this codec writes.
    // Handles: scalar key: value lines, nested blocks via indentation,
    // flow-style inline maps `{ k: v, k: v }`, flow-style lists
    // `[a, b]`, and double-quoted strings with `\\` and `\"` escapes.
    // It is NOT a general-purpose YAML parser; it expects files written
    // by `encode()` above (or hand-edited in the same shape).

    public static func decode(_ text: String, expectedWindowID: Int? = nil) throws -> WindowScopedSettings {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Strip comments and trailing whitespace.
        for i in lines.indices {
            if let hashIdx = lines[i].firstIndex(of: "#") {
                // Only treat as comment if the # is not inside a quoted string.
                let before = lines[i][..<hashIdx]
                if !before.contains("\"") || before.filter({ $0 == "\"" }).count % 2 == 0 {
                    lines[i] = String(before)
                }
            }
            lines[i] = lines[i].trimmingCharacters(in: .init(charactersIn: " \t\r"))
        }

        // First pass: build a flat dictionary of top-level keys → raw block text.
        var idx = 0
        var topKeys: [String: String] = [:]
        var topOrder: [String] = []
        while idx < lines.count {
            let line = lines[idx]
            if line.isEmpty { idx += 1; continue }
            // Top-level keys are at column 0 (no leading space) and contain ':'.
            // But after trimming we lost indentation info. Re-derive from the original.
            // We need original indentation — redo with indentation preserved.
            break
        }
        // Re-parse with indentation preserved.
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var collected: [String: [String]] = [:]
        var order: [String] = []
        var currentKey: String? = nil
        for rawLine in raw {
            let stripped = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let leading = stripped.prefix(while: { $0 == " " }).count
            let body = stripped.trimmingCharacters(in: .init(charactersIn: " \t\r"))
            if body.isEmpty || body.hasPrefix("#") { continue }
            if leading == 0, let colon = body.firstIndex(of: ":") {
                let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                if !order.contains(key) { order.append(key) }
                collected[key] = []
                if !valuePart.isEmpty {
                    // Inline scalar (e.g. `schema_version: 2`).
                    collected[key]?.append("__INLINE__:\(valuePart)")
                }
            } else if let key = currentKey {
                collected[key]?.append(stripped)
            }
        }

        // window_id is required.
        guard let widLines = collected["window_id"],
              let widLine = widLines.first,
              widLine.hasPrefix("__INLINE__:") else {
            throw DecodeError.missingWindowID
        }
        let widString = String(widLine.dropFirst("__INLINE__:".count))
        guard let wid = Int(widString) else {
            throw DecodeError.syntax(line: 2, message: "window_id is not an integer: \(widString)")
        }
        if let expected = expectedWindowID, expected != wid {
            throw DecodeError.windowIDMismatch(inFile: wid, expected: expected)
        }

        var s = WindowScopedSettings(windowID: wid)
        if let v = scalarInt(collected, "schema_version") { s.schemaVersion = v }
        if let v = scalarString(collected, "window_name") { s.windowName = v }
        if let v = scalarString(collected, "active_scope") { s.activeScope = v }

        // ui block.
        if let block = collected["ui"] {
            s.ui.showDirectoryPanel  = blockBool(block, "show_directory_panel")
            s.ui.showPreviewPanel    = blockBool(block, "show_preview_panel")
            s.ui.showMetadataPanel   = blockBool(block, "show_metadata_panel")
            s.ui.showToolbar         = blockBool(block, "show_toolbar")
            s.ui.showStatusBar       = blockBool(block, "show_status_bar")
            s.ui.showFileInfoOverlay = blockBool(block, "show_file_info_overlay")
        }
        // viewer block.
        if let block = collected["viewer"] {
            if let v = blockString(block, "default_zoom_mode") { s.viewer.defaultZoomMode = v }
            if let v = blockString(block, "interpolation") { s.viewer.interpolation = v }
            if let v = blockBool(block, "lock_zoom") { s.viewer.lockZoom = v }
            if let v = blockBool(block, "frameless_window") { s.viewer.framelessWindow = v }
        }
        // navigation block.
        if let block = collected["navigation"] {
            if let v = blockString(block, "sort_panel_by") { s.navigation.sortPanelBy = v }
            if let v = blockBool(block, "sort_ascending") { s.navigation.sortAscending = v }
            if let v = blockBool(block, "loop_at_ends") { s.navigation.loopAtEnds = v }
        }
        // slideshow block.
        if let block = collected["slideshow"] {
            if let v = blockBool(block, "was_running_on_quit") { s.slideshow.wasRunningOnQuit = v }
            if let v = blockInt(block, "current_index") { s.slideshow.currentIndex = v }
        }
        // session block — multi-level, decoded by lightweight nested scan.
        if let block = collected["session"] {
            s.session = decodeSession(block)
        }
        return s
    }

    // MARK: - Decode helpers

    private static func scalarInt(_ map: [String: [String]], _ key: String) -> Int? {
        guard let line = map[key]?.first, line.hasPrefix("__INLINE__:") else { return nil }
        return Int(line.dropFirst("__INLINE__:".count).trimmingCharacters(in: .whitespaces))
    }
    private static func scalarString(_ map: [String: [String]], _ key: String) -> String? {
        guard let line = map[key]?.first, line.hasPrefix("__INLINE__:") else { return nil }
        return unquote(String(line.dropFirst("__INLINE__:".count)).trimmingCharacters(in: .whitespaces))
    }
    private static func blockBool(_ lines: [String], _ key: String) -> Bool? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                let v = t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if v == "true" { return true }
                if v == "false" { return false }
            }
        }
        return nil
    }
    private static func blockInt(_ lines: [String], _ key: String) -> Int? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                let v = t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return Int(v)
            }
        }
        return nil
    }
    private static func blockString(_ lines: [String], _ key: String) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                let v = t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if v.isEmpty || v == "null" { return nil }
                return unquote(v)
            }
        }
        return nil
    }
    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t = String(t.dropFirst().dropLast())
            t = t.replacingOccurrences(of: "\\\"", with: "\"")
                 .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }

    private static func decodeSession(_ block: [String]) -> WindowSession {
        var sess = WindowSession()
        if let v = blockBool(block, "was_open_on_quit") { sess.wasOpenOnQuit = v }
        // Sub-block scanning: find indented children of "window:", "panels:", etc.
        let sub = splitSubBlocks(block)
        if let win = sub["window"] {
            if let frame = blockFlowArrayDouble(win, "frame") { sess.window.frame = frame }
            if let v = blockString(win, "screen_id") { sess.window.screenID = v }
            if let v = blockBool(win, "full_screen") { sess.window.fullScreen = v }
            if let v = blockBool(win, "frameless") { sess.window.frameless = v }
        }
        if let panels = sub["panels"] {
            if let p = decodeFlowPanel(panels, "file_panel") { sess.panels.filePanel = p }
            if let p = decodeFlowPanel(panels, "scope_editor") { sess.panels.scopeEditor = p }
            if let p = decodeFlowPanel(panels, "metadata") { sess.panels.metadata = p }
            if let p = decodeFlowPanel(panels, "histogram") { sess.panels.histogram = p }
            if let p = decodeFlowPanel(panels, "mcp_activity") { sess.panels.mcpActivity = p }
            if let p = decodeFlowPanel(panels, "gallery_strip") { sess.panels.galleryStrip = p }
        }
        if let vw = sub["viewer"] {
            if let v = blockString(vw, "zoom_mode") { sess.viewer.zoomMode = v }
            if let v = blockOptDouble(vw, "custom_zoom_percent") { sess.viewer.customZoomPercent = v }
            if let arr = blockFlowArrayDouble(vw, "pan_offset") { sess.viewer.panOffset = arr }
        }
        if let sel = sub["selection"] {
            sess.selection.currentFile = blockString(sel, "current_file")
            if let v = blockString(sel, "panel_focus") { sess.selection.panelFocus = v }
        }
        if let dp = sub["directory_panel"] {
            sess.directoryPanel.expandedPaths = decodeExpandedPaths(dp)
        }
        return sess
    }

    /// Split a parent block's lines into named sub-block lines, keyed by
    /// the sub-block name. Indentation-based: we look for child keys
    /// indented exactly 2 spaces deeper than the parent.
    private static func splitSubBlocks(_ block: [String]) -> [String: [String]] {
        // Determine the parent's base indentation by scanning the first
        // child line. Then each "key:" at base+2 starts a sub-block.
        guard let first = block.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return [:]
        }
        let baseIndent = first.prefix(while: { $0 == " " }).count
        var result: [String: [String]] = [:]
        var currentKey: String? = nil
        for line in block {
            let leading = line.prefix(while: { $0 == " " }).count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { continue }
            if leading == baseIndent, let colon = body.firstIndex(of: ":") {
                let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                if result[key] == nil { result[key] = [] }
                if !valuePart.isEmpty {
                    result[key]?.append("__INLINE__:\(valuePart)")
                }
            } else if let k = currentKey {
                result[k]?.append(line)
            }
        }
        return result
    }

    private static func blockFlowArrayDouble(_ block: [String], _ key: String) -> [Double]? {
        for line in block {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                let rest = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("[") && rest.hasSuffix("]") else { return nil }
                let inner = rest.dropFirst().dropLast()
                let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let nums = parts.compactMap { Double($0) }
                return nums.count == parts.count ? nums : nil
            }
        }
        return nil
    }

    private static func blockOptDouble(_ block: [String], _ key: String) -> Double? {
        for line in block {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                let v = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                if v == "null" || v.isEmpty { return nil }
                return Double(v)
            }
        }
        return nil
    }

    private static func decodeFlowPanel(_ block: [String], _ key: String) -> PanelPlacement? {
        for line in block {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\(key):") else { continue }
            let rest = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("{") && rest.hasSuffix("}") else { return nil }
            let inner = String(rest.dropFirst().dropLast())
            var dock = "left", visible = true, collapsed = false
            for pair in inner.split(separator: ",") {
                let p = pair.trimmingCharacters(in: .whitespaces)
                if let colon = p.firstIndex(of: ":") {
                    let k = String(p[..<colon]).trimmingCharacters(in: .whitespaces)
                    let v = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    switch k {
                    case "dock":      dock = v
                    case "visible":   visible = (v == "true")
                    case "collapsed": collapsed = (v == "true")
                    default: break
                    }
                }
            }
            return PanelPlacement(dock: dock, visible: visible, collapsed: collapsed)
        }
        return nil
    }

    private static func decodeExpandedPaths(_ block: [String]) -> [String: Bool] {
        // Find the `expanded_paths:` line. If the value is `{}` (or empty),
        // return empty. Otherwise scan child lines.
        var result: [String: Bool] = [:]
        var inMap = false
        var baseIndent = 0
        for line in block {
            let leading = line.prefix(while: { $0 == " " }).count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { continue }
            if !inMap {
                if body == "expanded_paths:" || body.hasPrefix("expanded_paths:") {
                    let rest = String(body.dropFirst("expanded_paths:".count)).trimmingCharacters(in: .whitespaces)
                    if rest == "{}" || rest.isEmpty {
                        if rest == "{}" { return [:] }
                        inMap = true
                        baseIndent = leading + 2
                    }
                }
            } else {
                if leading < baseIndent { break }
                if let colon = body.firstIndex(of: ":") {
                    let k = unquote(String(body[..<colon]).trimmingCharacters(in: .whitespaces))
                    let v = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    result[k] = (v == "true")
                }
            }
        }
        return result
    }
}
