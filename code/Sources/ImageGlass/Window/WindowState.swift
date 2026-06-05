import AppKit
import Foundation
import ImageGlassCore

/// Per-window in-memory state (multi_window.mdx §4.1). One instance per
/// `window_id`. Holds the per-window subset of state that used to live
/// on `AppState`, plus the lazy bookkeeping the `WindowRegistry`
/// (§4.2) needs to bring the window forward / send it to the trash.
///
/// In Group A this type is **purely additive** — it is constructed but
/// not yet wired into the existing GUI / MCP flow. Groups B–D fold it
/// into the actual viewer / panel / MCP layers, replacing
/// `AppState.shared`'s per-window-shaped fields one by one. Keeping
/// the data model independent here lets the migration land
/// incrementally without breaking the build.
@MainActor
public final class WindowState {

    public let windowID: Int

    /// On-disk YAML mirror. Loaded eagerly at construction; written
    /// back through `settingsStore`.
    public var settings: WindowScopedSettings

    /// Atomic YAML I/O for `settings_window_<windowID>.yaml`.
    public let settingsStore: WindowScopedSettingsStore

    /// Atomic YAML I/O for `directories_window_<windowID>.yaml`. The
    /// MCP `add_directory` / `remove_directory` family resolves to
    /// this store when this window is the frontmost MCP target
    /// (§6.1).
    public let directoriesStore: DirectoriesStore

    /// AppKit window instance. `nil` when the window is in a closed
    /// state but the on-disk YAML is preserved
    /// (multi_window.mdx §1.1).
    public weak var window: NSWindow?

    /// Live slideshow state. Mirrors `settings.slideshow.currentIndex`
    /// for persistence and adds the runtime `isRunning` / `isPaused`
    /// flags that are intentionally **not** persisted across quit
    /// (§7.1, §7.4).
    public var slideshow: WindowSlideshowRuntimeState

    public var isOpen: Bool { window != nil }
    public var isFrontmost: Bool { window?.isKeyWindow == true }

    /// Human-readable title for the Window menu auto-list (§5.5).
    public var displayTitle: String {
        if let name = settings.windowName, !name.isEmpty {
            return "Window \(windowID) — \(name)"
        }
        return "Window \(windowID)"
    }

    public init(
        windowID: Int,
        settings: WindowScopedSettings,
        settingsStore: WindowScopedSettingsStore,
        directoriesStore: DirectoriesStore
    ) {
        precondition(windowID >= 1, "window_id must be >= 1")
        precondition(settings.windowID == windowID,
            "settings.windowID=\(settings.windowID) does not match WindowState.windowID=\(windowID)")
        precondition(settingsStore.windowID == windowID,
            "settingsStore.windowID=\(settingsStore.windowID) does not match WindowState.windowID=\(windowID)")
        precondition((directoriesStore.windowID ?? windowID) == windowID,
            "directoriesStore.windowID=\(String(describing: directoriesStore.windowID)) does not match WindowState.windowID=\(windowID)")
        self.windowID = windowID
        self.settings = settings
        self.settingsStore = settingsStore
        self.directoriesStore = directoriesStore
        self.slideshow = WindowSlideshowRuntimeState(persisted: settings.slideshow)
    }

    // MARK: - Persistence helpers

    /// Snapshot the in-memory state into the persisted `slideshow`
    /// block and flush. Called on quit (§7.4) and on debounce.
    public func persistSlideshow() throws {
        try settingsStore.mutate { s in
            s.slideshow.currentIndex = slideshow.currentIndex
            s.slideshow.wasRunningOnQuit = slideshow.isRunning
            self.settings.slideshow = s.slideshow
        }
    }

    /// Snapshot the active selection and flush.
    public func persistSelection(_ absolutePath: String?) throws {
        try settingsStore.mutate { s in
            s.session.selection.currentFile = absolutePath
            self.settings.session.selection.currentFile = absolutePath
        }
    }

    public func persistWasOpenOnQuit(_ wasOpen: Bool) throws {
        try settingsStore.mutate { s in
            s.session.wasOpenOnQuit = wasOpen
            self.settings.session.wasOpenOnQuit = wasOpen
        }
    }

    public func rename(_ newName: String?) throws {
        try settingsStore.mutate { s in
            s.windowName = newName
            self.settings.windowName = newName
        }
        window?.title = settings.windowName ?? "ImageGlass"
    }
}

/// Runtime slideshow state (multi_window.mdx §7.1). `isRunning` and
/// `isPaused` are intentionally **not** persisted; only `currentIndex`
/// and the `wasRunningOnQuit` record are written on clean quit (§7.4).
public struct WindowSlideshowRuntimeState: Sendable {
    public var isRunning: Bool = false
    public var isPaused: Bool = false
    public var currentIndex: Int = 0
    public var lastAdvancedAt: Date? = nil

    public init(persisted: WindowSlideshowState) {
        // §7.4: live `isRunning` always starts false even if the
        // previous launch was mid-slideshow. The carry-over flag is
        // used only for the `slideshow_carryover=true` audit line.
        self.isRunning = false
        self.isPaused = false
        self.currentIndex = persisted.currentIndex
        self.lastAdvancedAt = nil
    }
}
