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

    /// Darwin distributed-notification name posted by the MCP server after
    /// any mutation to `directories.yaml`. The desktop app subscribes in
    /// `AppState.startDirectoriesFileWatcher()` for an immediate wake-up
    /// instead of waiting for the kqueue 250 ms debounce.
    public static let directoriesChangedNotificationName =
        "com.imageglass.mac.directoriesChanged"

    /// One notification record. Encoded as `{"jsonrpc":"2.0","method":…,
    /// "params":…}` and written newline-delimited on the MCP server's
    /// output channel.
    public struct Notification: Sendable {
        public let method: String
        public let params: [String: String]
        public init(method: String, params: [String: String]) {
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
    ///
    /// Instrumented per `docs/performance.mdx` §5.6 — the real "post" step
    /// (snapshot + fan-out to subscribers) is the part that does work.
    /// Property storage (add/remove subscriber) is left uninstrumented.
    public func emit(_ notification: Notification) {
        let trace = PerformanceLog.shared.start(
            "MCP.NotifyPost",
            extra: [("method", notification.method)]
        )
        defer { trace.finish() }
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
        var params: [String: String] = ["path": path]
        if let corr { params["corr"] = corr }
        emit(.init(
            method: "notifications/imageglass/selection_changed",
            params: params
        ))
    }

    /// `notifications/imageglass/view_mode_changed` — emitted whenever
    /// the file panel's view mode changes. Spec mcp_file.mdx §3.
    public func emitViewModeChanged(mode: String, corr: String? = nil) {
        var params: [String: String] = ["mode": mode]
        if let corr { params["corr"] = corr }
        emit(.init(
            method: "notifications/imageglass/view_mode_changed",
            params: params
        ))
    }

    /// include_checks.mdx §5.4 — post the cross-process Darwin
    /// distributed notification so any other process (typically the
    /// headless MCP server) reloads `directories.yaml`. Used after
    /// any GUI-driven `include_overrides` mutation (§3, §4, §7).
    public func postDirectoriesChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .init(Self.directoriesChangedNotificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
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
