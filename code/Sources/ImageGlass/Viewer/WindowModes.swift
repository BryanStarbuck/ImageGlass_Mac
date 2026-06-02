import AppKit
import SwiftUI
import ImageGlassCore

/// Helpers for the three "window display" modes: full screen, frameless,
/// and window-fit (resize the window to the image's intrinsic size).
@MainActor
enum WindowModes {

    /// Toggle native full-screen on the key window.
    static func toggleFullScreen() {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        win.toggleFullScreen(nil)
    }

    /// Toggle "frameless" — hides the title bar and chrome but keeps the
    /// window resizable.
    static func toggleFrameless(_ enabled: Bool) {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if enabled {
            win.styleMask.insert(.borderless)
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.standardWindowButton(.closeButton)?.isHidden       = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden        = true
        } else {
            win.styleMask.remove(.borderless)
            win.titlebarAppearsTransparent = false
            win.titleVisibility = .visible
            win.standardWindowButton(.closeButton)?.isHidden       = false
            win.standardWindowButton(.miniaturizeButton)?.isHidden = false
            win.standardWindowButton(.zoomButton)?.isHidden        = false
        }
    }

    /// Resize the key window so the content area matches the displayed
    /// image's natural pixel size, clamped to the visible screen rect.
    static func fitWindowToImage(path: String?) {
        guard let path else { return }
        let expanded = AppPaths.expandTilde(path)
        guard let img = NSImage(contentsOfFile: expanded) else {
            ErrorLog.log("fitWindowToImage: NSImage(contentsOfFile:) failed for \(expanded)",
                         class: "WindowModes")
            return
        }
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let screenFrame = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let inset: CGFloat = 32
        let maxW = max(320, screenFrame.width  - inset)
        let maxH = max(240, screenFrame.height - inset)

        var target = img.size
        let ratio = min(maxW / max(target.width, 1), maxH / max(target.height, 1))
        if ratio < 1 {
            target.width  *= ratio
            target.height *= ratio
        }
        win.setContentSize(target)
        win.center()
    }
}
