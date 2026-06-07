@preconcurrency import AppKit
import SwiftUI
import ImageGlassCore

/// docs/right_click.mdx §9.2 — SwiftUI ↔ AppKit `menu(for:)` bridge.
///
/// SwiftUI's `.contextMenu { }` modifier on macOS today does not render
/// keyboard-shortcut twins next to its items, and does not surface
/// disabled-item tooltips. The fork's docked Directory Panel needs both,
/// so panel rows attach an invisible `NSView` overlay that owns an
/// `NSMenu` and overrides `menu(for event: NSEvent)`.
///
/// The overlay is **non-interactive** for left clicks
/// (`acceptsFirstMouse(for:)` returns false; `hitTest` returns nil), so
/// it does not steal the row's tap gestures or the include-swatch
/// button. Right-clicks bypass SwiftUI hit-testing entirely — AppKit
/// dispatches `rightMouseDown` through `menu(for:)`, which is exactly
/// what we want.
///
/// Per §3.3, the bridge calls a `preselect` closure right before
/// returning the menu so the right-clicked row becomes the active
/// selection on the way to the menu open.
struct ContextMenuBridge: NSViewRepresentable {

    /// Closure that builds the menu against the current selection.
    /// Run on every right-click so the menu reflects live state
    /// (include-swatch state, multi-select count, file-exists flag).
    var menuBuilder: @MainActor () -> NSMenu?

    /// §3.3 — runs **before** the menu builder so the row becomes the
    /// active selection on the way in. Defaults to a no-op.
    var preselect: @MainActor () -> Void = {}

    /// §9.4 — surface id for the `menu.open` line. Telemetry only.
    var surface: ContextMenuActions.SurfaceID

    /// Optional path of the row this bridge belongs to. Telemetry only.
    var targetPath: String? = nil

    func makeNSView(context: Context) -> ContextMenuOverlayView {
        let v = ContextMenuOverlayView()
        v.menuBuilder = menuBuilder
        v.preselect = preselect
        v.surface = surface
        v.targetPath = targetPath
        return v
    }

    func updateNSView(_ nsView: ContextMenuOverlayView, context: Context) {
        nsView.menuBuilder = menuBuilder
        nsView.preselect = preselect
        nsView.surface = surface
        nsView.targetPath = targetPath
    }
}

/// The actual AppKit subview. `wantsLayer = true` keeps it cheap; the
/// view is transparent and never draws.
final class ContextMenuOverlayView: NSView {
    var menuBuilder: (@MainActor () -> NSMenu?)?
    var preselect: (@MainActor () -> Void)?
    var surface: ContextMenuActions.SurfaceID = .panelEmpty
    var targetPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// Make sure left-clicks pass through to the SwiftUI hit-test plane.
    /// Returning nil from `hitTest` removes us from the responder chain
    /// for pointer events; right-clicks still arrive via the window's
    /// `rightMouseDown` -> `menu(for:)` dispatch (AppKit handles those
    /// independent of hit-testing).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Returning self for right-click events means AppKit calls
        // `menu(for:)` on us. For everything else, return nil so the
        // event passes through to the SwiftUI parent.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown
            || (event.type == .leftMouseDown
                && event.modifierFlags.contains(.control)) {
            return self
        }
        return nil
    }

    /// AppKit's right-click handler. We rebuild the menu on each fire
    /// so it reflects live state.
    override func menu(for event: NSEvent) -> NSMenu? {
        preselect?()
        guard let menu = menuBuilder?() else { return nil }
        ContextMenuActions.recordOpen(menu: surface,
                                      itemCount: menu.items.count,
                                      targetPath: targetPath)
        return menu
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

/// docs/right_click.mdx §9.3 — a tiny shared box that lets a
/// right-click verb (*Open in New Window*) stage the path the next
/// `newWindow:` action should pre-select. The SwiftUI WindowGroup's
/// bootstrap reads this on first paint and clears it.
@MainActor
final class PendingNewWindowSelection {
    static let shared = PendingNewWindowSelection()
    var path: String?
    private init() {}

    /// Consume and clear in one call. Called by the new window's
    /// bootstrap path.
    func take() -> String? {
        defer { path = nil }
        return path
    }
}
