import AppKit
import Foundation
import ImageGlassCore

/// Launch-time bootstrap for the multi-window registry
/// (multi_window.mdx §1.4, §4.3). Runs the v1 → v2 migration, scans
/// `~/Library/Application Support/ImageGlass_Mac/` for existing
/// `settings_window_*.yaml` files, and registers a `WindowState` for
/// each one. Closed windows are kept in the registry in a closed
/// state so the Window menu's "Reopen Closed Window ▸" submenu can
/// surface them (§5.2).
///
/// In Group B this bootstrap is called once from
/// `AppState.bootstrap()` (or equivalent) before any MCP tool can
/// fire. It is **idempotent** — calling twice in one process is a
/// no-op past the first call.
@MainActor
public enum WindowRegistryBootstrap {

    private static var hasRun = false

    /// Result of the launch-time bootstrap. Surfaces what happened so
    /// the caller can journal the matching `log.log` line
    /// (multi_window.mdx §13.1).
    public struct Result: Sendable {
        public let migration: WindowMigration.Result
        public let loadedWindowIDs: [Int]
        public let frontmostWindowID: Int?
    }

    /// Idempotent launch entry point. Safe to call from any GUI surface
    /// that needs the registry populated.
    @discardableResult
    public static func runIfNeeded() throws -> Result {
        if hasRun {
            return Result(
                migration: WindowMigration.Result(
                    didMigrate: false,
                    v1DirectoriesFound: false,
                    v1SettingsFound: false,
                    bootstrappedWindowIDs: []
                ),
                loadedWindowIDs: WindowRegistry.shared.windows.keys.sorted(),
                frontmostWindowID: WindowRegistry.shared.frontmostWindowID
            )
        }
        hasRun = true

        // 1. Run the v1 → v2 migration (no-op if the layout is already v2).
        let migration = try WindowMigration.migrateIfNeeded()

        // 2. Enumerate every `settings_window_*.yaml` and load its
        //    matching `directories_window_*.yaml`.
        var ids = Array(WindowMigration.enumerateExistingWindowIDs()).sorted()

        // 3. If neither the migration nor the disk enumeration produced
        //    any windows, this is a brand-new install. Bootstrap
        //    window 1 with defaults (multi_window.mdx §1.4).
        if ids.isEmpty {
            try bootstrapFreshWindow1()
            ids = [1]
        }

        // 4. Load each window's YAML into a `WindowState` and register
        //    it.
        var loaded: [Int] = []
        for id in ids {
            do {
                let state = try loadWindowState(id: id)
                WindowRegistry.shared.register(state)
                loaded.append(id)
            } catch {
                NSLog("[WindowRegistryBootstrap] failed to load window_id=\(id): \(error)")
            }
        }

        // 5. Reseed `nextWindowID` from observed IDs.
        WindowRegistry.shared.reseedNextWindowID(observed: loaded)

        // 6. Install the frontmost-tracking observer.
        WindowRegistryFrontmostObserver.shared.install()

        // 7. Install the cross-target resolvers so MCP tools in
        //    `ImageGlassCore` route through the GUI's registry
        //    (multi_window.mdx §6). The closures capture
        //    `WindowRegistry.shared`, which lives on the main actor —
        //    every MCP tool dispatch happens on the main actor in
        //    this codebase, so the @Sendable conformance is safe.
        installCoreResolvers()

        return Result(
            migration: migration,
            loadedWindowIDs: loaded,
            frontmostWindowID: WindowRegistry.shared.frontmostWindowID
        )
    }

    // MARK: - Resolver wiring

