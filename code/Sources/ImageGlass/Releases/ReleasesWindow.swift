import AppKit
import SwiftUI

/// Shows the "Releases & News" window as a single shared, reusable instance.
/// Picking the menu item a second time brings the existing window forward
/// rather than opening a duplicate.
@MainActor
final class ReleasesWindowController {
    static let shared = ReleasesWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ReleasesView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Releases & News"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 720, height: 640))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = WindowDelegate.shared
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    fileprivate func windowDidClose() {
        window = nil
    }

    @MainActor
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        static let shared = WindowDelegate()
        func windowWillClose(_ notification: Notification) {
            ReleasesWindowController.shared.windowDidClose()
        }
    }
}
