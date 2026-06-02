import Foundation

/// Validation for scope names. Spec §4.4: "a short, file-system-safe
/// identifier that the caller uses to reference this configuration on
/// subsequent calls."
///
/// We enforce:
/// * non-empty after trimming
/// * length 1..64
/// * only `[A-Za-z0-9._-]` — no slashes, no spaces, no leading dot, no `..`
///
/// This is stricter than the OS would require, but it keeps scope file paths
/// predictable and prevents path-traversal via the scope name itself.
public enum MCPScopeName {

    public static let maxLength = 64

    public static let allowed: Set<Character> = {
        var s = Set<Character>("abcdefghijklmnopqrstuvwxyz")
        s.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        s.formUnion("0123456789")
        s.formUnion("._-")
        return s
    }()

    public static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPToolError.invalidScopeName("scope name is empty")
        }
        guard name.count <= maxLength else {
            throw MCPToolError.invalidScopeName(
                "scope name is too long (max \(maxLength)): \(name)"
            )
        }
        if name == "." || name == ".." {
            throw MCPToolError.invalidScopeName("scope name '\(name)' is reserved")
        }
        if name.hasPrefix(".") {
            throw MCPToolError.invalidScopeName(
                "scope name cannot start with '.': \(name)"
            )
        }
        for ch in name {
            if !allowed.contains(ch) {
                throw MCPToolError.invalidScopeName(
                    "scope name contains illegal character '\(ch)': \(name)"
                )
            }
        }
        return name
    }
}
