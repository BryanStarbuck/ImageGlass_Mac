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

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched via `swift run` (no .app bundle), the process can
        // come up as an accessory and never bring its window to the front.
        // Force a regular activation policy so the SwiftUI window is reachable.
        NSApp.setActivationPolicy(.regular)

        // SwiftUI creates the WindowGroup window lazily — it doesn't exist
        // when `applicationDidFinishLaunching` fires. Wait for the first
        // titled window to be created, then recenter it onto the screen
        // that contains the mouse cursor if SwiftUI restored a frame to a
        // monitor the user isn't looking at.
        Self.installFirstWindowRelocator()
    }

    private static nonisolated(unsafe) var mainWindowObserver: NSObjectProtocol?

    @MainActor
    private static func installFirstWindowRelocator() {
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  window.canBecomeMain
            else { return }
            MainActor.assumeIsolated {
                Self.relocateIfOffCursorScreen(window)
                NSApp.activate(ignoringOtherApps: true)
            }
            if let token = mainWindowObserver {
                NotificationCenter.default.removeObserver(token)
                mainWindowObserver = nil
            }
        }
    }

    /// SwiftUI's `WindowGroup` restores the previous frame from
    /// `NSUserDefaults` ("NSWindow Frame …"). If that frame is on a
    /// monitor the user isn't looking at — or on a monitor that's been
    /// disconnected — the window is technically visible but practically
    /// invisible. If the restored frame is on a screen that doesn't contain
    /// the mouse cursor, recenter on the cursor's screen.
    @MainActor
    private static func relocateIfOffCursorScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return
        }
        if let windowScreen = window.screen, windowScreen == cursorScreen {
            return
        }
        let visible = cursorScreen.visibleFrame
        var newFrame = window.frame
        if newFrame.width < 300 { newFrame.size.width = 900 }
        if newFrame.height < 300 { newFrame.size.height = 600 }
        newFrame.origin.x = visible.midX - newFrame.width / 2
        newFrame.origin.y = visible.midY - newFrame.height / 2
        window.setFrame(newFrame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}
