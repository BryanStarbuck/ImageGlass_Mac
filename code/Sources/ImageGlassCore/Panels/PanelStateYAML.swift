import Foundation

/// Human-readable YAML mirror of `PanelLayout` written to
/// `~/Library/Application Support/ImageGlass_Mac/panels.yaml`.
///
/// The fork's primary persistence for panels is `layout.json` (see
/// `LayoutStore`), but the user-facing contract — restated in
/// docs/panels.mdx §6.5 and the project's CLAUDE.md — is that the
/// minimum set of state the app remembers across launches is
/// **which panels are open and where they live**. This file is that
/// contract surfaced as a YAML file the user (or Claude Code) can
/// read with `cat` without going through `jq`. The file is a
/// projection — `layout.json` remains the source of truth at runtime.
///
/// Schema:
/// ```yaml
/// schema_version: 1
/// panels:
///   - id: file_panel
///     visible: true
///     position: left
///     size: 280
///     tab_index: 0
///   - id: scope_editor
///     visible: false
///     last_position: left
///     last_size: [280, 400]
/// ```
public enum PanelStateYAML {
    public static let currentSchemaVersion: Int = 1

    /// Encode a `PanelLayout` as YAML. Stable iteration order
    /// (descriptor catalog order, with unknown ids tacked on the end)
    /// so a `git diff` of `panels.yaml` is a real semantic diff.
    public static func encode(_ layout: PanelLayout) -> String {
        var out = ""
        out += "schema_version: \(currentSchemaVersion)\n"
        out += "active_preset: \(quote(layout.activePreset))\n"
        out += "panels:\n"

        var seen = Set<String>()
        for d in BuiltInPanelCatalog.all {
            seen.insert(d.id)
            out += render(panelID: d.id, layout: layout)
        }
        // Unknown panels (plugins, etc.) still need to be reflected so a
        // round-trip via `panels.yaml` is faithful.
        for g in layout.groups {
            for pid in g.panelIDs where !seen.contains(pid) {
                seen.insert(pid)
                out += render(panelID: pid, layout: layout)
            }
        }
        for f in layout.floating where !seen.contains(f.id) {
            seen.insert(f.id)
            out += render(panelID: f.id, layout: layout)
        }
        for pid in layout.hidden.keys where !seen.contains(pid) {
            seen.insert(pid)
            out += render(panelID: pid, layout: layout)
        }
        return out
    }

    private static func render(panelID id: String, layout: PanelLayout) -> String {
        var out = "  - id: \(id)\n"
        if let (g, idx) = layout.locate(panelID: id) {
            out += "    visible: true\n"
            out += "    position: \(g.position.wireValue)\n"
            if let s = g.size {
                out += "    size: \(formatNumber(s))\n"
            }
            if g.panelIDs.count > 1 {
                out += "    tab_index: \(idx)\n"
            }
        } else if let f = layout.floating.first(where: { $0.id == id }) {
            out += "    visible: true\n"
            out += "    position: floating\n"
            out += "    floating_frame: [\(formatNumber(f.frame.origin.x)), \(formatNumber(f.frame.origin.y)), \(formatNumber(f.frame.width)), \(formatNumber(f.frame.height))]\n"
        } else if let h = layout.hidden[id] {
            out += "    visible: false\n"
            out += "    last_position: \(h.lastPosition.wireValue)\n"
            out += "    last_size: [\(formatNumber(h.lastSize.width)), \(formatNumber(h.lastSize.height))]\n"
        } else {
            out += "    visible: false\n"
        }
        return out
    }

    private static func quote(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needs = s.contains(":") || s.contains("#") || s.contains("'") ||
                    s.contains("\"") || s.first == " " || s.last == " "
        if !needs { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func formatNumber(_ d: Double) -> String {
        if d == d.rounded() {
            return String(Int(d))
        }
        return String(format: "%.1f", d)
    }

    private static func formatNumber(_ d: CGFloat) -> String {
        formatNumber(Double(d))
    }
}

/// Atomic writer for `panels.yaml`. Same atomic-rename + lock pattern
/// as `DirectoriesStore`.
public final class PanelStateYAMLStore: @unchecked Sendable {
    public static let shared = PanelStateYAMLStore()

    private let fm = FileManager.default
    private let lock = NSLock()

    public init() {}

    /// Override for tests so they can isolate the YAML file.
    public var fileOverride: URL?

    public var file: URL {
        fileOverride ?? AppPaths.macAppSupportDir.appendingPathComponent("panels.yaml")
    }

    public func save(_ layout: PanelLayout) throws {
        lock.lock()
        defer { lock.unlock() }
        try AppPaths.ensureMacDirectories()
        let yaml = PanelStateYAML.encode(layout)
        guard let data = yaml.data(using: .utf8) else {
            throw PanelStateYAMLError.encodingFailed
        }
        let url = file
        let tmp = url.deletingPathExtension().appendingPathExtension("yaml.tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

public enum PanelStateYAMLError: Error, CustomStringConvertible {
    case encodingFailed
    public var description: String {
        switch self {
        case .encodingFailed: return "panels.yaml UTF-8 encoding failed"
        }
    }
}
