import Foundation
import Observation
import AppKit
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
    public var selectedFile: String? = nil {
        didSet {
            // mcp_file.mdx §2.3 — every selection change (whether the
            // user clicked a row, hit ←/→, dropped a file, or an MCP
            // tool wrote selection.txt) emits a single
            // `notifications/imageglass/selection_changed` push event
            // so connected MCP clients see the move.
            guard oldValue != selectedFile else { return }
            // mcp_file.mdx §10.1 trigger condition #1 / §10.7 negative
            // case: the walker only auto-selects when the viewer is
            // empty. Mirror selectedFile into the walker so a manual
            // selection (or any incoming MCP `select_file`) suppresses
            // a future first-image-found auto-advance.
            DirectoryTreeWalker.shared.viewerIsEmpty = (selectedFile == nil)
            if let path = selectedFile {
                MCPNotificationBus.shared.emitSelectionChanged(path: path)
            }
        }
    }
    public var lastEvaluated: Date? = nil

    public var showPanelColumn: Bool = true
    public var panelViewMode: PanelViewMode = .list

    /// Live snapshot of `DirectoryTreeWalker.shared.snapshot()`. Refreshed
    /// from `DirectoryTreeWalker.didChangeNotification` (walk completed,
    /// refilter ran, root removed) and is the source of truth the file
    /// tree panel (Stage E) binds to. Empty until the walker starts
    /// emitting; populated for every root in `directories.yaml`.
    public var walkerRoots: [RootDirectory] = []

    /// Layout of all modular panels (toolbar, file panel, status bar, ...).
    /// Loaded from `layout.json` at bootstrap, persisted on every mutation.
    /// See docs/panels.mdx.
    public let panelLayout = PanelLayoutModel()

    /// Per-window viewer state (zoom mode, pan, rotation, overlays, ...).
    /// Lives here so menu commands and the SwiftUI viewer can share it.
    public var viewer: ViewerState = ViewerState()

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

    /// Crop subsystem controller. Owned by AppState so the SwiftUI panel
    /// and the overlay can share one observable instance. See `Crop/`.
    public let cropController: CropController = CropController()

    private let storage = LocalStorage.shared
    private var fileWatcher: FileWatcher?
    /// Watchers for the source directories of the active scope. Spec §
    /// "Animation & Multi-Frame Support" → "real-time file change monitoring":
    /// re-evaluate the scope when an external tool drops a new file into a
    /// watched directory.
    private var sourceWatchers: [FileWatcher] = []
    /// Watches `~/Library/Application Support/ImageGlass_Mac/selection.txt`
    /// so MCP `select_file` calls move the GUI selection without us having
    /// to invent a wire-level push channel (mcp_file.mdx §2.3).
    private var selectionWatcher: FileWatcher?
    /// Watches `~/Library/Application Support/ImageGlass_Mac/panel_view_mode.txt`
    /// so MCP `panel.set_view_mode` switches the file panel between list
    /// and tree views without a wire-level push (mcp_file.mdx §3).
    private var viewModeWatcher: FileWatcher?
    /// Set to `true` while a scope walk is in flight on a background task
    /// (mcp_file.mdx §10.5 — the toolbar's refresh icon spins while this is true).
    public var isWalking: Bool = false
    /// Cancellable handle to the in-flight scope walk. A second
    /// `reevaluateActive()` arriving before the first finishes cancels the
    /// first so only the latest scope state ever lands in the GUI
    /// (mcp_file.mdx §10.3).
    private var walkTask: Task<Void, Never>?

    public init() {}

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
            await loadConfig()
            await loadSettings()
            themeStore.bootstrap()
            PanelRegistry.shared.registerBuiltInPanels()
            panelLayout.reloadFromDisk()
            panelLayout.startWatching()
            let bootstrapped = try storage.bootstrapIfNeeded()
            // mcp_file.mdx §1.3 — first launch leaves an empty
            // `directories.yaml` so the panel has a defined state.
            var directoryCount = 0
            var storedRoots: [RootDirectory] = []
            do {
                let file = try DirectoriesStore.shared.ensureExists()
                directoryCount = file.roots.count
                storedRoots = file.roots
            } catch {
                ErrorLog.log("DirectoriesStore.ensureExists failed",
                             error: error, class: String(describing: Self.self))
            }
            MCPAuditLogger.shared.logStartup(layout: "Browser", directoryCount: directoryCount)
            await refreshScopeList()
            await activate(scopeNamed: bootstrapped)
            startWatching()
            startSelectionWatcher()
            startViewModeWatcher()
            startDirectoryTreeWalkerObserver()
            // mcp_file.mdx §3A.5: the walker is "running even when the
            // component is turned off" — so every root in
            // directories.yaml is scheduled at boot. A relaunch with
            // pre-existing roots repopulates the in-memory tree without
            // the user re-adding anything.
            for root in storedRoots {
                let corr = MCPAuditLogger.newCorrelationId()
                DirectoryTreeWalker.shared.scheduleWalk(
                    root: root.path, filter: root.filter, corr: corr
                )
            }
        } catch {
            ErrorLog.log("bootstrap failed", error: error, class: String(describing: Self.self))
            NSLog("ImageGlass bootstrap failed: \(error)")
        }
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

    /// (Re)attach FileWatchers to each include-rule directory in the active
    /// scope so external changes (new screenshots, deleted files, renames)
    /// trigger a re-evaluation. Called after every scope activation.
    private func rebuildSourceWatchers() {
        sourceWatchers.forEach { $0.cancel() }
        sourceWatchers.removeAll()
        guard let scope = activeScope else { return }
        var seen = Set<String>()
        for dir in scope.include.directories {
            let expanded = AppPaths.expandTilde(dir)
            guard seen.insert(expanded).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let url = URL(fileURLWithPath: expanded)
            let w = FileWatcher(url: url) { [weak self] in
                Task { @MainActor in
                    await self?.reevaluateActive()
                }
            }
            w.start()
            sourceWatchers.append(w)
        }
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
        walkerRoots = DirectoryTreeWalker.shared.snapshot()

        directoryDidChangeToken = NotificationCenter.default.addObserver(
            forName: DirectoryTreeWalker.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.walkerRoots = DirectoryTreeWalker.shared.snapshot()
            }
        }

        firstImageFoundToken = NotificationCenter.default.addObserver(
            forName: DirectoryTreeWalker.firstImageFoundNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                guard self.selectedFile == nil else {
                    // §10.3 — user clicked something during the walk;
                    // honor that selection and let the walker's callback
                    // fall on the floor.
                    return
                }
                if let url = note.object as? URL {
                    let path = url.path
                    if !self.resolvedFiles.contains(path) {
                        self.resolvedFiles.insert(path, at: 0)
                    }
                    self.selectedFile = path
                    // §10.5 — "the panel switches to tree view if it
                    // was not already" and "the panel is visible". Wire
                    // both here so the on-screen result matches the
                    // verify step in §10A.4.
                    self.panelViewMode = .tree
                    self.showPanelColumn = true
                    self.panelLayout.showPanel(
                        BuiltInPanelCatalog.filePanel.id
                    )
                }
            }
        }
    }

    private func startViewModeWatcher() {
        viewModeWatcher?.cancel()
        let url = AppPaths.macAppSupportDir.appendingPathComponent("panel_view_mode.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: .atomic)
        }
        let w = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let data = try? Data(contentsOf: url),
                      let raw = String(data: data, encoding: .utf8) else { return }
                let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved: PanelViewMode = (mode == "tree") ? .tree : .list
                if self.panelViewMode != resolved {
                    self.panelViewMode = resolved
                }
            }
        }
        w.start()
        self.viewModeWatcher = w
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

    /// Move selection to the previous file in `resolvedFiles`.
    public func selectPrevious(wrap: Bool = true) {
        guard !resolvedFiles.isEmpty else { return }
        guard let current = selectedFile,
              let idx = resolvedFiles.firstIndex(of: current) else {
            selectedFile = resolvedFiles.first; return
        }
        if idx > 0 {
            selectedFile = resolvedFiles[idx - 1]
        } else if wrap {
            selectedFile = resolvedFiles.last
        }
    }

    /// Move selection to the next file in `resolvedFiles`.
    public func selectNext(wrap: Bool = true) {
        guard !resolvedFiles.isEmpty else { return }
        guard let current = selectedFile,
              let idx = resolvedFiles.firstIndex(of: current) else {
            selectedFile = resolvedFiles.first; return
        }
        if idx < resolvedFiles.count - 1 {
            selectedFile = resolvedFiles[idx + 1]
        } else if wrap {
            selectedFile = resolvedFiles.first
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
