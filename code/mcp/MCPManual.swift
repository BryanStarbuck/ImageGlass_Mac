import Foundation

/// MCP self-describing manual surface (spec
/// `docs/use_cases/mcp_and_filters_on_dirs.mdx` §7).
///
/// The canonical source is the plain-text file at
/// `code/mcp/mcp_manual.txt`, bundled by SwiftPM as a
/// resource on the `ImageGlassCore` target. The string returned by
/// `text` is fed verbatim into:
///   * `initialize.instructions` on the MCP handshake (§7.3).
///   * `resources/read` for the `imageglass-mcp://manual` resource (§7.5).
///
/// Both surfaces are guaranteed identical because they read from the same
/// in-process cache loaded once at first access.
public enum MCPManual {

    /// Logical URI advertised on `resources/list`.
    public static let resourceURI = "imageglass-mcp://manual"

    /// Human-friendly name advertised on `resources/list`.
    public static let resourceName = "ImageGlass MCP Manual"

    /// Description advertised on `resources/list`.
    public static let resourceDescription =
        "Operational manual: tools, voice verb → field cookbook, " +
        "priority semantics, failure modes."

    public static let resourceMimeType = "text/plain"

    /// The manual text, loaded once on first access. Falls back to a
    /// short embedded stub when the bundled resource cannot be located
    /// (defensive — under normal builds `Bundle.module` always finds it).
    public static var text: String { cached }

    /// Whether the bundled resource was loaded successfully. Exposed for
    /// tests so the bundling regression cannot ship silent.
    public static var loadedFromResource: Bool { didLoadFromResource }

    // MARK: - Cache

    private static let cached: String = MCPManual.load().text
    private static let didLoadFromResource: Bool = MCPManual.load().fromResource

    private static func load() -> (text: String, fromResource: Bool) {
        if let url = Bundle.module.url(forResource: "mcp_manual", withExtension: "txt"),
           let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8),
           !s.isEmpty {
            return (s, true)
        }
        // Stub fallback so the MCP `initialize` handshake never fails
        // even if the resource bundling is broken in a partial build.
        // Tests rely on `loadedFromResource` to catch this case.
        return (
            "ImageGlass_Mac MCP Server.\n" +
            "Manual resource not bundled in this build. See\n" +
            "docs/use_cases/mcp_and_filters_on_dirs.mdx §7 for the\n" +
            "command surface and voice-verb cookbook.\n",
            false
        )
    }
}
