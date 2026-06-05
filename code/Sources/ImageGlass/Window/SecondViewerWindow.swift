import AppKit
import SwiftUI
import ImageGlassCore

/// Detached floating window that mirrors the main viewer's currently
/// selected image. No panels, no overlays, no status bar — just the
/// image. Whenever `state.selectedFile` changes, this window loads the
/// same file and updates its title to `Second: <filename>`.
///
/// Lives as a single shared instance so the View-menu toggle reuses
/// the same window rather than spawning duplicates. The window uses
/// `.floating` level so it stays above the main viewer.
@MainActor
final class SecondViewerWindowController {
    static let shared = SecondViewerWindowController()

    private var window: NSWindow?

    private init() {}

    var isVisible: Bool { window?.isVisible == true }

    func show(state: AppState) {
        if let existing = window {
            Self.placeOnMainWindowScreen(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SecondViewerContentView(state: state))
        let win = NSWindow(contentViewController: hosting)
        win.title = Self.title(for: state.selectedFile)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 640, height: 480))
        win.minSize = NSSize(width: 240, height: 180)
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.level = .floating
        win.delegate = WindowDelegate.shared
        Self.placeOnMainWindowScreen(win)

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle(state: AppState) {
        if isVisible { hide() } else { show(state: state) }
    }

    /// Called from the SwiftUI content view whenever `state.selectedFile`
    /// changes. Updates the title bar to `Second: <filename>`.
    func updateTitle(for selectedFile: String?) {
        window?.title = Self.title(for: selectedFile)
    }

    private static func title(for selectedFile: String?) -> String {
        guard let path = selectedFile else { return "Second: (no image)" }
        let expanded = AppPaths.expandTilde(path)
        return "Second: \((expanded as NSString).lastPathComponent)"
    }

    /// Park the window near the left edge of the main viewer's screen so
    /// it doesn't sit on top of the primary canvas by default.
    private static func placeOnMainWindowScreen(_ win: NSWindow) {
        let main = NSApp.windows.first { other in
            other !== win
                && other.canBecomeMain
                && other.styleMask.contains(.titled)
                && other.isVisible
        }
        let screen = main?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let target = screen else { win.center(); return }

        let visible = target.visibleFrame
        var f = win.frame
        f.origin.x = visible.minX + 24
        f.origin.y = visible.midY - f.height / 2
        win.setFrame(f, display: true)
    }

    fileprivate func windowDidClose() {
        // isReleasedWhenClosed=false keeps the NSWindow alive after the
        // user clicks the red traffic light; nothing to clean up.
    }

    @MainActor
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        static let shared = WindowDelegate()
        func windowWillClose(_ notification: Notification) {
            SecondViewerWindowController.shared.windowDidClose()
        }
    }
}

/// Content view rendered inside the second viewer window. Hosts the
/// AppKit `ImageCanvasView` directly — no overlays, no panels, no
/// status bar. Observes `state.selectedFile` and forwards both the
/// new path (to the canvas) and the title update (to the controller).
struct SecondViewerContentView: View {
    @Bindable var state: AppState

    var body: some View {
        SecondImageCanvasHost(path: resolvedPath)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .onChange(of: state.selectedFile, initial: true) { _, _ in
                SecondViewerWindowController.shared.updateTitle(for: state.selectedFile)
            }
    }

    private var resolvedPath: String? {
        state.selectedFile.map { AppPaths.expandTilde($0) }
    }
}

/// Minimal SwiftUI ↔ AppKit bridge: a fresh `ImageCanvasView` whose
/// only input is the path. We deliberately do not wire any of the
/// viewer-state knobs (zoom, pan, rotation, color picker, animation
/// pause) — this is a passive mirror, so it always renders the image
/// at fit-to-window and ignores the main viewer's user gestures.
private struct SecondImageCanvasHost: NSViewRepresentable {
    let path: String?

    func makeNSView(context: Context) -> ImageCanvasView {
        let v = ImageCanvasView()
        v.zoomMode = .fit
        return v
    }

    func updateNSView(_ v: ImageCanvasView, context: Context) {
        if v.loadedPath != path {
            // Log every load attempt. ErrorLog prepends an ISO-8601
            // timestamp, so the line in ~/Library/Application Support/
            // ImageGlass_Mac/log.log looks like:
            //   [2026-06-03T14:23:11.482Z] [...] [SecondViewer] attempting to load: <full path>
            ErrorLog.log(
                "attempting to load: \(path ?? "(nil — clearing canvas)")",
                class: "SecondViewer"
            )

            if let p = path {
                // Pre-flight the same validation `ImageCanvasView.setImage`
                // runs internally, so a bad path produces a labelled
                // "SecondViewer" error line in addition to the canvas's
                // generic one. Each failure mode names the specific reason.
                let result = ImageCanvasView.validate(path: p)
                if result != .ok {
                    ErrorLog.log(
                        "failed to load image (\(result)): \(p)",
                        class: "SecondViewer"
                    )
                } else if NSImage(contentsOfFile: p) == nil {
                    // Path is a readable file but ImageIO/NSImage couldn't
                    // decode it — bad header, unsupported codec, etc.
                    ErrorLog.log(
                        "failed to decode image data at: \(p)",
                        class: "SecondViewer"
                    )
                }
            }

            v.setImage(path: path)
            v.toolTip = path
        }
        v.zoomMode = .fit
    }
}
