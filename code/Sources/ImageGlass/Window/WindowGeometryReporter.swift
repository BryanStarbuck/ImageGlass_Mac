import SwiftUI
import AppKit
import Combine
import ImageGlassCore

/// Logs window and panel geometry to `log.log` so the file-panel
/// visibility bug can be diagnosed from outside the running app.
///
/// The user complaint is that the left file-tree bar "does not show
/// and does not work" — so every time the user resizes the window, we
/// need a hard record of:
///
/// * The window's frame in screen coordinates.
/// * The window's content-rect size (what SwiftUI is given to lay out).
/// * The left file-panel's width (or 0 if not visible).
/// * The image viewer's inferred frame inside the content rect.
/// * Whether the file panel is currently visible at all.
///
/// Format (one line per record):
///
/// ```
/// ts=… app=window.resize window=[x,y,w,h] content=[w,h] \
///       file_panel=[w] file_panel_visible=true|false \
///       viewer=[x,y,w,h]
/// ```
///
/// Records land in the same `~/Library/Application Support/ImageGlass_Mac/log.log`
/// as the MCP audit records (use_cases/mcp_file.mdx §0). `grep`
/// for `app=window.resize` to see them.
@MainActor
public final class WindowGeometryReporter: NSObject, NSWindowDelegate {
    public static let shared = WindowGeometryReporter()

    /// Last logged size — used to debounce duplicate notifications.
    private var lastLogged: CGRect = .zero
    private var window: NSWindow?
    private weak var appState: AppState?

    public func attach(to window: NSWindow, state: AppState) {
        self.window = window
        self.appState = state
        // Don't clobber an existing delegate; many SwiftUI windows
        // already have one. We become an auxiliary observer instead.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResized(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResized(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResized(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        // Initial snapshot once mounted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.logCurrent(reason: "attach")
        }
    }

    @objc private func windowResized(_ note: Notification) {
        logCurrent(reason: "resize")
    }

    /// Log the window + panel + viewer geometry. Called on every resize
    /// AND on every panel show/hide so the audit trail captures both
    /// "user dragged the window" and "user closed the panel."
    public func logCurrent(reason: String) {
        // docs/performance.mdx §5.4 / §10.12 — `Window.ReportGeometry`.
        // Wraps every geometry snapshot so the analyzer can see how
        // often (and how expensively) the resize-burst path fires.
        let _trace = PerformanceLog.shared.start(
            "Window.ReportGeometry",
            extra: [("reason", reason)]
        )
        defer { _trace.finish() }
        guard let window = self.window, let state = self.appState else { return }
        let frame = window.frame
        let content = window.contentLayoutRect.size
        let filePanelID = BuiltInPanelCatalog.filePanel.id
        let isVisible = state.panelLayout.layout.isVisible(filePanelID)
        let leftGroup = state.panelLayout.layout.groups.first { $0.position == .left }
        let leftWidth: CGFloat = (leftGroup != nil) ? (leftGroup!.size ?? 280) : 0
        let rightGroup = state.panelLayout.layout.groups.first { $0.position == .right }
        let rightWidth: CGFloat = (rightGroup != nil) ? (rightGroup!.size ?? 320) : 0
        let topGroup = state.panelLayout.layout.groups.first { $0.position == .top }
        let topHeight: CGFloat = (topGroup != nil) ? (topGroup!.size ?? 44) : 0
        let bottomGroup = state.panelLayout.layout.groups.first { $0.position == .bottom }
        let bottomHeight: CGFloat = (bottomGroup != nil) ? (bottomGroup!.size ?? 120) : 0
        // Approximation: viewer takes the middle row, minus left + right.
        let viewerW = max(0, content.width - leftWidth - rightWidth)
        let viewerH = max(0, content.height - topHeight - bottomHeight)
        let viewerX = leftWidth
        let viewerY = topHeight

        // Debounce: skip if the frame and panel widths haven't changed.
        let key = CGRect(
            x: frame.origin.x + leftWidth + topHeight * 0.0001,
            y: frame.origin.y + viewerW * 0.0001,
            width: frame.width, height: frame.height
        )
        if reason == "resize" && abs(key.width - lastLogged.width) < 0.5 &&
            abs(key.height - lastLogged.height) < 0.5 &&
            abs(key.origin.x - lastLogged.origin.x) < 0.5 &&
            abs(key.origin.y - lastLogged.origin.y) < 0.5 {
            return
        }
        lastLogged = key

        MCPAuditLogger.shared.log([
            ("app", "window.resize"),
            ("reason", reason),
            ("window", "[\(fmt(frame.origin.x)),\(fmt(frame.origin.y)),\(fmt(frame.width)),\(fmt(frame.height))]"),
            ("content", "[\(fmt(content.width)),\(fmt(content.height))]"),
            ("file_panel_visible", isVisible ? "true" : "false"),
            ("file_panel", "[\(fmt(leftWidth))]"),
            ("right_panel", "[\(fmt(rightWidth))]"),
            ("top_panel", "[\(fmt(topHeight))]"),
            ("bottom_panel", "[\(fmt(bottomHeight))]"),
            ("viewer", "[\(fmt(viewerX)),\(fmt(viewerY)),\(fmt(viewerW)),\(fmt(viewerH))]"),
        ])
    }

    private func fmt(_ d: CGFloat) -> String {
        String(format: "%.0f", Double(d))
    }
}

/// SwiftUI shim that locates the hosting `NSWindow` once and hands it
/// to `WindowGeometryReporter`. Mount once at the top of `ContentView`.
public struct WindowGeometryAttach: NSViewRepresentable {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let w = v.window {
                WindowGeometryReporter.shared.attach(to: w, state: state)
            }
        }
        return v
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}
