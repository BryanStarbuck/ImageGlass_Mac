import AppKit
import Foundation
import ImageGlassCore

/// Process-wide map of every known window — open, closed, or retired —
/// keyed by `window_id` (multi_window.mdx §4.2). Owns the
/// monotonically-increasing `next_window_id` counter (§1.2), the
/// `frontmostWindowID` used as the implicit MCP target (§6), and the
/// `retiredWindowIDs` set that guarantees a retired number is never
/// reused.
///
/// **Threading**: `@MainActor` so all mutations happen on the main
/// thread. AppKit's window notifications already arrive on the main
/// thread, and the SwiftUI app shell instantiates windows on the main
/// actor, so this is a natural home for the registry.
///
/// **Persistence**: `nextWindowID` and `retiredWindowIDs` round-trip
/// through the application-level YAML helpers exposed in
/// `WindowRegistryPersistence` (added in Group B). Group A keeps the
/// registry purely in-memory so this file does not pull in any new
/// dependencies on the application-level `SettingsStore`.
@MainActor
public final class WindowRegistry {

    public static let shared = WindowRegistry()

    /// All known windows, keyed by `window_id`. Closed windows stay
    /// in the dictionary until explicitly retired (§5.3).
    public private(set) var windows: [Int: WindowState] = [:]

    /// `nil` when no window is open (§6.5). Updated by
    /// `NSWindowDidBecomeKeyNotification` in Group B; tests may set it
    /// directly via `setFrontmost(_:)`.
    public private(set) var frontmostWindowID: Int?

    public private(set) var retiredWindowIDs: Set<Int> = []

    /// Monotonic counter (§1.2). The next allocation returns this
    /// value, then increments. Persisted to the app-level
    /// `settings.yaml` in Group B; in Group A the counter is
    /// purely in-memory and defaults to `max(windows) + 1` when
    /// `bootstrap(loaded:)` reseeds it.
    public private(set) var nextWindowID: Int = 1

    public init() {}

    // MARK: - Allocation

    /// Allocate a fresh `window_id`. Skips any ID in
    /// `retiredWindowIDs` (§5.3 — retired numbers are never reused).
    @discardableResult
    public func allocateNextWindowID() -> Int {
        var id = nextWindowID
        while retiredWindowIDs.contains(id) {
            id += 1
        }
        nextWindowID = id + 1
        return id
    }

    /// Reseed the counter to `max(observed, retired) + 1`. Used at
    /// launch (§14.3) when the persisted counter is missing or behind
    /// the observed maximum on disk.
    public func reseedNextWindowID(observed: [Int]) {
        let max = (observed + retiredWindowIDs).reduce(0, Swift.max)
        nextWindowID = max + 1
    }

    // MARK: - Registration / lookup

    /// Register a fully-constructed `WindowState`. Called by the
    /// factory in Group B; here for tests in Group A.
    public func register(_ state: WindowState) {
        precondition(windows[state.windowID] == nil,
            "Duplicate WindowState registration for window_id=\(state.windowID)")
        windows[state.windowID] = state
    }

    public func window(id: Int) -> WindowState? {
        windows[id]
    }

    /// The full set of open windows, in `window_id` order — useful for
    /// the Window menu's auto-list and the ⌘\` cycle order (§5.4).
    public var openWindows: [WindowState] {
        windows.values
            .filter { $0.isOpen }
            .sorted { $0.windowID < $1.windowID }
    }

    public var closedWindows: [WindowState] {
        windows.values
            .filter { !$0.isOpen }
            .sorted { $0.windowID < $1.windowID }
    }

    /// The current MCP target (§6). When the caller does not specify a
    /// `window_id`, the dispatcher resolves to this window and brings
    /// it forward via `NSWindow.makeKeyAndOrderFront(_:)`.
    public var frontmost: WindowState? {
        guard let id = frontmostWindowID else { return nil }
        return windows[id]
    }

    /// Test hook + Group B wiring point. AppKit's
    /// `NSWindowDidBecomeKeyNotification` listener will call this.
    public func setFrontmost(windowID: Int?) {
        if let id = windowID {
            precondition(windows[id] != nil, "setFrontmost(windowID: \(id)) — unknown window")
        }
        frontmostWindowID = windowID
    }

    // MARK: - Close / retire

    /// Mark a window closed (§1.3 step 5). The `WindowState` stays in
    /// the registry; only the AppKit window is released. The on-disk
    /// YAML is left alone so a `Window → Reopen` can resurrect it
    /// (§5.2).
    public func close(windowID: Int) {
        guard let state = windows[windowID] else { return }
        state.window?.close()
        state.window = nil
        if frontmostWindowID == windowID {
            // Hand the frontmost crown to the next open window if any.
            frontmostWindowID = openWindows.first(where: { $0.windowID != windowID })?.windowID
        }
    }

    /// Retire a window forever (§1.1, §5.3). Removes the registry
    /// entry, adds the ID to `retiredWindowIDs`, and moves the YAML
    /// files to `~/Library/Application Support/ImageGlass_Mac/
    /// Trash/window_<N>/`. The number is **not** reused (§1.2).
    public func retire(windowID: Int) throws {
        precondition(windows[windowID] != nil || retiredWindowIDs.contains(windowID),
            "retire(windowID: \(windowID)) — unknown window")
        if let state = windows[windowID] {
            state.window?.close()
            state.window = nil
        }
        try moveToTrash(windowID: windowID)
        windows.removeValue(forKey: windowID)
        retiredWindowIDs.insert(windowID)
        if frontmostWindowID == windowID {
            frontmostWindowID = openWindows.first?.windowID
        }
    }

    private func moveToTrash(windowID: Int) throws {
        try AppPaths.ensureMacTrashDir(windowID: windowID)
        let trashDir = AppPaths.macTrashDir(windowID: windowID)
        let fm = FileManager.default
        let sources: [URL] = [
            AppPaths.macSettingsWindowFile(id: windowID),
            AppPaths.macDirectoriesWindowFile(id: windowID),
        ]
        for src in sources where fm.fileExists(atPath: src.path) {
            let dst = trashDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.moveItem(at: src, to: dst)
        }
    }

    // MARK: - Reset (test hook)

    /// Tear down the registry. Tests in Group A use this between
    /// scenarios; production code never calls it.
    public func resetForTesting() {
        for state in windows.values {
            state.window?.close()
            state.window = nil
        }
        windows.removeAll()
        retiredWindowIDs.removeAll()
        frontmostWindowID = nil
        nextWindowID = 1
    }
}
