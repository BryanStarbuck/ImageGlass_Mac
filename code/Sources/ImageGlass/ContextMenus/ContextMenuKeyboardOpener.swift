import AppKit
import ImageGlassCore

/// docs/right_click.mdx §13 — `⇧F10` opens the context menu of the
/// focused row/canvas via keyboard alone, mirroring the right-click
/// path.
///
/// Registered once at app launch from `ImageGlassApp` /
/// `AboutAppDelegate`. The handler looks at the first responder of the
/// key window and, if it sits inside a SwiftUI view that has attached
/// the `ContextMenuBridge`, locates the overlay and calls its
/// `menu(for:)` with a synthesized right-click event positioned at the
/// row's vertical center.
@MainActor
final class ContextMenuKeyboardOpener {
    static let shared = ContextMenuKeyboardOpener()

    private var monitor: Any?

    private init() {}

    /// Idempotent — call once on `applicationDidFinishLaunching`.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.matchesShiftF10(event) {
                if self.openContextMenuAtFocus() { return nil }
            }
            return event
        }
    }

    private func matchesShiftF10(_ event: NSEvent) -> Bool {
        // F10 = NSF10FunctionKey (0xF70D). The `shift` modifier must be
        // pressed; ignore the others (caps lock, numeric keypad bits).
        let chars = event.charactersIgnoringModifiers ?? ""
        let f10 = String(format: "%c", 0xF70D)
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        return chars == f10 && mods == [.shift]
    }

    /// Locate the nearest `ContextMenuOverlayView` ancestor of the
    /// current first responder and pop its menu. Returns true when a
    /// menu was opened.
    private func openContextMenuAtFocus() -> Bool {
        guard let win = NSApp.keyWindow else { return false }
        var responder: NSResponder? = win.firstResponder
        while let r = responder {
            if let view = r as? NSView {
                if let overlay = findOverlay(in: view) {
                    return popUp(overlay: overlay, in: win)
                }
                // Walk up the superview chain so a focused child
                // (e.g., the include-swatch button) still routes to the
                // row-level overlay.
                if let parent = view.superview,
                   let overlay = findOverlay(in: parent) {
                    return popUp(overlay: overlay, in: win)
                }
            }
            responder = r.nextResponder
        }
        return false
    }

    private func findOverlay(in view: NSView) -> ContextMenuOverlayView? {
        if let o = view as? ContextMenuOverlayView { return o }
        for sub in view.subviews {
            if let o = findOverlay(in: sub) { return o }
        }
        return nil
    }

    private func popUp(overlay: ContextMenuOverlayView, in win: NSWindow) -> Bool {
        let rect = overlay.convert(overlay.bounds, to: nil)
        let location = NSPoint(x: rect.midX, y: rect.midY)
        let synth = NSEvent.mouseEvent(with: .rightMouseDown,
                                       location: location,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber,
                                       context: nil,
                                       eventNumber: 0,
                                       clickCount: 1,
                                       pressure: 0)
        guard let synth, let menu = overlay.menu(for: synth) else { return false }
        let screenPt = win.convertPoint(toScreen: location)
        let view = overlay
        let pointInView = view.convert(NSPoint(x: rect.midX,
                                               y: rect.midY),
                                       from: nil)
        NSMenu.popUpContextMenu(menu, with: synth, for: view)
        _ = screenPt; _ = pointInView
        return true
    }
}
