import Foundation
import Observation
@preconcurrency import AppKit
import ImageGlassCore

/// Root reactive model. Holds the active scope, its resolved file list,
/// the current selection, and panel-visibility state.
@MainActor
@Observable
public final class AppState {
    public var availableScopes: [String] = []
    public var activeScopeName: String = ""
    public var activeScope: Scope? = nil
    public var resolvedFiles: [String] = []
    /// UserDefaults key for the most recently previewed file. Restored
    /// on cold launch in `bootstrap()` so both the main and second
    /// viewer windows come up showing the user's last image. Written
    /// from `selectedFile.didSet` on every selection change after the
    /// restore-from-launch phase completes.
    private static let lastSelectedFileKey = "ig.last_selected_file"

    /// True while `bootstrap()` is still seeding the initial selection
    /// (either from `resolvedFiles.first` in `activate()` or from the
    /// persisted `lastSelectedFileKey`). Suppresses the persistence
    /// write in `didSet` so we don't clobber the saved value with the
    /// transient scope-first assignment before we get to restore it.
    private var isRestoringSelection = true

    public var selectedFile: String? = nil {
        didSet {
            // mcp_file.mdx §2.3 — every selection change (whether the
            // user clicked a row, hit ←/→, dropped a file, or an MCP
            // tool wrote selection.txt) emits a single
            // `notifications/imageglass/selection_changed` push event
            // so connected MCP clients see the move.
            guard oldValue != selectedFile else { return }
            // Persist the latest non-nil selection so the next cold
            // launch can restore it (and both viewer windows come up
            // showing the user's last image). Skipped during bootstrap
            // restoration so the seed value from `activate()` does not
            // overwrite the saved value before we read it.
            if !isRestoringSelection, let path = selectedFile {
                UserDefaults.standard.set(path, forKey: Self.lastSelectedFileKey)
            }
            // Defensive: any path that lands here must be a full
            // absolute path (or `~/` prefixed — we expand at the
            // canvas). A bare filename like "img_6.gif" cannot resolve
            // to a real file unless the process cwd happens to be its
            // parent. We log but do NOT roll back: the canvas runs the
            // same validation and refuses to load, and a downstream
            // consumer correcting the path is preferable to a silent
            // hop back to oldValue that would mask the source of the
            // bad selection. This is the "cyan-but-no-image"
            // diagnostic the user asked for.
            if let path = selectedFile {
                let result = ImageCanvasView.validate(path: AppPaths.expandTilde(path))
                if result != .ok {
                    ErrorLog.log("AppState.selectedFile invalid path (\(result)) — canvas will refuse to load: '\(path)'",
                                 class: String(describing: Self.self))
                }
            }
            // mcp_file.mdx §10.1 trigger condition #1 / §10.7 negative
            // case: the walker only auto-selects when the viewer is
            // empty. Mirror selectedFile into the walker so a manual
            // selection (or any incoming MCP `select_file`) suppresses
            // a future first-image-found auto-advance.
            DirectoryTreeWalker.shared.viewerIsEmpty = (selectedFile == nil)
            // Mirror the new file selection into the tree-nav cursor so
            // arrow keys resume from the visible row, and open every
            // ancestor folder so the row is actually rendered (the user
            // just clicked it, or MCP `select_file` landed it).
            // hotkeys.mdx §4.
            if let path = selectedFile {
                treeNav.activeRow = path
                treeNav.revealAncestors(of: path)
            }
            if let path = selectedFile {
                MCPNotificationBus.shared.emitSelectionChanged(path: path)
            }
            // multi_window.mdx §8 — mirror the new selection into the
            // bound window's per-window state so persistence on quit
            // writes the correct `session.selection.current_file`. Skip
            // during bootstrap restoration so we don't clobber a
            // freshly-loaded YAML before the bind happens.
            if !isRestoringSelection, let window = boundWindow {
                window.selectedFile = selectedFile
            }
        }
    }
    /// menus.mdx §4.2 / slideshow.mdx §0A / local_storage.mdx §"Last
    /// Viewed Image" — the image **currently being viewed** on the main
    /// canvas, as an absolute POSIX (or `~/`-prefixed) path, or `nil`
    /// when the viewer is empty. This is the single global cursor: it is
    /// the same value the directory panel highlights, the slideshow reads
    /// on every tick, and the "Copy Current Image Path" menu item copies.
    /// It is a thin alias over `selectedFile` so every surface that cycles
    /// images (arrow keys, `N`/`P`, panel clicks, slideshow advance, MCP
    /// `select_file`) keeps `currentImage` up to date automatically, and
    /// so the last value is persisted to the per-window config YAML for
    /// restore-on-relaunch (see `WindowState.persistSelection`).
    public var currentImage: String? {
        get { selectedFile }
        set { selectedFile = newValue }
    }

    public var lastEvaluated: Date? = nil

    /// Visibility of the left file panel column. Computed off
    /// `panelLayout` so the title-bar `sidebar.left` toolbar button
    /// (docs/panels.mdx §5.6.1), the View menu's Show/Hide Panel Column
    /// item, the ⌘L keybinding, and §10.5's walker hook all read and
    /// write the *same* truth — the on-disk layout. Eliminates the
    /// drift bug where a stored boolean disagreed with the layout
    /// after a relaunch. Mutations route through `hideByUser` /
    /// `showByUser` so an explicit close also persists to
    /// `settings.layout.show_file_panel`.
    public var showPanelColumn: Bool {
        get { panelLayout.layout.isVisible(BuiltInPanelCatalog.filePanel.id) }
        set {
            if newValue {
                showByUser(panelID: BuiltInPanelCatalog.filePanel.id, asPrimary: true)
            } else {
                hideByUser(panelID: BuiltInPanelCatalog.filePanel.id)
            }
        }
    }
    public var panelViewMode: PanelViewMode = .tree

    /// menus.mdx View ▸ Left File Tree ▸ "Only Show Included Items".
    /// When on, the file-tree panel hides every row whose resolved
    /// include state (`RootDirectory.effectiveState`) is `.exclude`,
    /// leaving only the green-checked / inherit-include rows whose chain
    /// above them is all-include (include_checks.mdx §6). Off by default
    /// for every customer. Persisted per-window in
    /// `directories_window_<N>.yaml` (`only_show_included_items`) and
    /// mirrored here so the panel re-renders the instant it changes.
    /// Mutate through `setOnlyShowIncludedItems(_:)`, never by assigning
    /// this property directly, so the on-disk YAML stays in sync.
    public var onlyShowIncludedItems: Bool = false

    /// Live snapshot of `DirectoryTreeWalker.shared.snapshot()`. Refreshed
    /// from `DirectoryTreeWalker.didChangeNotification` (walk completed,
    /// refilter ran, root removed) and is the source of truth the file
    /// tree panel (Stage E) binds to. Empty until the walker starts
    /// emitting; populated for every root in `directories.yaml`.
    public var walkerRoots: [RootDirectory] = []

    /// Cached count of root entries in `directories.yaml`. Set by bootstrap
    /// and updated by `reloadDirectoriesFromDisk` so the panel's spinner
    /// gate (`walkerRoots.isEmpty && directoriesRootCount > 0`) never reads
    /// the YAML file on the SwiftUI render hot-path.
    public var directoriesRootCount: Int = 0

    /// Layout of all modular panels (toolbar, file panel, status bar, ...).
    /// Loaded from `layout.json` at bootstrap, persisted on every mutation.
    /// See docs/panels.mdx.
    public let panelLayout = PanelLayoutModel()

    /// The frontmost window's viewer state (zoom mode, pan, rotation,
    /// overlays, ...). Lives here so menu commands and the SwiftUI
    /// viewer can share it. In the multi-window model
    /// (multi_window.mdx §2.1, §4.1) every `WindowState` owns its own
    /// `ViewerState`; this property points at the **frontmost
    /// window's** instance. `bindToFrontmostWindow(_:)` swaps the
    /// reference when the user activates a different window, which
    /// re-fires SwiftUI observation so the canvas re-renders against
    /// the new window's zoom / pan / overlay state.
    public var viewer: ViewerState = ViewerState()

    /// The `WindowState` whose `viewer` / `selectedFile` are currently
    /// mirrored into `AppState`. Set by `bindToFrontmostWindow(_:)` on
    /// every focus transition. Nil during early bootstrap before any
    /// window has registered.
    public weak var boundWindow: WindowState?

    /// Centralized tree-expansion + arrow-key cursor for the Directory
    /// Panel. See `TreeNavigator` and `docs/hotkeys.mdx` §4.
    public var treeNav: TreeNavigator = TreeNavigator()

