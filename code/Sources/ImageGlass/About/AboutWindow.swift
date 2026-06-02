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
///
/// This delegate also owns the Cocoa application-lifecycle hooks SwiftUI
/// still doesn't surface in macOS 14: Finder "Open With…" routing,
/// dock-icon reopen, and "Open Recent" tracking. The delegate posts
/// `Notification.Name.imageGlassOpenURLs` whenever the system asks the app
/// to open files; `ContentView` observes that notification and forwards
/// the URLs to `AppState.openExternalFile(url:)`.
final class AboutAppDelegate: NSObject, NSApplicationDelegate {
    /// URLs received from AppKit before the SwiftUI window finished its
    /// first `.task` (the cold-launch "Open With…" case). They get
    /// re-broadcast as soon as a listener appears via `flushPendingOpens`.
    @MainActor private static var pendingURLs: [URL] = []
    @MainActor private static var hasListener: Bool = false

    @MainActor
    @objc func orderFrontStandardAboutPanel(_ sender: Any?) {
        AboutWindowController.show()
    }

    // MARK: - Finder "Open With…" / drag-onto-app-icon

    /// Called when the user opens one or more files from Finder by
    /// double-clicking, drag-drop onto the app icon, or `open -a ImageGlass`.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Self.routeOpen(urls: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    /// Newer URL-based variant (universal links, drag-drop on Sequoia+).
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.routeOpen(urls: urls)
    }

    /// Dock-icon click when there are no visible windows: re-show the
    /// main window instead of leaving the user staring at the dock.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for win in sender.windows where win.canBecomeMain {
                win.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    /// Mac-native viewers (Preview, Pixea) terminate on last-window-close.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched via `swift run` (no .app bundle), the process can
        // come up as an accessory and never bring its window to the front.
        NSApp.setActivationPolicy(.regular)
        // Recenter the SwiftUI window on the cursor's screen if it restored
        // a frame to a monitor the user isn't looking at.
        Self.installFirstWindowRelocator()
        // Single-line charter audit so a silent regression shows up in logs.
        NSLog("%@", CharterStatus.summary())
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

    @MainActor
    private static func routeOpen(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let docs = NSDocumentController.shared
        for url in urls {
            docs.noteNewRecentDocumentURL(url)
        }
        if hasListener {
            NotificationCenter.default.post(
                name: .imageGlassOpenURLs,
                object: nil,
                userInfo: ["urls": urls]
            )
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// Called by the SwiftUI root once it has subscribed to the notification.
    /// Drains buffered URLs received during cold-launch Finder "Open With…".
    @MainActor
    static func registerListenerAndFlush() {
        hasListener = true
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        NotificationCenter.default.post(
            name: .imageGlassOpenURLs,
            object: nil,
            userInfo: ["urls": urls]
        )
    }
}

extension Notification.Name {
    /// Posted by `AboutAppDelegate` whenever AppKit asks the app to open
    /// one or more file URLs from outside the SwiftUI window. Payload:
    ///   `userInfo["urls"]: [URL]`
    static let imageGlassOpenURLs = Notification.Name("ImageGlassOpenURLs")
}
