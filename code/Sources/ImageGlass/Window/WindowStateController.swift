import AppKit
import Foundation
import ImageGlassCore

/// Multi-monitor window-state controller. See `docs/multi_monitor.mdx`.
///
/// One instance, attached to the main viewer `NSWindow`. Responsibilities:
///
///   * Restore the window to its saved `(display, frame, fullscreen, zoomed)`
///     state on first attach (§5.1, §5.2).
///   * Observe `NSWindowDelegate` notifications and write the current state
///     back to `state.settings.window` on a debounce (§5.3).
///   * Force a synchronous save on `applicationWillTerminate` so the very
///     last move/resize is on disk before the process exits.
///   * Re-apply the saved `last_selected_file` to `state.selectedFile`
///     after `state.bootstrap()` resolves the scope (§7.4).
///
/// The controller is the *sole* writer of `state.settings.window`; the
/// SwiftUI Settings UI does not bind to these fields.
@MainActor
final class WindowStateController: NSObject {

    static let shared = WindowStateController()

    weak var window: NSWindow?
    weak var appState: AppState?

    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    private var selectionSaveTask: Task<Void, Never>?

    /// True after we have applied the saved frame to the window at least
    /// once. Subsequent `windowDidChangeScreen` events update the saved
    /// `display_id`; before this flag flips, they are ignored so the
    /// restore itself does not get treated as a user-initiated move.
    private var hasRestored = false

    /// Timestamp at which the window became stable on a fallback display
    /// (§6.3). Used to decide when to commit the new `display_id` to
    /// disk vs. preserving the original one in hope of a reconnect.
    private var fallbackSettledAt: Date?

    private override init() {
        super.init()
    }

    // MARK: - Wiring

