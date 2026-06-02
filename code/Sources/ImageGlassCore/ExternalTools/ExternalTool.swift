import Foundation

/// Descriptor of a third-party tool registered with ImageGlass.
///
/// Mirrors the upstream Windows model documented in `docs/build-tools.mdx`:
/// an executable path + an argument template that may include the `<file>`
/// placeholder, plus an optional hotkey and an "integration" flag.
///
/// Persisted as one plain-JSON file per tool under
/// `~/Library/Application Support/ImageGlass/tools/<id>.json` so the
/// on-disk layout matches the plain-text charter of the rest of the app.
public struct ExternalTool: Codable, Equatable, Sendable, Identifiable {

    /// Unique tool identifier. Doubles as the on-disk filename (no extension).
    /// Must be safe to drop into a filename — no path separators, no leading dot.
    public var id: String

    /// Human-readable name shown in UI. Defaults to `id` when not provided.
    public var displayName: String

    /// Absolute path to the executable on disk. Tilde is allowed and expanded
    /// at launch time via `AppPaths.expandTilde`.
    public var executablePath: String

    /// Argument template. Tokens to be expanded:
    ///   * `<file>`  - replaced by the currently displayed image path.
    ///
    /// Stored as a single string (matching the upstream `Arguments` field);
    /// tokenized into an argv array at launch time.
    public var arguments: String

    /// Optional hotkey binding string (e.g. "cmd+shift+e"). Free-form — the
    /// UI layer interprets it; the launcher itself does not.
    public var hotkey: String?

    /// "Integration" flag from the upstream model. When `true`, the tool is
    /// expected to speak the IPC protocol back to ImageGlass (it receives
    /// IMAGE_LOADED events on its socket). When `false`, ImageGlass just
    /// fires-and-forgets the subprocess each time.
    public var integration: Bool

    public init(
        id: String,
        displayName: String? = nil,
        executablePath: String,
        arguments: String = "",
        hotkey: String? = nil,
        integration: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.executablePath = executablePath
        self.arguments = arguments
        self.hotkey = hotkey
        self.integration = integration
    }
}

/// Errors thrown by the external-tools subsystem.
public enum ExternalToolError: Error, CustomStringConvertible, Equatable {
    case invalidId(String)
    case notFound(String)
    case alreadyExists(String)
    case executableMissing(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .invalidId(let s):
            return "Invalid tool id '\(s)' (must be non-empty, no path separators, no leading dot)."
        case .notFound(let s):
            return "Tool not found: '\(s)'."
        case .alreadyExists(let s):
            return "Tool already exists: '\(s)'."
        case .executableMissing(let s):
            return "Executable not found on disk: '\(s)'."
        case .launchFailed(let s):
            return "Failed to launch tool: \(s)."
        }
    }
}

/// id-validation helper used by both storage and MCP layers.
public enum ExternalToolId {
    public static func validate(_ id: String) throws {
        guard !id.isEmpty,
              !id.contains("/"),
              !id.contains("\\"),
              !id.hasPrefix("."),
              !id.contains("\0") else {
            throw ExternalToolError.invalidId(id)
        }
    }
}
