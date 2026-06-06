import Foundation

/// Cross-target dispatcher for the multi-window MCP retargeting rule
/// (multi_window.mdx §6).
///
/// The MCP tool layer lives in `ImageGlassCore` and cannot depend on
/// the GUI target (where `WindowRegistry` lives). The GUI installs a
/// resolver here at launch that returns the `window_id` of the
/// frontmost AppKit window. CLI / standalone MCP server / tests
/// leave the resolver nil and fall through to the default
/// (`window_id = 1`).
///
/// Two responsibilities:
///
/// * `currentWindowID()` — the implicit MCP target for any call
///   that does not specify `window_id`. Used by hint files
///   (`selection_window_<N>.txt`) and audit-log `window_id=` fields.
/// * `bringFrontmostForward()` — the GUI side of §6's "bring it
///   forward" promise. The MCP tool calls this before applying any
///   mutation so the user can see the change land in the window
///   they targeted.
public enum MCPWindowTarget {

    /// Installed by the GUI at launch. Nil-safe: callers always get
    /// a defined `window_id` via `currentWindowID()` even before the
    /// GUI is up, so MCP-only and CLI use cases just see window 1.
    nonisolated(unsafe) public static var windowIDResolver: (@Sendable () -> Int?)?

    /// Installed by the GUI at launch. The MCP tool layer calls this
    /// immediately before applying any mutation so the user sees the
    /// targeted window jump to the front (§6).
    nonisolated(unsafe) public static var bringFrontmostForward: (@Sendable () -> Void)?

    /// Resolve the implicit MCP target. Returns 1 when no GUI is
    /// attached.
    public static func currentWindowID() -> Int {
        return windowIDResolver?() ?? 1
    }

    /// Resolve an explicit `window_id` from a tool argument, falling
    /// back to the frontmost target if absent. Returns `nil` if the
    /// caller supplied an explicit value that is invalid (negative
    /// or non-integer) — the tool layer turns this into
    /// `err=unknown_window_id` per §14.8 / §6.5.
    public static func resolveTarget(explicit: Int?) -> Int? {
        if let explicit {
            return explicit >= 1 ? explicit : nil
        }
        return currentWindowID()
    }

    /// Convenience: invoke the bring-forward hook if installed.
    public static func bringForward() {
        bringFrontmostForward?()
    }
}