    /// Crop tool controller (docs/crop.mdx §5.1). Lives at AppState scope
    /// so the menu commands, overlay, and panel all bind to the same
    /// instance.
    public var crop: CropController = CropController()

    /// Video preview transport controller (docs/videos.mdx §3). Owns the
    /// AVPlayer + AVPlayerLooper for the active viewer window so the
    /// Video menu, the canvas, and the MCP surface all bind to the same
    /// observable.
    public var video: VideoPlaybackController = VideoPlaybackController()

    /// SVG preview controller (docs/svg.mdx §3). Holds the
    /// WKWebView-backed transport bridge + per-file SVG state.
    public var svg: SVGPlaybackController = SVGPlaybackController()

    /// Merged, effective configuration produced by `ConfigLoader`. Loaded
    /// during `bootstrap()` from the three igconfig.* tiers + CLI overrides.
    public var config: Config = .builtIn

    /// Paths used to load `config`. Useful for diagnostics and for the
    /// Settings UI ("where is my config file?").
    public var configPaths: ConfigPaths = ConfigPaths.resolve()

    /// Canonical spec-§2.3 `settings.json` model. Loaded from
    /// `~/Library/Application Support/ImageGlass/settings.json` during
    /// `bootstrap()`; written back atomically via `saveSettings()`.
    public var settings: Settings = .defaults

    /// Backing store for `settings`. Owned by `AppState` so it lives as
    /// long as the running app.
    public let settingsStore: SettingsStore = SettingsStore()

    /// Theme catalog + current selection (see docs/themes.mdx).
    public let themeStore = ThemeStore()

    /// Setting overrides captured from `/Name=Value` flags at launch. The
    /// configs subsystem layers these on top of the loaded `igconfig.json`.
    public var cliOverrides: [String: String] = [:]

    /// Positional file/directory paths supplied on the command line.
    public var cliOpenPaths: [String] = []

    /// True if `--startup-boost` was on the command line.
    public var cliStartupBoost: Bool = false

