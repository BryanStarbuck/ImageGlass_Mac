import AppKit
import SwiftUI
import ImageGlassCore

/// Global bare-`S` slideshow toggle (slideshow.mdx §3 — "S is a
/// dependable play/stop toggle regardless of window focus").
///
/// Why this exists: the SwiftUI `.onKeyPress("s")` binding in
/// `ImageGlassHotkeysModifier` only fires when a *focusable* canvas or
/// panel view is first responder. When the "Filter files" `TextField`
/// (or any other text field) owns first-responder — which is exactly
/// where focus lands when the window opens — AppKit routes the
/// keystroke into the field and the SwiftUI handler never sees it, so
/// `S` typed an "s" into the filter instead of starting/stopping the
/// show. This app-level `NSEvent` key-down monitor intercepts a bare
/// `S` (no ⌘/⌥/⌃) *before* it reaches the focused field, toggles the
/// slideshow, and swallows the event so it neither types into the
/// filter nor double-fires the SwiftUI handler.
///
/// Scope guards keep the override narrow so ordinary text entry still
/// works everywhere it should:
///   * a modal session (NSAlert / Open / Save panels) is never touched
///     — `NSApp.modalWindow != nil` passes the key through so the user
///     can still type paths / filenames containing "s";
///   * only a **main viewer window** is hijacked — the Settings /
///     About / Releases / floating auxiliary windows pass the key
///     through untouched;
///   * crop mode passes the key through (matches the existing
///     `handleSlideshowKey` guard — the user is mid-task).
@MainActor
final class SlideshowHotkeyMonitor {
    static let shared = SlideshowHotkeyMonitor()

    private var monitor: Any?
    private weak var appState: AppState?

    private init() {}

    /// Install the process-wide monitor once. Safe to call from every
    /// window's `.onAppear` / `.task`; only the first call installs the
    /// `NSEvent` monitor, later calls just refresh the `AppState`
    /// reference the toggle reads its interval / navigation list from.
    func installIfNeeded(appState: AppState) {
        self.appState = appState
        guard monitor == nil else { return }
        // Extract only Sendable primitives (`ModifierFlags`, `String`)
        // from the non-Sendable `NSEvent` before hopping onto the main
        // actor. Key-down events are already delivered on the main
        // thread, so `assumeIsolated` is safe here.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags
            let chars = event.charactersIgnoringModifiers
            let swallow = MainActor.assumeIsolated {
                SlideshowHotkeyMonitor.shared.shouldToggle(modifiers: modifiers, chars: chars)
            }
            return swallow ? nil : event
        }
    }

    /// Returns `true` when the event is a bare `S` that should toggle
    /// the slideshow and be swallowed; `false` to let the event pass
    /// through to the normal responder chain.
    private func shouldToggle(modifiers: NSEvent.ModifierFlags, chars: String?) -> Bool {
        // Bare `S` only. Any ⌘/⌥/⌃ chord routes to the menu (⌥⌘S) or
        // other bindings, exactly like `handleSlideshowKey`. Shift is
        // allowed so a shifted `S` still toggles.
        let blocking: NSEvent.ModifierFlags = [.command, .option, .control]
        guard modifiers.intersection(blocking).isEmpty else { return false }
        guard chars?.lowercased() == "s" else { return false }
        // Never override text entry inside a modal alert / open / save
        // panel — the user may be typing a path or filename with an "s".
        guard NSApp.modalWindow == nil else { return false }
        // Only hijack a real main viewer window; leave Settings / About /
        // Releases / floating auxiliaries alone.
        guard let keyWin = NSApp.keyWindow,
              Self.isMainViewerWindow(keyWin) else { return false }
        guard let appState else { return false }
        // Mid-crop: leave the key alone (the user is in the crop loop).
        guard !appState.crop.isActive else { return false }

        SlideshowController.shared.toggle(appState: appState, source: "key:S:global")
        return true
    }

    /// A "main viewer window" is one the `WindowStateController`
    /// attached to on launch, or any window bound to a registered
    /// `WindowState` (the ⌘N multi-window case). Auxiliary windows
    /// (Settings, About, Releases, Second Viewer, Floating File Tree)
    /// and transient modal panels are deliberately excluded.
    private static func isMainViewerWindow(_ window: NSWindow) -> Bool {
        if WindowStateController.shared.window === window { return true }
        return WindowRegistry.shared.windows.values.contains { $0.window === window }
    }
}
