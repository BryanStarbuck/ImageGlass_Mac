import AppKit
import SwiftUI
import ImageGlassCore

/// Owns the single About window instance and shows/hides it on demand.
///
/// We bypass `WindowGroup` for About because:
///   1. SwiftUI's `WindowGroup` can spawn duplicate windows, which is
///      wrong UX for an About dialog.
///   2. We need to replace the standard `App > About ImageGlass` menu
///      item, which routes to `NSApplication.orderFrontStandardAboutPanel(_:)`.
///      An `NSWindowController` lets us intercept that and present
///      `AboutView` instead.
@MainActor
enum AboutWindowController {

    private static var window: NSWindow?

    /// Public entry point. Called from:
    ///   - The custom `About ImageGlass` menu command in `ImageGlassApp`.
    ///   - The `AppDelegate`'s override of `orderFrontStandardAboutPanel(_:)`.
    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "About \(AboutInfo.projectName)"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.setContentSize(NSSize(width: 560, height: 640))
        win.minSize = NSSize(width: 480, height: 480)

        // Track close so we can re-create cleanly next time.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AboutWindowController.window = nil
            }
        }

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `NSApplicationDelegate` that intercepts the system About menu item so
/// the standard Apple panel is never shown — our custom one is shown
/// instead. SwiftUI doesn't expose a first-class hook for replacing the
/// About item's action; subclassing `NSApplication`'s delegate is the
/// supported workaround on macOS 14.
final class AboutAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    @objc func orderFrontStandardAboutPanel(_ sender: Any?) {
        AboutWindowController.show()
    }
}