    public enum PanelViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        public var label: String { self == .list ? "List" : "Tree" }
    }

    /// docs/list_of_files.mdx §3D — user-selectable tree rendering
    /// technology. The walker / data layer is unchanged; only the
    /// SwiftUI view that hosts the tree differs. Persisted to
    /// `UserDefaults` under `ig.tree_render_tech`. Default is
    /// `.swiftUI` per §3D.3.
    public var treeRenderTechnology: TreeRenderTechnology = TreeRenderTechnology.loadOrDefault() {
        didSet {
            guard oldValue != treeRenderTechnology else { return }
            treeRenderTechnology.save()
        }
    }

    /// Crop subsystem controller. Owned by AppState so the SwiftUI panel
    /// and the overlay can share one observable instance. See `Crop/`.
    public let cropController: CropController = CropController()

    private let storage = LocalStorage.shared
    private var fileWatcher: FileWatcher?
    /// Long-lived subscription to `FileSystemWatcher.shared.events(for:)`.
    /// Replaces the legacy fan-out of one `FileWatcher` per include-rule
    /// directory: spec docs/file_system_change.mdx §3.1 / §3.3 says a
    /// single FSEventStream per scope is correct and cheap, while N
    /// kqueue file descriptors over a tree is the wrong primitive
    /// (Apple "do not use kqueue for large hierarchies"). Cancelled and
    /// re-armed by `rebuildSourceWatchers()` on every scope change.
    private var scopeFSTask: Task<Void, Never>?
    /// Name of the scope the active subscription belongs to. Tracked so
    /// `rebuildSourceWatchers` can decide whether to keep the existing
    /// subscription (same scope, same roots) or replace it.
    private var scopeFSScopeName: String?
    /// Roots the active subscription covers. Same purpose as
    /// `scopeFSScopeName` — short-circuits a no-op rebuild.
    private var scopeFSRoots: [URL] = []
    /// Legacy field — retained for binary compatibility with any
    /// callers that read this property; the new FileSystemWatcher
    /// subscription replaces its function. Always empty in v2+.
    private var sourceWatchers: [FileWatcher] = []
    /// Watches `~/Library/Application Support/ImageGlass_Mac/selection.txt`
    /// so MCP `select_file` calls move the GUI selection without us having
    /// to invent a wire-level push channel (mcp_file.mdx §2.3).
    private var selectionWatcher: FileWatcher?
    /// Watches `~/Library/Application Support/ImageGlass_Mac/panel_view_mode.txt`
    /// so MCP `panel.set_view_mode` switches the file panel between list
    /// and tree views without a wire-level push (mcp_file.mdx §3).
    private var viewModeWatcher: FileWatcher?
    /// Watches `~/Library/Application Support/ImageGlass_Mac/slideshow.txt`
    /// so MCP `set_slideshow` calls drive `SlideshowController` without a
    /// direct cross-module call (slideshow.mdx §12).
    private var slideshowWatcher: FileWatcher?
    /// `corr=` value of the last applied slideshow.txt — used to dedupe
    /// re-fires when the FileWatcher coalesces events.
    private var lastSlideshowCorr: String = ""
    /// Watches `~/Library/Application Support/ImageGlass_Mac/` (the parent
    /// directory) so that when the MCP server process writes `directories.yaml`
    /// the GUI app notices and schedules walks for any newly-added roots.
    /// We watch the directory rather than the file itself because the atomic
    /// write (temp-file + rename) replaces the inode, which would break a
    /// kqueue watcher on the file's old file descriptor.
    private var directoriesFileWatcher: FileWatcher?
    /// Last successfully reconciled `directories.yaml` snapshot. The
    /// kqueue watcher on the app-support directory fires on every write
    /// to that directory — including the walker's own audit-log writes,
    /// which can happen thousands of times per second during a deep
    /// walk. Without this guard, each FSEvent triggers a full reload +
    /// a spurious `scheduleWalk` for every root whose previous walk
    /// hasn't yet committed to `walker.roots`, stacking dozens of
    /// concurrent walks of the same cloud-backed directory.
    private var lastReconciledDirectoriesFile: DirectoriesFile?
    /// Token for the `NSDistributedNotificationCenter` subscription that gives
    /// the MCP server an immediate push channel into this process. Complements
    /// the kqueue watcher — whichever fires first wins; the other is a no-op
    /// because `reloadDirectoriesFromDisk()` is idempotent.
    private var directoriesChangedToken: NSObjectProtocol?
    /// Repeating timer that refreshes `heartbeat.txt` every 30 s so the MCP
    /// server can determine whether this process is alive via `kill(pid, 0)`.
    private var heartbeatTimer: Timer?
    /// Set to `true` while a scope walk is in flight on a background task
    /// (mcp_file.mdx §10.5 — the toolbar's refresh icon spins while this is true).
    public var isWalking: Bool = false
    /// Cancellable handle to the in-flight scope walk. A second
    /// `reevaluateActive()` arriving before the first finishes cancels the
    /// first so only the latest scope state ever lands in the GUI
    /// (mcp_file.mdx §10.3).
    private var walkTask: Task<Void, Never>?

    public init() {}

    deinit {
        // Swift 6.x toolchains (observed: Swift 6.3.2 / Xcode 26 on macOS 26)
        // make `deinit` of an @MainActor class implicitly nonisolated, so
        // touching MainActor-isolated stored properties directly is a hard
        // error. Older toolchains let this compile. Wrap in
        // `MainActor.assumeIsolated` — the same pattern used throughout
        // this codebase — so the cleanup compiles on both. Safe in
        // practice: @Observable @MainActor instances are only released
        // from the main thread (SwiftUI ownership, test teardown on
        // MainActor), which is what `assumeIsolated` requires at runtime.
        MainActor.assumeIsolated {
            heartbeatTimer?.invalidate()
            if let t = directoriesChangedToken {
                DistributedNotificationCenter.default().removeObserver(t)
            }
            if let t = firstImageFoundToken {
                NotificationCenter.default.removeObserver(t)
            }
            if let t = directoryDidChangeToken {
                NotificationCenter.default.removeObserver(t)
            }
        }
    }

    /// Apply parsed launch arguments. Safe to call from the app entry point
    /// before `bootstrap()` runs.
    public func applyLaunchArguments(_ args: ImageGlassLaunchArguments) {
        self.cliOverrides = args.overrides
        self.cliOpenPaths = args.openPaths
        self.cliStartupBoost = args.startupBoost
    }

    // MARK: - Bootstrap

    public func bootstrap() async {
        do {
            try AppPaths.ensureDirectories()
            try AppPaths.ensureLayoutDirectories()
            try AppPaths.ensureMacDirectories()
            // multi_window.mdx §1.4 / §3.5 / §4.3 — run the v1 → v2 Local
            // Storage migration and populate `WindowRegistry.shared` with
            // every `settings_window_<N>.yaml` on disk before any
            // `DirectoriesStore` read. This is idempotent on subsequent
            // launches.
            do {
                _ = try WindowRegistryBootstrap.runIfNeeded()
            } catch {
                ErrorLog.log("WindowRegistryBootstrap.runIfNeeded failed",
                             error: error, class: String(describing: Self.self))
            }
            // multi_window.mdx §2.1 / §4.1 — install the frontmost-
            // window mirror hook so window-switches (⌘\`, Window menu,
            // click) swap AppState.viewer / AppState.selectedFile to
            // the new window's instances. Done here (after the
            // registry bootstrap) so the first becomeKey landing in
            // `WindowRegistryFrontmostObserver` already has the hook
            // available.
            WindowRegistry.shared.onFrontmostChanged = { [weak self] window in
                self?.bindToFrontmostWindow(window)
            }
            // Bind eagerly to the lowest-numbered registered window
            // (window 1 in the single-window case) so AppState's
            // viewer / selectedFile are pointing at a real
            // `WindowState` instance before bootstrap restores the
            // last-selected file. Without this, the bootstrap-time
            // assignment to `selectedFile` would not yet mirror into
            // any window's per-window storage.
            if let firstWindow = WindowRegistry.shared.windows.values
                .sorted(by: { $0.windowID < $1.windowID })
                .first
            {
                bindToFrontmostWindow(firstWindow)
            }
            // perf/plans/AppLaunch.Total.plan §B — the config disk reads
            // (ConfigLoader is not actor-isolated, so we can run it on a
            // detached background task) and the settings store
            // (SettingsStore is an actor; loadOrDefault runs off the main
            // actor anyway) are independent of each other. Run them in
            // parallel and only `await` at the join point. On a warm
            // cache the savings are small; on a cold cache (first launch,
            // slow disk) this hides ~5–15 ms of duplicated JSON decode
            // latency from the launch hot path.
            let cliArgs = Array(CommandLine.arguments.dropFirst())
            let configHandle = Task.detached(priority: .userInitiated) {
                () -> (ConfigPaths, Config) in
                let paths = ConfigPaths.resolve()
                let cli = CLIOverrides.parse(cliArgs)
                let loader = ConfigLoader(paths: paths)
                do {
                    let resolution = try loader.resolveAndPersist(cli: cli)
                    return (paths, resolution.config)
                } catch {
                    ErrorLog.log("config load failed; using built-in defaults",
                                 error: error, class: String(describing: AppState.self))
                    NSLog("ImageGlass config load failed: \(error) — using built-in defaults")
                    return (paths, .builtIn)
                }
            }
            async let settingsTask: Settings = settingsStore.loadOrDefault()
            let (loadedPaths, loadedConfig) = await configHandle.value
            self.configPaths = loadedPaths
            self.config = loadedConfig
            self.settings = await settingsTask
            // perf/plans/AppLaunch.Total.plan §B / §C — `themeStore.bootstrap()`
            // does a `contentsOfDirectory` scan of the themes folder plus
            // three plain-text reads. The `currentTheme` / `appearanceMode`
            // bindings ContentView reads are @Observable, so painting the
            // first frame with built-in defaults and re-rendering after the
            // store loads costs at most a single re-layout — far cheaper
            // than blocking first paint on the scan. Deferred to the
            // post-bootstrap Task below.
            PanelRegistry.shared.registerBuiltInPanels()
            panelLayout.reloadFromDisk()
            // docs/panels.mdx §6.5 — bootstrap reconciliation. The
            // user-facing contract (CLAUDE.md, dir_ui.mdx §2) is that
            // `settings.layout.show_*` is the single source of truth
            // for which panels are open: the file panel defaults to
            // ON, and only an explicit user-close persists as `false`.
            // The reconciliation below replays those flags against the
            // freshly-loaded `layout.json` so a layout that has drifted
            // (file_panel landed in `hidden`, scope_editor stuck on the
            // left, etc.) is silently corrected. `file_panel` is
            // restored *as the primary tab* so it lands as the
            // prominent left-dock surface instead of behind whatever
            // else happens to share the left column.
            reconcilePanelsWithSettings()
            panelLayout.startWatching()
            // docs/performance.mdx §5.4 / §7.8 — wrap the directory-load
            // kickoff so the analyzer can see the cost of restoring the
            // user's persisted roots and scheduling their walks. Scope
            // evaluation itself is instrumented separately (see
            // ScopeEvaluator) — do not double-instrument here.
            let _loadDirsTrace = PerformanceLog.shared.start("AppLaunch.LoadDirectories")
            let bootstrapped = try storage.bootstrapIfNeeded()
            // mcp_file.mdx §1.3 — first launch leaves an empty
            // `directories.yaml` so the panel has a defined state.
            var directoryCount = 0
            var storedRoots: [RootDirectory] = []
            do {
                let file = try DirectoriesStore.shared.ensureExists()
                directoryCount = file.roots.count
                storedRoots = file.roots
                self.directoriesRootCount = directoryCount
            } catch {
                ErrorLog.log("DirectoriesStore.ensureExists failed",
                             error: error, class: String(describing: Self.self))
            }
            MCPAuditLogger.shared.logStartup(layout: "Browser", directoryCount: directoryCount)
            await refreshScopeList()
            await activate(scopeNamed: bootstrapped)
            // perf/plans/AppLaunch.Total.plan §C — none of the watchers,
            // the heartbeat timer, the directory-tree walker observer, or
            // the boot-time scheduleWalk loop need to complete before the
            // first viewer paint. They all open kqueue file descriptors,
            // post audit lines, and allocate correlation ids — costs
            // that add up on the launch hot path. Defer to a main-actor
            // Task so they land after FirstFrame.
            let deferredRoots = storedRoots
            Task { @MainActor [weak self] in
                guard let self else { return }
                // perf/plans/AppLaunch.Total.plan §C — themeStore.bootstrap
                // scans `themes/` and reads three plain-text selection
                // files. ContentView's `.tint` / `.preferredColorScheme`
                // bindings re-render automatically when the store
                // republishes, so painting first frame with the
                // BuiltinThemes defaults and updating afterwards is
                // visually fine.
                self.themeStore.bootstrap()
                self.startWatching()
                self.startSelectionWatcher()
                self.startViewModeWatcher()
                self.startSlideshowWatcher()
                self.startDirectoryTreeWalkerObserver()
                self.startDirectoriesFileWatcher()
                self.writeHeartbeat()
                self.startHeartbeatTimer()
                // mcp_file.mdx §3A.5: the walker is "running even when the
                // component is turned off" — so every root in
                // directories.yaml is scheduled at boot. A relaunch with
                // pre-existing roots repopulates the in-memory tree without
                // the user re-adding anything.
                for root in deferredRoots {
                    let corr = MCPAuditLogger.newCorrelationId()
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: root.path, filter: root.filter, corr: corr
                    )
                }
            }
            _loadDirsTrace.finish(extra: [
                ("roots", String(storedRoots.count)),
                ("scope", bootstrapped),
            ])
            // Restore the last image the user previewed (saved on
            // every selection via `lastSelectedFileKey`). Runs after
            // `activate()` so it can override the scope's first-file
            // seed when the saved path is still readable on disk.
            // Both viewer windows observe `selectedFile`, so this one
            // assignment makes the main viewer and the floating
            // second viewer load the same image at launch.
            restoreLastSelectedFileIfAvailable()
            isRestoringSelection = false
        } catch {
            ErrorLog.log("bootstrap failed", error: error, class: String(describing: Self.self))
            NSLog("ImageGlass bootstrap failed: \(error)")
            isRestoringSelection = false
        }
    }

    /// Bind `AppState` to a specific `WindowState` so that
    /// `state.viewer` and `state.selectedFile` mirror that window's
    /// per-window storage (multi_window.mdx §2.1, §4.1). Called when
    /// the user activates a different window via ⌘\` / Window menu /
    /// click. Two-way sync:
    ///
    /// * Before swapping, snapshot the **outgoing** window's
    ///   `selectedFile` from `AppState.selectedFile` (the live SwiftUI
    ///   binding may have moved since the last switch).
    /// * After swapping, copy the incoming window's `selectedFile`
    ///   into `AppState.selectedFile` so the canvas re-renders against
    ///   the right image.
    ///
    /// The `viewer` instance is replaced wholesale; SwiftUI's
    /// observation tracker re-runs every `state.viewer.*` binding
    /// because the published value changed.
    public func bindToFrontmostWindow(_ newWindow: WindowState) {
        // 1. Snapshot the outgoing window's selection back into its
        //    own `WindowState` before we overwrite AppState's mirror.
        if let outgoing = boundWindow, outgoing !== newWindow {
            outgoing.selectedFile = selectedFile
        }
        boundWindow = newWindow

        // 2. Swap in the new window's viewer instance. The bindings
        //    that observe `state.viewer.*` re-fire automatically
        //    because the stored property changed.
        if viewer !== newWindow.viewer {
            viewer = newWindow.viewer
        }

        // 3. Mirror the new window's selection into the AppState
        //    binding so the canvas / panel re-render against it. The
        //    `didSet` on `selectedFile` does its own bookkeeping; the
        //    `isRestoringSelection` flag suppresses the UserDefaults
        //    write during this swap so window-switch does not clobber
        //    the global last-image marker.
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        selectedFile = newWindow.selectedFile
        isRestoringSelection = wasRestoring

        // 4. Hydrate the file-panel expand/collapse state from the new
        //    window's persisted YAML, then install the persist-on-change
        //    callback so subsequent mouse / keyboard toggles flush back
        //    to `settings_window_<N>.yaml#session.directory_panel`.
        //    Clear the callback first so `loadExpansionMap` (which
        //    rewrites the sets) cannot trigger a save against the
        //    *outgoing* window via a stale closure.
        treeNav.onPersistRequested = nil
        treeNav.loadExpansionMap(
            newWindow.settings.session.directoryPanel.expandedPaths
        )
        treeNav.onPersistRequested = { [weak self, weak newWindow] in
            guard let self, let win = newWindow else { return }
            let snapshot = self.treeNav.expansionMap
            do {
                try win.persistDirectoryPanelExpansion(snapshot)
            } catch {
                ErrorLog.log("persistDirectoryPanelExpansion failed",
                             error: error, class: String(describing: Self.self))
            }
        }
    }

    /// Read the persisted last-previewed file from UserDefaults and,
    /// if it still points at a readable image on disk, assign it to
    /// `selectedFile`. A missing/invalid value is left alone so the
    /// `activate()` seed (first file in the active scope) remains in
    /// place — the user just sees the scope's default image instead.
    private func restoreLastSelectedFileIfAvailable() {
        guard let saved = UserDefaults.standard.string(forKey: Self.lastSelectedFileKey),
              !saved.isEmpty else {
            return
        }
        let expanded = AppPaths.expandTilde(saved)
        let result = ImageCanvasView.validate(path: expanded)
        guard result == .ok else {
            ErrorLog.log(
                "restoreLastSelectedFile: skipping '\(saved)' (\(result))",
                class: String(describing: Self.self)
            )
            return
        }
        // Ensure prev/next navigation works even if the restored file
        // isn't in the active scope (e.g. it was opened via drag-drop
        // last session and the scope is now different).
        if !resolvedFiles.contains(saved) {
            resolvedFiles.insert(saved, at: 0)
        }
        selectedFile = saved
    }

    /// Loads `settings.json` via the actor-backed `SettingsStore`. Any
    /// failure (missing file, malformed JSON) leaves `settings` at its
    /// default value so the app remains usable.
    public func loadSettings() async {
        let loaded = await settingsStore.loadOrDefault()
        self.settings = loaded
    }

    /// Persists the current `settings` to disk atomically.
    public func saveSettings() async {
        do {
            try await settingsStore.save(settings)
        } catch {
            ErrorLog.log("settings save failed", error: error, class: String(describing: Self.self))
            NSLog("ImageGlass settings save failed: \(error)")
        }
    }

    /// Loads the layered igconfig.* configuration and persists the merged
    /// result back to `igconfig.json`. CLI overrides are parsed from the
    /// process arguments. Failures fall back to `Config.builtIn` so the
    /// app remains usable even with a corrupt config file.
    public func loadConfig() async {
        let paths = ConfigPaths.resolve()
        let cli = CLIOverrides.parse(Array(CommandLine.arguments.dropFirst()))
        let loader = ConfigLoader(paths: paths)
        do {
            let resolution = try loader.resolveAndPersist(cli: cli)
            self.configPaths = paths
            self.config = resolution.config
        } catch {
            ErrorLog.log("config load failed; using built-in defaults",
                         error: error, class: String(describing: Self.self))
            NSLog("ImageGlass config load failed: \(error) — using built-in defaults")
            self.configPaths = paths
            self.config = .builtIn
        }
    }

    public func refreshScopeList() async {
        do {
            availableScopes = try storage.listScopes()
        } catch {
            ErrorLog.log("storage.listScopes failed",
                         error: error, class: String(describing: Self.self))
            availableScopes = []
        }
    }

    public func activate(scopeNamed name: String) async {
        let scope: Scope
        do {
            scope = try storage.loadScope(name)
        } catch LocalStorage.Error.notFound {
            // "Not found" is normal (scope deleted, never written, or a
            // stale last-active name from a prior schema). Log at INFO
            // via NSLog (not ErrorLog) and fall back to the bootstrap
            // scope so the app stays usable. The schema-mismatch ERROR
            // path below stays intact.
            NSLog("ImageGlass scope '\(name)' not found; falling back to bootstrap scope")
            let fallbackName: String
            do {
                fallbackName = try storage.bootstrapIfNeeded()
            } catch {
                ErrorLog.log("storage.bootstrapIfNeeded failed during fallback for missing scope '\(name)'",
                             error: error, class: String(describing: Self.self))
                return
            }
            if fallbackName == name {
                // bootstrapIfNeeded handed back the same broken name —
                // refuse to recurse forever.
                ErrorLog.log("scope '\(name)' missing and bootstrap returned same name; giving up",
                             class: String(describing: Self.self))
                return
            }
            await activate(scopeNamed: fallbackName)
            return
        } catch {
            ErrorLog.log("storage.loadScope failed for '\(name)'",
                         error: error, class: String(describing: Self.self))
            return
        }
        activeScopeName = name
        activeScope = scope
        // If the scope has never been evaluated, evaluate now; otherwise show stored list.
        if scope.lastEvaluated == nil || scope.resolvedFiles.isEmpty {
            await reevaluateActive()
        } else {
            resolvedFiles = scope.resolvedFiles
            lastEvaluated = scope.lastEvaluated
            selectedFile = resolvedFiles.first
            rebuildSourceWatchers()
        }
        if let f = selectedFile { cropController.bind(activeImage: nil, path: f) }
    }

    /// Re-walk the active scope on a background `Task`. If a previous
    /// walk is still in flight when this is called, that earlier task
    /// is cancelled first so only the latest scope state ever lands in
    /// the GUI (mcp_file.mdx §10.3).
    ///
    /// `isWalking` is observable and drives the spinning refresh icon
    /// in the panel toolbar (§10.5). Callers can `await` this method;
    /// it returns when the new walk has finished (or has been
    /// superseded and abandoned).
    public func reevaluateActive() async {
        guard let scopeIn = activeScope else { return }
        walkTask?.cancel()
        let scopeName = scopeIn.name
        let scopeSnapshot = scopeIn
        isWalking = true
        let walkStart = Date()
        let task = Task.detached(priority: .utility) {
            () -> (Scope, Int) in
            // Off the main actor: heavy filesystem walk happens here.
            // `Task.isCancelled` is checked after the walk so the cost
            // of a cancelled walk is bounded by `ScopeEvaluator.evaluate`.
            let evaluated = ScopeEvaluator.evaluate(scopeSnapshot)
            let elapsedMs = Int(Date().timeIntervalSince(walkStart) * 1000.0)
            return (evaluated, elapsedMs)
        }
        walkTask = Task { [weak self] in
            let (scope, elapsedMs) = await task.value
            // If a later reevaluateActive() ran while we were walking,
            // walkTask is now a different task; drop our results.
            guard let self else { return }
            guard !Task.isCancelled else {
                self.isWalking = false
                return
            }
            do {
                try self.storage.saveScope(scope)
            } catch {
                ErrorLog.log("storage.saveScope failed for '\(scope.name)'",
                             error: error, class: String(describing: Self.self))
            }
            self.activeScope = scope
            self.resolvedFiles = scope.resolvedFiles
            self.lastEvaluated = scope.lastEvaluated

            // mcp_file.mdx §10: when the viewer is empty
            // (`selectedFile == nil`) and the new resolved list contains
            // at least one image, auto-select the first one and emit
            // the `panel.auto_select_first` audit line.
            let viewerWasEmpty = (self.selectedFile == nil)
            if self.selectedFile == nil
                || !(self.resolvedFiles.contains(self.selectedFile ?? "")) {
                self.selectedFile = self.resolvedFiles.first
                if viewerWasEmpty, let first = self.resolvedFiles.first {
                    let corr = MCPAuditLogger.newCorrelationId()
                    MCPAuditLogger.shared.logAutoSelectFirst(
                        path: first,
                        corr: corr,
                        reason: "viewer_empty"
                    )
                    // Push a notifications/imageglass/auto_select_first
                    // event to any connected MCP client (§10).
                    MCPNotificationBus.shared.emitAutoSelectFirst(
                        path: first,
                        corr: corr,
                        reason: "viewer_empty"
                    )
                }
            }
            self.rebuildSourceWatchers()

            // Audit the walk itself (mcp_file.mdx §8: every walk produces
            // a matching `app=scope.evaluate` line).
            MCPAuditLogger.shared.logScopeEvaluate(
                scope: scopeName,
                count: self.resolvedFiles.count,
                elapsedMs: elapsedMs,
                corr: MCPAuditLogger.newCorrelationId()
            )
            self.isWalking = false
        }
        await walkTask?.value
    }

    /// Bind `FileSystemWatcher.shared` to the active scope so external
    /// changes (new screenshots, deletes, renames, atomic-rename saves,
    /// volume unmounts) trigger a re-evaluation. Replaces the legacy
    /// per-directory kqueue fan-out — spec docs/file_system_change.mdx
    /// §3.1 explains why one FSEventStream per scope beats N
    /// kqueue file descriptors for a tree. Called after every scope
    /// activation.
    private func rebuildSourceWatchers() {
        guard let scope = activeScope else {
            // Scope cleared — release any active subscription.
            let task = scopeFSTask
            let prevScope = scopeFSScopeName
            scopeFSTask = nil
            scopeFSScopeName = nil
            scopeFSRoots = []
            task?.cancel()
            if let prev = prevScope {
                Task { await FileSystemWatcher.shared.unwatch(scope: prev) }
            }
            return
        }

        // Resolve include-rule directories to URLs the watcher can
        // bind to. Skip non-existent paths — `ScopeEvaluator` already
        // tolerates missing roots, and FSEventsScopeWatcher itself
        // emits `.rootDisappeared` if a previously-present root goes
        // away later.
        var seen = Set<String>()
        var roots: [URL] = []
        for dir in scope.include.directories {
            let expanded = AppPaths.expandTilde(dir)
            guard seen.insert(expanded).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            roots.append(URL(fileURLWithPath: expanded))
        }

        // Idempotent: identical scope + roots → keep the existing
        // subscription, do not flap the FSEventStream.
        if scopeFSScopeName == scope.name && scopeFSRoots == roots {
            return
        }

        // Tear down the previous subscription before spawning a new one
        // so its `for await` loop exits cleanly (the AsyncStream is
        // finished by `unwatch(scope:)`).
        let previousScope = scopeFSScopeName
        scopeFSTask?.cancel()

        scopeFSScopeName = scope.name
        scopeFSRoots = roots

        let scopeName = scope.name
        scopeFSTask = Task { [weak self] in
            // Do NOT guard-let self at the top of this task: a single
            // `guard let self` here would promote the weak capture to a
            // strong local that spans the entire `for await` loop body,
            // creating a retain cycle between AppState (which owns
            // scopeFSTask) and the long-lived Task (which would then hold
            // AppState strongly for the duration of the loop).
            // Instead, the preamble (unwatch/watch/events) uses a scoped
            // `if let self` that releases the strong reference as soon as
            // those three awaits complete. The loop re-checks `self` on
            // every iteration so it is only held strongly for the duration
            // of one reevaluateActive() call, not for the entire loop.
            if let self {
                if let prev = previousScope, prev != scopeName {
                    await FileSystemWatcher.shared.unwatch(scope: prev)
                }
                await FileSystemWatcher.shared.watch(scope: scopeName, roots: roots)
            }
            let stream = await FileSystemWatcher.shared.events(for: scopeName)
            for await _ in stream {
                if Task.isCancelled { break }
                // Spec §6 stage 4 — every batch triggers a single
                // scope re-evaluation. `reevaluateActive()` already
                // serializes overlapping walks via `walkTask`.
                // Re-resolve self on every iteration: if AppState was
                // deallocated mid-stream, break cleanly instead of
                // extending its lifetime through another walk cycle.
                guard let self else { break }
                await self.reevaluateActive()
            }
        }
    }

    // MARK: - Settings-driven panel visibility (docs/panels.mdx §6.5)

    /// Replay each `settings.layout.show_*` flag against the loaded
    /// `PanelLayout` so the two stores agree. Called once during
    /// `bootstrap()` after `panelLayout.reloadFromDisk()`. The flags
    /// are authoritative: a stale layout that hides `file_panel`
    /// (because the user landed on a pre-fork `layout.json`) is
    /// silently corrected back to "visible" because the default
    /// `show_file_panel = true` carries the spec's "on by default"
    /// guarantee.
    public func reconcilePanelsWithSettings() {
        reconcile(panelID: BuiltInPanelCatalog.filePanel.id,
                  showFlag: settings.layout.show_file_panel,
                  asPrimary: true)
        reconcile(panelID: BuiltInPanelCatalog.scopeEditor.id,
                  showFlag: settings.layout.show_scope)
        reconcile(panelID: BuiltInPanelCatalog.metadata.id,
                  showFlag: settings.layout.show_metadata)
        reconcile(panelID: BuiltInPanelCatalog.mcpActivity.id,
                  showFlag: settings.layout.show_mcp)
        reconcile(panelID: BuiltInPanelCatalog.galleryStrip.id,
                  showFlag: settings.layout.show_thumb_strip)
        reconcile(panelID: BuiltInPanelCatalog.statusBar.id,
                  showFlag: settings.layout.show_status_bar)
        reconcile(panelID: BuiltInPanelCatalog.toolbar.id,
                  showFlag: settings.layout.show_toolbar)
    }

    private func reconcile(panelID id: String,
                           showFlag: Bool,
                           asPrimary: Bool = false) {
        let isVisible = panelLayout.layout.isVisible(id)
        if showFlag && !isVisible {
            if asPrimary {
                panelLayout.showPanelAsPrimary(id)
            } else {
                panelLayout.showPanel(id)
            }
        } else if !showFlag && isVisible {
            panelLayout.hidePanel(id)
        } else if showFlag && asPrimary {
            // Visible but possibly not the primary tab in its group —
            // promote it so the file_panel is the active surface even
            // when an existing left group already held something else.
            panelLayout.showPanelAsPrimary(id)
        }
    }

    /// Hide a panel because the user clicked the close button in its
    /// chrome (or hit ⌘L for the file panel). Persists the explicit
    /// close to `settings.layout.show_*` so the next launch respects
    /// the user's choice — the spec's "if the user goes out of their
    /// way to close it, save that off" contract.
    public func hideByUser(panelID id: String) {
        panelLayout.hidePanel(id)
        if updateLayoutSetting(forPanelID: id, visible: false) {
            Task { await saveSettings() }
        }
    }

    /// Show a panel because the user clicked the title-bar toolbar
    /// button, the View menu, or a Show toggle in Settings. Persists
    /// to `settings.layout.show_*` so reconciliation on the next
    /// launch keeps the panel visible.
    public func showByUser(panelID id: String, asPrimary: Bool = false) {
        if asPrimary {
            panelLayout.showPanelAsPrimary(id)
        } else {
            panelLayout.showPanel(id)
        }
        if updateLayoutSetting(forPanelID: id, visible: true) {
            Task { await saveSettings() }
        }
    }

    /// Toggle visibility of a panel as a user action (persists to
    /// `settings.layout.show_*`). Used by the title-bar `sidebar.left`
    /// button and `⌘L` for the file panel — see docs/panels.mdx §5.6.1.
    public func toggleByUser(panelID id: String, asPrimary: Bool = false) {
        if panelLayout.layout.isVisible(id) {
            hideByUser(panelID: id)
        } else {
            showByUser(panelID: id, asPrimary: asPrimary)
        }
    }

    /// Called by the SettingsScene toggles. The settings binding has
    /// already mutated `settings.layout.show_*`; this just reconciles
    /// the live `panelLayout` to match and persists the settings.
    /// Distinct from `showByUser` / `hideByUser` because those write
    /// the settings flag themselves (which would double-write when
    /// driven from the `@Binding` toggle).
    public func applyShowFlag(_ id: String, visible: Bool, asPrimary: Bool = false) {
        let isVisible = panelLayout.layout.isVisible(id)
        if visible && !isVisible {
            if asPrimary {
                panelLayout.showPanelAsPrimary(id)
            } else {
                panelLayout.showPanel(id)
            }
        } else if !visible && isVisible {
            panelLayout.hidePanel(id)
        }
        Task { await saveSettings() }
    }

    /// Map a panel id to its `LayoutSettings.show_*` flag and write
    /// the new value. Returns `true` if a flag was changed (so the
    /// caller knows whether to persist).
    @discardableResult
    private func updateLayoutSetting(forPanelID id: String, visible: Bool) -> Bool {
        var changed = false
        switch id {
        case BuiltInPanelCatalog.filePanel.id:
            if settings.layout.show_file_panel != visible {
                settings.layout.show_file_panel = visible; changed = true
            }
        case BuiltInPanelCatalog.scopeEditor.id:
            if settings.layout.show_scope != visible {
                settings.layout.show_scope = visible; changed = true
            }
        case BuiltInPanelCatalog.metadata.id:
            if settings.layout.show_metadata != visible {
                settings.layout.show_metadata = visible; changed = true
            }
        case BuiltInPanelCatalog.mcpActivity.id:
            if settings.layout.show_mcp != visible {
                settings.layout.show_mcp = visible; changed = true
            }
        case BuiltInPanelCatalog.galleryStrip.id:
            if settings.layout.show_thumb_strip != visible {
                settings.layout.show_thumb_strip = visible; changed = true
            }
        case BuiltInPanelCatalog.statusBar.id:
            if settings.layout.show_status_bar != visible {
                settings.layout.show_status_bar = visible; changed = true
            }
        case BuiltInPanelCatalog.toolbar.id:
            if settings.layout.show_toolbar != visible {
                settings.layout.show_toolbar = visible; changed = true
            }
        default:
            // Panels not mirrored in `LayoutSettings` (histogram,
            // color_picker, frame_nav, etc.) leave the JSON layout as
            // the only persistence — same as before this hook existed.
            break
        }
        return changed
    }

    // MARK: - Watching

    /// React to MCP `select_file` calls. The tool writes the path to
    /// `~/Library/Application Support/ImageGlass_Mac/selection.txt`; we
    /// poll the file and reflect its contents into `selectedFile`. If the
    /// path is not yet in `resolvedFiles` it is added as an ad-hoc entry
    /// (matches `openExternalFile`).
    private func startSelectionWatcher() {
        selectionWatcher?.cancel()
        let url = AppPaths.macAppSupportDir.appendingPathComponent("selection.txt")
        // Touch the file so `open(O_EVTONLY)` succeeds on first launch.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: .atomic)
        }
        let w = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let data = try? Data(contentsOf: url),
                      let raw = String(data: data, encoding: .utf8) else { return }
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return }
                if !self.resolvedFiles.contains(path) {
                    self.resolvedFiles.insert(path, at: 0)
                }
                self.selectedFile = path
            }
        }
        w.start()
        self.selectionWatcher = w
    }

    /// React to MCP `panel.set_view_mode` calls. The tool writes the
    /// chosen mode (`tree`, `list`, `details`, `grid`, `scroller`) to
    /// `~/Library/Application Support/ImageGlass_Mac/panel_view_mode.txt`;
    /// we poll the file and reflect its contents into `panelViewMode`.
    /// Strings outside `{list, tree}` collapse to `.list` for now —
    /// `grid` / `details` / `scroller` views are not wired in the GUI
    /// yet (mcp_file.mdx §3).
    /// React to `DirectoryTreeWalker.firstImageFoundNotification` —
    /// when an MCP `add_directory` / `refresh_directory` call completes
    /// its walk and the §10 trigger conditions hold (viewer is empty,
    /// first matched file's kind is `.image`), the walker posts the URL
    /// and we move the viewer's selection to it. The walker already
    /// emits the `app=panel.auto_select_first` audit line; this is the
    /// missing on-screen half of §10.
    private var firstImageFoundToken: NSObjectProtocol?
    /// `DirectoryTreeWalker.didChangeNotification` token. Drives the
    /// observable `walkerRoots` snapshot the file tree panel renders
    /// (Stage E). Fires on every walk completion, refilter, and
    /// `removeRoot` so the panel updates within ~250 ms (mcp_file.mdx
    /// §4.3 / §6.3 / §7.3).
    private var directoryDidChangeToken: NSObjectProtocol?
    private func startDirectoryTreeWalkerObserver() {
        if let t = firstImageFoundToken {
            NotificationCenter.default.removeObserver(t)
        }
        if let t = directoryDidChangeToken {
            NotificationCenter.default.removeObserver(t)
        }
        // Initial pull so panels that boot before any walk completes
        // still see whatever roots the walker already has (e.g. when
        // bootstrap scheduled walks that finish synchronously on a
        // tiny test fixture).
        refreshWalkerRoots()

        directoryDidChangeToken = NotificationCenter.default.addObserver(
            forName: DirectoryTreeWalker.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshWalkerRoots()
            }
        }

        firstImageFoundToken = NotificationCenter.default.addObserver(
            forName: DirectoryTreeWalker.firstImageFoundNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // URL is Sendable; extract it before crossing into @MainActor Task.
            let url = note.object as? URL
            Task { @MainActor in
                guard let self else { return }
                guard self.selectedFile == nil else {
                    // §10.3 — user clicked something during the walk;
                    // honor that selection and let the walker's callback
                    // fall on the floor.
                    return
                }
                if let url {
                    let path = url.path
                    if !self.resolvedFiles.contains(path) {
                        self.resolvedFiles.insert(path, at: 0)
                    }
                    self.selectedFile = path
                    // §10.5 — "the panel switches to tree view if it
                    // was not already" and "the panel is visible". Wire
                    // both here so the on-screen result matches the
                    // verify step in §10A.4. `showPanelColumn` is a
                    // computed alias for `panelLayout.isVisible(...)`
                    // so we go through `showPanel` directly.
                    self.panelViewMode = .tree
                    self.panelLayout.showPanel(
                        BuiltInPanelCatalog.filePanel.id
                    )
                }
            }
        }
    }

    /// Watch the `ImageGlass_Mac/` support directory for changes to
    /// `directories.yaml`. When the MCP server (a separate process) writes
    /// new roots, this fires and schedules walks on the GUI's own
    /// `DirectoryTreeWalker` so the file tree panel updates live.
    ///
    /// We watch the parent DIRECTORY (not the file itself) because the
    /// atomic write path uses rename, which replaces the inode. A kqueue
    /// watcher on the file's old fd would go silent after the first write.
    ///
    /// We also subscribe to a Darwin distributed notification posted by the
    /// MCP server immediately after each write. Whichever arrives first
    /// (notification or kqueue event) triggers the reload; the second is a
    /// no-op because `reloadDirectoriesFromDisk()` is idempotent.
    private func startDirectoriesFileWatcher() {
        directoriesFileWatcher?.cancel()
        let dir = AppPaths.macAppSupportDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let w = FileWatcher(url: dir) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reloadDirectoriesFromDisk()
            }
        }
        w.start()
        directoriesFileWatcher = w

        if let t = directoriesChangedToken {
            DistributedNotificationCenter.default().removeObserver(t)
        }
        directoriesChangedToken = DistributedNotificationCenter.default().addObserver(
            forName: .init(MCPNotificationBus.directoriesChangedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadDirectoriesFromDisk()
            }
        }
    }

    /// Write this process's PID to `heartbeat.txt`. The MCP server reads
    /// the PID and probes liveness via `kill(pid, 0)` to populate the
    /// `app_running` field in write-tool responses.
    ///
    /// `nonisolated` because it touches no `AppState` instance state —
    /// only `AppPaths` statics and `ProcessInfo` — and shouldn't pull
    /// disk I/O onto the main actor every 30 s. Lets the Timer closure
    /// call it without an actor hop.
    nonisolated private func writeHeartbeat() {
        let url = AppPaths.macAppSupportDir.appendingPathComponent("heartbeat.txt")
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        try? pid.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.writeHeartbeat() }
        }
    }

    /// Diff the on-disk `directories.yaml` against the walker's current
    /// in-memory snapshot and reconcile all three change types
    /// (list_of_files.mdx §3A.1 cross-process update guarantee):
    ///
    /// * New root → `scheduleWalk` (background walk + FS watch)
    /// * Removed root → `removeRoot` (watcher torn down, tree dropped)
    /// * Filter changed → `refilter` (in-memory recompute, no re-walk)
    ///
    /// include_checks.mdx §5.7 — also merges the YAML's
    /// `defaultIncludeState` and `includeOverrides[]` into
    /// `walkerRoots` via `refreshWalkerRoots()` so an external
    /// (MCP-driven) include-state change paints the column immediately.
    private func reloadDirectoriesFromDisk() {
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        // Bail out if the YAML's content is identical to the last
        // reconciled snapshot. The directory watcher fires on every log
        // write under app-support; reconciling on each one was the root
        // cause of the multi-walk pile-up reported in the perf log.
        if let prev = lastReconciledDirectoriesFile, prev == file {
            return
        }
        lastReconciledDirectoriesFile = file
        directoriesRootCount = file.roots.count
        let current = DirectoryTreeWalker.shared.snapshot()
        var currentByPath: [URL: RootDirectory] = [:]
        for r in current { currentByPath[r.path] = r }
        var filePaths: Set<URL> = []
        for root in file.roots {
            filePaths.insert(root.path)
            if let existing = currentByPath[root.path] {
                if existing.filter != root.filter {
                    DirectoryTreeWalker.shared.refilter(root: root.path, filter: root.filter)
                }
            } else {
                DirectoryTreeWalker.shared.scheduleWalk(
                    root: root.path, filter: root.filter,
                    corr: MCPAuditLogger.newCorrelationId()
                )
            }
        }
        for path in currentByPath.keys where !filePaths.contains(path) {
            DirectoryTreeWalker.shared.removeRoot(path: path)
        }
        // include_checks.mdx §5.7 — merge YAML include state into
        // walkerRoots. The walker's snapshot only carries
        // tree+filter+lastWalked; the include override fields live in
        // the YAML and have to be glued on here.
        refreshWalkerRoots()
    }

    /// include_checks.mdx §5.6 — rebuild `walkerRoots` by taking the
    /// walker's tree snapshot and grafting the YAML's
    /// `defaultIncludeState` + `includeOverrides[]` onto each matching
    /// entry. The walker is the source of truth for the *file tree
    /// structure*; `directories.yaml` is the source of truth for the
    /// include state. The panel binds to `walkerRoots`, so this merge
    /// is the single place the two halves meet.
    public func refreshWalkerRoots() {
        let snapshot = DirectoryTreeWalker.shared.snapshot()
        let yaml = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        var overridesByPath: [URL: (IncludeState, [IncludeOverrideEntry])] = [:]
        for r in yaml.roots {
            overridesByPath[r.path] = (r.defaultIncludeState, r.includeOverrides)
        }
        let merged: [RootDirectory] = snapshot.map { walked in
            guard let yamlForRoot = overridesByPath[walked.path] else { return walked }
            return RootDirectory(
                path: walked.path,
                filter: walked.filter,
                lastWalked: walked.lastWalked,
                tree: walked.tree,
                defaultIncludeState: yamlForRoot.0,
                includeOverrides: yamlForRoot.1
            )
        }
        self.walkerRoots = merged
        // menus.mdx View ▸ Left File Tree ▸ "Only Show Included Items" —
        // the flag lives in the same YAML the merge just loaded, so pull
        // it through here too. This is the single funnel called at
        // bootstrap, on every walk change, and after an external
        // (MCP-driven) edit, so the toggle state stays honest without a
        // second file read. Guarded so re-assigning the same value never
        // spuriously invalidates the panel.
        if self.onlyShowIncludedItems != yaml.onlyShowIncludedItems {
            self.onlyShowIncludedItems = yaml.onlyShowIncludedItems
        }
    }

    /// menus.mdx View ▸ Left File Tree ▸ "Only Show Included Items" —
    /// the one entry point the menu toggle calls. Writes the flag into
    /// this window's `directories_window_<N>.yaml`, updates the
    /// in-memory mirror synchronously so the file-tree panel re-renders
    /// in the next frame (ahead of the file watcher), journals the
    /// change, and posts the cross-process notification so a headless
    /// MCP client sees the same truth.
    public func setOnlyShowIncludedItems(_ enabled: Bool) {
        guard onlyShowIncludedItems != enabled else { return }
        do {
            try DirectoriesStore.shared.setOnlyShowIncludedItems(enabled)
        } catch {
            ErrorLog.log("setOnlyShowIncludedItems failed",
                         error: error,
                         class: String(describing: Self.self))
            return
        }
        onlyShowIncludedItems = enabled
        MCPAuditLogger.shared.log([
            ("tool", "panel.set_only_show_included_items"),
            ("enabled", enabled ? "true" : "false"),
            ("client", "gui"),
            ("ok", "true"),
        ])
        MCPNotificationBus.shared.postDirectoriesChanged()
    }

    private func startViewModeWatcher() {
        viewModeWatcher?.cancel()
        let url = AppPaths.macAppSupportDir.appendingPathComponent("panel_view_mode.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("tree".utf8).write(to: url, options: .atomic)
        }
        let w = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let data = try? Data(contentsOf: url),
                      let raw = String(data: data, encoding: .utf8) else { return }
                let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved: PanelViewMode?
                switch mode {
                case "tree": resolved = .tree
                case "list": resolved = .list
                default:     resolved = nil  // empty / unknown — keep current default
                }
                if let resolved, self.panelViewMode != resolved {
                    self.panelViewMode = resolved
                }
            }
        }
        w.start()
        self.viewModeWatcher = w
    }

    /// slideshow.mdx §12 — the MCP `set_slideshow` tool writes
    /// `slideshow.txt`. The GUI reads `on=<bool> corr=<id>
    /// [interval=<sec>]` and routes the toggle through
    /// `SlideshowController`. A one-shot `interval` is applied for the
    /// current run only — it is not persisted to `settings.json`.
    private func startSlideshowWatcher() {
        slideshowWatcher?.cancel()
        let url = AppPaths.macAppSupportDir.appendingPathComponent("slideshow.txt")
        // Do not pre-seed the file: an empty slideshow.txt at startup
        // must not retroactively trigger a toggle. The watcher only
        // fires on writes that arrive after launch.
        let w = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let data = try? Data(contentsOf: url),
                      let raw = String(data: data, encoding: .utf8) else { return }
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }
                // Parse whitespace-separated key=value tokens.
                var on: Bool? = nil
                var interval: Double? = nil
                var corr: String = ""
                for token in line.split(whereSeparator: { $0.isWhitespace }) {
                    let kv = token.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let key = String(kv[0])
                    let val = String(kv[1])
                    switch key {
                    case "on":       on = (val == "true")
                    case "interval": interval = Double(val)
                    case "corr":     corr = val
                    default:         break
                    }
                }
                guard let on else { return }
                // Dedup: kqueue can re-fire on identical writes.
                if !corr.isEmpty, corr == self.lastSlideshowCorr { return }
                self.lastSlideshowCorr = corr
                if on {
                    let seconds = interval
                        ?? self.settings.slideshow.interval_seconds
                    SlideshowController.shared.start(
                        appState: self,
                        seconds: seconds,
                        source: "mcp:set_slideshow"
                    )
                } else {
                    SlideshowController.shared.stop(
                        reason: "user_toggle",
                        source: "mcp:set_slideshow"
                    )
                }
            }
        }
        w.start()
        self.slideshowWatcher = w
    }

    private func startWatching() {
        fileWatcher?.cancel()
        let watcher = FileWatcher(url: AppPaths.scopesDir) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshScopeList()
                if !self.activeScopeName.isEmpty {
                    // Reload the active scope from disk so MCP edits propagate.
                    let reloaded: Scope?
                    do {
                        reloaded = try self.storage.loadScope(self.activeScopeName)
                    } catch LocalStorage.Error.notFound {
                        // Scope file vanished between FSEvent and reload
                        // (deletion / rename in flight). Don't log as an
                        // error — just skip this reload tick; the
                        // refreshScopeList above already updated the
                        // visible scope list.
                        reloaded = nil
                    } catch {
                        ErrorLog.log("storage.loadScope failed during watcher reload for '\(self.activeScopeName)'",
                                     error: error, class: String(describing: Self.self))
                        reloaded = nil
                    }
                    if let scope = reloaded {
                        // Charter §5 workflow: MCP edits include/exclude rules,
                        // then ImageGlass "re-evaluates the scope" so the panel
                        // reflects the new criteria. set_directories /
                        // set_include_criteria / set_exclude_criteria do not
                        // touch resolvedFiles on the MCP side, so if the rules
                        // changed since the last copy we held, walk the new
                        // criteria here.
                        let rulesChanged =
                            self.activeScope?.include != scope.include ||
                            self.activeScope?.exclude != scope.exclude
                        self.activeScope = scope
                        if rulesChanged {
                            await self.reevaluateActive()
                        } else {
                            self.resolvedFiles = scope.resolvedFiles
                            self.lastEvaluated = scope.lastEvaluated
                        }
                    }
                }
            }
        }
        watcher.start()
        self.fileWatcher = watcher
    }

    // MARK: - Selection navigation

    /// The ordered list arrow-key navigation walks. When the file tree is
    /// driven by `directories.yaml` (walker roots), this is the flattened
    /// depth-first **folder order** — exactly the order the tree shows — so
    /// Up/Down/Left/Right step through images in folder order. Falls back to
    /// the scope's `resolvedFiles` when there are no walker roots.
    ///
    /// include_checks.mdx §10.4 — when walker roots exist, excluded
    /// files are dropped from the navigation order so the arrow keys
    /// skip past them. The panel still renders them (with a red-X
    /// swatch), so the user can later cycle them back to `include`.
    public var orderedNavigationFiles: [String] {
        guard !walkerRoots.isEmpty else { return resolvedFiles }
        let roots = walkerRoots
        return DirectoryFilenamePanel.flattenVisible(roots).filter {
            SlideshowController.isInScope(path: $0, roots: roots)
        }
    }

    /// Move selection to the previous file in folder order.
    public func selectPrevious(wrap: Bool = true) {
        let files = orderedNavigationFiles
        guard !files.isEmpty else { return }
        guard let current = selectedFile,
              let idx = files.firstIndex(of: current) else {
            selectedFile = files.first; return
        }
        if idx > 0 {
            selectedFile = files[idx - 1]
        } else if wrap {
            selectedFile = files.last
        }
    }

    /// Move selection to the next file in folder order.
    public func selectNext(wrap: Bool = true) {
        let files = orderedNavigationFiles
        guard !files.isEmpty else { return }
        guard let current = selectedFile,
              let idx = files.firstIndex(of: current) else {
            selectedFile = files.first; return
        }
        if idx < files.count - 1 {
            selectedFile = files[idx + 1]
        } else if wrap {
            selectedFile = files.first
        }
    }

    /// Jump to the first image of the previous folder (Up arrow). "Folder"
    /// is the parent directory of each image, in folder order. Lets the user
    /// skip whole subprojects/pages instead of stepping image-by-image.
    public func selectPreviousFolder(wrap: Bool = true) { jumpFolder(-1, wrap: wrap) }

    /// Jump to the first image of the next folder (Down arrow).
    public func selectNextFolder(wrap: Bool = true) { jumpFolder(1, wrap: wrap) }

    // MARK: - Tree arrow-key navigation (hotkeys.mdx §4)

    /// Current cursor position for arrow-key navigation. Falls back to
    /// `selectedFile` when the user has not yet moved the cursor onto
    /// a folder row.
    public var arrowCursor: String? {
        get { treeNav.activeRow ?? selectedFile }
        set { treeNav.activeRow = newValue }
    }

    /// All currently visible rows (folders + passing files), depth-first
    /// over `walkerRoots`, honoring `treeNav` expansion. Empty when the
    /// walker has no roots — the legacy-tree path falls back to
    /// `selectPrevious` / `selectNext` for ↑ / ↓.
    public var visibleTreeRows: [TreeRow] {
        TreeFlatten.visibleRows(roots: walkerRoots, nav: treeNav)
    }

    /// ↓ — next visible row. If the new row is a file, also update the
    /// viewer's `selectedFile`; if it's a folder, the viewer holds.
    /// Honors `Settings.viewer.wrap_at_ends`.
    public func arrowDown() {
        let wrap = settings.viewer.wrap_at_ends
        let rows = visibleTreeRows
        if rows.isEmpty { selectNext(wrap: wrap); return }
        guard let cursor = arrowCursor,
              let idx = rows.firstIndex(where: { $0.path == cursor }) else {
            activateRow(rows.first)
            return
        }
        let target = idx + 1
        if target < rows.count {
            activateRow(rows[target])
        } else if wrap {
            activateRow(rows.first)
        }
    }

    /// ↑ — previous visible row.
    public func arrowUp() {
        let wrap = settings.viewer.wrap_at_ends
        let rows = visibleTreeRows
        if rows.isEmpty { selectPrevious(wrap: wrap); return }
        guard let cursor = arrowCursor,
              let idx = rows.firstIndex(where: { $0.path == cursor }) else {
            activateRow(rows.last)
            return
        }
        let target = idx - 1
        if target >= 0 {
            activateRow(rows[target])
        } else if wrap {
            activateRow(rows.last)
        }
    }

    /// ← — folder: collapse when expanded, else jump to parent.
    /// File: jump to the file's parent folder. hotkeys.mdx §4.1.
    public func arrowLeft() {
        let rows = visibleTreeRows
        guard let cursor = arrowCursor,
              let row = rows.first(where: { $0.path == cursor }) else {
            return
        }
        if row.isDirectory {
            if treeNav.isExpanded(folderPath: row.path, depth: row.depth) {
                treeNav.setExpanded(row.path, false)
                // Cursor stays on the folder row.
            } else if let parent = row.parentFolder,
                      rows.contains(where: { $0.path == parent }) {
                arrowCursor = parent
            }
        } else {
            // File row → go to the file's parent folder row. Use the
            // path-derived parent so we step out even when the parent
            // wasn't in `parentFolder` (which is `nil` for root files).
            let parent = (row.path as NSString).deletingLastPathComponent
            if rows.contains(where: { $0.path == parent }) {
                arrowCursor = parent
            }
        }
    }

    /// → — folder collapsed: expand. Folder expanded: step into first
    /// child. File: no-op. hotkeys.mdx §4.1.
    public func arrowRight() {
        let rows = visibleTreeRows
        guard let cursor = arrowCursor,
              let row = rows.first(where: { $0.path == cursor }) else {
            return
        }
        guard row.isDirectory else { return }
        if !treeNav.isExpanded(folderPath: row.path, depth: row.depth) {
            treeNav.setExpanded(row.path, true)
            return
        }
        guard let firstChild = row.firstChildPath else { return }
        // The first child may not yet appear in `rows` (we just expanded
        // a moment ago). Re-flatten to find it.
        let refreshed = visibleTreeRows
        guard let target = refreshed.first(where: { $0.path == firstChild })
        else { return }
        activateRow(target)
    }

    /// Activate a visible row from one of the arrow handlers: set the
    /// `treeNav.activeRow` cursor and mirror file selections into
    /// `selectedFile` so the viewer follows. Folders keep the viewer
    /// on its last image (hotkeys.mdx §4.2).
    private func activateRow(_ row: TreeRow?) {
        guard let row else { return }
        treeNav.activeRow = row.path
        if !row.isDirectory {
            selectedFile = row.path
        }
    }

    private func jumpFolder(_ direction: Int, wrap: Bool) {
        let files = orderedNavigationFiles
        guard !files.isEmpty else { return }
        // Distinct parent folders, in first-seen (folder) order.
        var folders: [String] = []
        var seen = Set<String>()
        for f in files {
            let dir = (f as NSString).deletingLastPathComponent
            if seen.insert(dir).inserted { folders.append(dir) }
        }
        guard !folders.isEmpty else { return }
        let currentFolder = selectedFile.map { ($0 as NSString).deletingLastPathComponent }
        let curIdx = currentFolder.flatMap { folders.firstIndex(of: $0) } ?? 0
        var target = curIdx + direction
        if target < 0 { target = wrap ? folders.count - 1 : 0 }
        if target >= folders.count { target = wrap ? 0 : folders.count - 1 }
        let targetFolder = folders[target]
        // Select the first image in that folder.
        if let first = files.first(where: { ($0 as NSString).deletingLastPathComponent == targetFolder }) {
            selectedFile = first
        }
    }

    // MARK: - Externally opened files (drag-drop, Open dialog)

    /// Add an ad-hoc file (from drag-drop or Open dialog) to the resolved
    /// list and select it. Does not modify the active scope on disk —
    /// it's a transient browse. Also records the URL with
    /// `NSDocumentController` so the system Open Recent menu reflects it.
    public func openExternalFile(url: URL) {
        let path = AppPaths.contractTilde(url.path)
        if !resolvedFiles.contains(path) {
            resolvedFiles.insert(path, at: 0)
        }
        selectedFile = path
        // The AppKit recent-document list is what backs both
        // Open Recent menu entries and `NSDocumentController.recentDocumentURLs`.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}
