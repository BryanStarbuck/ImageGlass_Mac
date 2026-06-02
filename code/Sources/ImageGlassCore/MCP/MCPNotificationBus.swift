import Foundation

/// In-process broker for JSON-RPC notifications the MCP server emits to
/// its connected client. `MCPServer` subscribes to this bus at startup
/// and writes every emitted notification to its output stream. The MCP
/// tools (`select_file`, `panel.set_view_mode`, …) and the SwiftUI app
/// state (when the user changes selection in the GUI) post events here
/// without having to know whether or which transport is connected.
///
/// `docs/use_cases/mcp_file.mdx` §2.3 / §3 / §10 describe the
/// `selection_changed`, `view_mode_changed`, and
/// `auto_select_first_changed` push events emitted on this bus.
public final class MCPNotificationBus: @unchecked Sendable {

    public static let shared = MCPNotificationBus()

    /// One notification record. Encoded as `{"jsonrpc":"2.0","method":…,
    /// "params":…}` and written newline-delimited on the MCP server's
    /// output channel.
    public struct Notification: Sendable {
        public let method: String
        public let params: [String: Any]
        public init(method: String, params: [String: Any]) {
            self.method = method
            self.params = params
        }
    }

    public typealias Subscriber = @Sendable (Notification) -> Void

    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]

    public init() {}

    /// Register a subscriber. Returns a token; pass it to
    /// `removeSubscriber(_:)` to detach. Subscribers are invoked
    /// synchronously on the thread that calls `emit(_:)`.
    @discardableResult
    public func addSubscriber(_ handler: @escaping Subscriber) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    public func removeSubscriber(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeValue(forKey: token)
    }

    /// Broadcast a notification to every subscriber.
    public func emit(_ notification: Notification) {
        lock.lock()
        let snapshot = Array(subscribers.values)
        lock.unlock()
        for handler in snapshot {
            handler(notification)
        }
    }

    // MARK: - Convenience emitters for the §-numbered events

    /// `notifications/imageglass/selection_changed` — emitted whenever
    /// the GUI selection (or an MCP `select_file` call) lands on a new
    /// file. Spec mcp_file.mdx §2.3 / §10.
    public func emitSelectionChanged(path: String, corr: String? = nil) {
        var params: [String: Any] = ["path": path]
        if let corr { params["corr"] = corr }
        emit(.init(
            method: "notifications/imageglass/selection_changed",
            params: params
        ))
    }

    /// `notifications/imageglass/view_mode_changed` — emitted whenever
    /// the file panel's view mode changes. Spec mcp_file.mdx §3.
    public func emitViewModeChanged(mode: String, corr: String? = nil) {
        var params: [String: Any] = ["mode": mode]
        if let corr { params["corr"] = corr }
        emit(.init(
            method: "notifications/imageglass/view_mode_changed",
            params: params
        ))
    }

    /// `notifications/imageglass/auto_select_first` — emitted when the
    /// walker's §10 auto-select-first rule fires.
    public func emitAutoSelectFirst(
        path: String,
        corr: String,
        reason: String
    ) {
        emit(.init(
            method: "notifications/imageglass/auto_select_first",
            params: [
                "path":   path,
                "corr":   corr,
                "reason": reason,
            ]
        ))
    }
}
