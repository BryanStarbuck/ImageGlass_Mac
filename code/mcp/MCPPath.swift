import Foundation

/// Path normalization for MCP tool arguments.
///
/// Spec §10: "Path arguments are normalized and expanded (`~` → home
/// directory) before use. Symlink escapes and path-traversal patterns (`../`)
/// are followed exactly as the user's shell would follow them — Claude Code
/// is treated as the user."
///
/// We therefore:
/// * expand a leading `~` via `AppPaths.expandTilde`
/// * resolve relative paths against the user's home directory (spec says
///   absolute paths are expected; relatives are tolerated and rooted at $HOME
///   so they remain inspectable rather than depending on the CWD of the
///   ImageGlass process, which the user has no visibility into)
/// * standardize the URL so `.`/`..` segments collapse
/// * round-trip through `contractTilde` for the on-disk form so paths under
///   `$HOME` show up as `~/...` — this matches what `ScopeEvaluator` writes
///   back into `resolvedFiles`.
public enum MCPPath {

    /// Normalize a single directory argument. Returns the form we persist:
    /// tilde-contracted under $HOME, otherwise absolute and standardized.
    public static func normalizeDirectory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = AppPaths.expandTilde(trimmed)
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = (AppPaths.homeDirectory as NSString)
                .appendingPathComponent(expanded)
        }
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        return AppPaths.contractTilde(standardized)
    }

    public static func normalizeDirectories(_ raws: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in raws {
            let n = normalizeDirectory(raw)
            if n.isEmpty { continue }
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