    /// Install the closures `ImageGlassCore` calls into to resolve the
    /// current MCP target. Idempotent: re-installing is a no-op when
    /// the resolvers are already set.
    private static func installCoreResolvers() {
        if DirectoriesStore.frontmostResolver == nil {
            DirectoriesStore.frontmostResolver = {
                MainActor.assumeIsolated {
                    WindowRegistry.shared.frontmost?.directoriesStore
                }
            }
        }
        if MCPWindowTarget.windowIDResolver == nil {
            MCPWindowTarget.windowIDResolver = {
                MainActor.assumeIsolated {
                    WindowRegistry.shared.frontmostWindowID
                }
            }
        }
        if MCPWindowTarget.bringFrontmostForward == nil {
            MCPWindowTarget.bringFrontmostForward = {
                MainActor.assumeIsolated {
                    if let win = WindowRegistry.shared.frontmost?.window {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func bootstrapFreshWindow1() throws {
        // Write empty per-window settings and directories files for
        // window 1 so the first-launch flow lands on a consistent
        // on-disk state (§1.4).
        let settings = WindowScopedSettings(windowID: 1)
        let settingsYAML = WindowScopedSettingsYAML.encode(settings)
        let settingsURL = AppPaths.macSettingsWindowFile(id: 1)
        try writeAtomically(settingsYAML.data(using: .utf8) ?? Data(), to: settingsURL)

        let directories = DirectoriesFile()
        let dirYAML = DirectoriesYAML.encode(directories)
        let dirURL = AppPaths.macDirectoriesWindowFile(id: 1)
        try writeAtomically(dirYAML.data(using: .utf8) ?? Data(), to: dirURL)
    }

    private static func loadWindowState(id: Int) throws -> WindowState {
        let settingsStore = WindowScopedSettingsStore(windowID: id)
        let settings: WindowScopedSettings
        do {
            settings = try settingsStore.load()
        } catch {
            // Surface the parse failure (§14.2) but still register a
            // default WindowState so the rest of the launch can
            // proceed. A broken YAML file gets a `.invalid.bak`
            // sibling and a fresh default in its place.
            try renameInvalidSettings(id: id)
            settings = WindowScopedSettings(windowID: id)
            try? settingsStore.save(settings)
        }
        let directoriesStore = DirectoriesStore(windowID: id)
        return WindowState(
            windowID: id,
            settings: settings,
            settingsStore: settingsStore,
            directoriesStore: directoriesStore
        )
    }

    private static func renameInvalidSettings(id: Int) throws {
        let fm = FileManager.default
        let src = AppPaths.macSettingsWindowFile(id: id)
        guard fm.fileExists(atPath: src.path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let bak = src.appendingPathExtension("invalid-\(ts).bak")
        try fm.moveItem(at: src, to: bak)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }
}

/// `NSWindow.didBecomeKeyNotification` observer (multi_window.mdx
/// §6). Updates `WindowRegistry.shared.frontmostWindowID` whenever an
/// AppKit window that corresponds to a registered `WindowState`
/// becomes key.
///
/// In Group B the matching is heuristic: the first AppKit window to
/// become key after launch is associated with the lowest-numbered
/// open `WindowState`. Group D will replace this with explicit
/// `WindowState → NSWindow` bindings created when `New Image Window`
/// allocates a new window.
@MainActor
final class WindowRegistryFrontmostObserver {

    static let shared = WindowRegistryFrontmostObserver()

    private var observer: NSObjectProtocol?
    private var hasAssignedDefaultWindow = false

    private init() {}

    func install() {
        if observer != nil { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      window.styleMask.contains(.titled),
                      window.canBecomeMain
                else { return }
                self.handleBecomeKey(window)
            }
        }
    }

    private func handleBecomeKey(_ window: NSWindow) {
        let registry = WindowRegistry.shared

        // Heuristic for Group B: bind the first key window to the
        // lowest-numbered open `WindowState` if it has no AppKit
        // window yet. This is good enough while the live app is
        // still single-window (no ⌘N path exists yet — that lands
        // in Group D).
        if !hasAssignedDefaultWindow,
           let candidate = registry.openWindows
            .first(where: { $0.window == nil })
            ?? registry.windows.values.sorted(by: { $0.windowID < $1.windowID }).first
        {
            candidate.window = window
            hasAssignedDefaultWindow = true
            registry.setFrontmost(windowID: candidate.windowID)
            return
        }

        // Subsequent key changes: find the `WindowState` whose
        // `window === window`. If none, this is some auxiliary
        // window (Settings, About, the slideshow overlay) — leave
        // the frontmost as-is.
        for (id, state) in registry.windows where state.window === window {
            registry.setFrontmost(windowID: id)
            return
        }
    }
}