    /// Called from `ContentView.task` after `state.bootstrap()` resolves
    /// settings and the scope. Finds the main viewer window, applies the
    /// saved frame, installs delegate observers, and schedules a
    /// selection restore.
    func bootstrap(appState: AppState) {
        self.appState = appState

        // Find the main viewer window. SwiftUI may not have a key window
        // yet on a very cold launch; if we don't find one, retry on the
        // next `didBecomeKeyNotification`.
        if let win = Self.findMainWindow() {
            attach(window: win)
        } else {
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard let win = note.object as? NSWindow,
                          win.styleMask.contains(.titled),
                          win.canBecomeMain
                    else { return }
                    self.attach(window: win)
                    self.removePendingFirstKeyObserver()
                }
            }
            observers.append(token)
        }

        // Selection restore is independent of having an attached window —
        // it just needs `resolvedFiles` to be populated.
        restoreSelection()

        // Whenever the user changes selection going forward, debounce-save it.
        observeSelectionChanges()
    }

    private func removePendingFirstKeyObserver() {
        // Strip the becomeKey observer once we've attached.
        if let token = observers.first {
            NotificationCenter.default.removeObserver(token)
            observers.removeFirst()
        }
    }

    /// Attach to a concrete `NSWindow`. Idempotent.
    func attach(window: NSWindow) {
        if self.window === window { return }
        self.window = window
        applyRestoredFrame(to: window)
        installWindowObservers(window)
        installTerminationObserver()
    }

    // MARK: - Restore

    /// Spec §5.2. Resolves the saved display by UUID, computes the
    /// absolute target frame, clamps it to the visible rect, and applies
    /// it to the window. Restores zoomed + fullscreen flags.
    private func applyRestoredFrame(to window: NSWindow) {
        // docs/performance.mdx §5.4 / §10.12 — `Window.ApplyState`.
        let _trace = PerformanceLog.shared.start("Window.ApplyState")
        defer { _trace.finish() }
        guard let saved = appState?.settings.window else { return }

        let targetScreen = WindowDisplayResolver.screen(forUUID: saved.display_id)
            ?? NSScreen.main
        guard let screen = targetScreen else {
            hasRestored = true
            return
        }

        let visible = screen.visibleFrame
        let frame = saved.frame.flatMap { f -> NSRect? in
            let absolute = WindowGeometry.absolute(
                local: f,
                displayOriginX: Double(screen.frame.origin.x),
                displayOriginY: Double(screen.frame.origin.y)
            )
            let clamped = WindowGeometry.clamp(
                x: absolute.x, y: absolute.y,
                width: absolute.width, height: absolute.height,
                visibleMinX: Double(visible.minX),
                visibleMinY: Double(visible.minY),
                visibleMaxX: Double(visible.maxX),
                visibleMaxY: Double(visible.maxY)
            )
            return NSRect(x: clamped.x, y: clamped.y,
                          width: clamped.width, height: clamped.height)
        }

        if let frame {
            window.setFrame(frame, display: true)
        } else {
            // First launch: center default size on chosen screen.
            let size = NSSize(width: 1100, height: 760)
            let centered = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width, height: size.height
            )
            window.setFrame(centered, display: true)
        }

        if saved.zoomed && !window.isZoomed {
            window.zoom(nil)
        }
        if saved.fullscreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        hasRestored = true
    }

    /// Spec §7.4. Apply `last_selected_file` to `AppState.selectedFile`
    /// once the active scope has resolved its file list. Also drains
    /// `PendingNewWindowSelection` — when the user fired *Open in New
    /// Window* from a context menu (docs/right_click.mdx §7.1 item 2),
    /// the staged path takes precedence over the saved selection so
    /// the freshly-spawned window opens with the file the user clicked.
    private func restoreSelection() {
        guard let state = appState else { return }
        // docs/right_click.mdx §9.3 — context-menu New Window override.
        if let pending = PendingNewWindowSelection.shared.take() {
            let abs = AppPaths.expandTilde(pending)
            if FileManager.default.fileExists(atPath: abs) {
                state.openExternalFile(url: URL(fileURLWithPath: abs))
                return
            }
        }
        guard let path = state.settings.window.last_selected_file else { return }
        let resolved = state.resolvedFiles
        if resolved.contains(path) {
            state.selectedFile = path
            return
        }
        let abs = AppPaths.expandTilde(path)
        if FileManager.default.fileExists(atPath: abs) {
            state.openExternalFile(url: URL(fileURLWithPath: abs))
        }
        // else: file is gone; leave saved path on disk so a future re-mount
        //       can still recover it (spec §7.4 last paragraph).
    }

    // MARK: - Observation

    private func installWindowObservers(_ window: NSWindow) {
        let nc = NotificationCenter.default
        let notes: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification
        ]
        for name in notes {
            let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.scheduleSave()
                }
            }
            observers.append(token)
        }
    }

    private func observeSelectionChanges() {
        // AppState is an @Observable class; we can't easily KVO it. Drive
        // selection persistence by polling on a low-frequency Task — the
        // user only changes selection by arrow keys / clicks, and a 250 ms
        // tick is well below human-noticeable.
        selectionSaveTask?.cancel()
        selectionSaveTask = Task { [weak self] in
            var lastSeen: String? = nil
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                let current = await MainActor.run { self.appState?.selectedFile }
                if current != lastSeen {
                    lastSeen = current
                    await MainActor.run { self.scheduleSave() }
                }
            }
        }
    }

    private func installTerminationObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.saveNow()
            }
        }
        observers.append(token)
    }

    // MARK: - Save

    /// Spec §5.3 (debounced). Coalesces bursts of resize/move events
    /// into a single write 500 ms after the last event.
    private func scheduleSave() {
        guard hasRestored else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.saveNow() }
        }
    }

    /// Synchronous capture-then-persist. Called by the debounce path and
    /// by the terminate observer.
    func saveNow() {
        guard let state = appState else { return }
        captureCurrentState(into: &state.settings.window)
        Task { [weak state] in
            await state?.saveSettings()
        }
    }

    /// Pure capture: read the window + selection and write into a
    /// `WindowSettings` value. Split out so unit tests can drive it
    /// without an actor hop.
    func captureCurrentState(into target: inout WindowSettings) {
        guard let window else {
            // No window — still update selection.
            target.last_selected_file = appState?.selectedFile
            target.saved_at = Self.iso8601Now()
            return
        }

        let screen = window.screen ?? NSScreen.main
        if let screen {
            let (uuid, name) = WindowDisplayResolver.identity(for: screen)
            let preferredUUID = preferredDisplayUUID(current: uuid, saved: target.display_id)
            target.display_id = preferredUUID
            target.display_name = name

            let g = window.frame
            let o = screen.frame.origin
            target.frame = WindowGeometry.displayLocal(
                globalX: Double(g.minX),
                globalY: Double(g.minY),
                displayOriginX: Double(o.x),
                displayOriginY: Double(o.y),
                width: Double(g.width),
                height: Double(g.height)
            )
        }
        target.fullscreen = window.styleMask.contains(.fullScreen)
        target.zoomed = window.isZoomed
        target.minimized = window.isMiniaturized
        target.last_selected_file = appState?.selectedFile
        target.saved_at = Self.iso8601Now()
    }

    /// Spec §6.3. If the currently-attached screen does not match the
    /// originally-saved one and 60 s have not yet elapsed on the
    /// fallback screen, keep the original UUID so a re-plug restores
    /// the window correctly. Otherwise commit the new UUID.
    private func preferredDisplayUUID(current: String?, saved: String?) -> String? {
        guard let saved else { return current }
        guard let current else { return saved }
        if current == saved {
            fallbackSettledAt = nil
            return current
        }
        if fallbackSettledAt == nil { fallbackSettledAt = Date() }
        if let since = fallbackSettledAt, Date().timeIntervalSince(since) > 60 {
            // User has stayed on the fallback display for >60s — accept it.
            return current
        }
        return saved
    }

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private static func findMainWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.canBecomeMain, key.styleMask.contains(.titled) {
            return key
        }
        return NSApp.windows.first { $0.canBecomeMain && $0.styleMask.contains(.titled) }
    }
}

// MARK: - Display identity (CGDisplayCreateUUIDFromDisplayID wrapper)

/// Maps `NSScreen` <-> stable UUID via `CGDisplayCreateUUIDFromDisplayID`.
/// Spec §4.1.
@MainActor
enum WindowDisplayResolver {

    static func screen(forUUID uuid: String?) -> NSScreen? {
        guard let uuid else { return nil }
        for screen in NSScreen.screens {
            let (u, _) = identity(for: screen)
            if u == uuid { return screen }
        }
        return nil
    }

    /// Returns the display UUID (stable across reboots and reconfiguration)
    /// and the human-readable display name for an `NSScreen`. Either field
    /// may be `nil` on virtual/special displays.
    static func identity(for screen: NSScreen) -> (uuid: String?, name: String?) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let n = screen.deviceDescription[key] as? CGDirectDisplayID else {
            return (nil, screen.localizedName)
        }
        guard let cf = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else {
            return (nil, screen.localizedName)
        }
        let s = CFUUIDCreateString(nil, cf) as String?
        return (s, screen.localizedName)
    }
}
