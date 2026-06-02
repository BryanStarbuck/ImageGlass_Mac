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
    public var selectedFile: String? = nil
    public var lastEvaluated: Date? = nil

    public var showPanelColumn: Bool = true
    public var panelViewMode: PanelViewMode = .list

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
            await loadConfig()
            await loadSettings()
            themeStore.bootstrap()
            PanelRegistry.shared.registerBuiltInPanels()
            panelLayout.reloadFromDisk()
            panelLayout.startWatching()
            let bootstrapped = try storage.bootstrapIfNeeded()
            await refreshScopeList()
            await activate(scopeNamed: bootstrapped)
            startWatching()
        } catch {
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
            NSLog("ImageGlass config load failed: \(error) — using built-in defaults")
            self.configPaths = paths
            self.config = .builtIn
        }
    }

    public func refreshScopeList() async {
        availableScopes = (try? storage.listScopes()) ?? []
    }

    public func activate(scopeNamed name: String) async {
        guard let scope = try? storage.loadScope(name) else { return }
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

    public func reevaluateActive() async {
        guard var scope = activeScope else { return }
        scope = ScopeEvaluator.evaluate(scope)
        try? storage.saveScope(scope)
        activeScope = scope
        resolvedFiles = scope.resolvedFiles
        lastEvaluated = scope.lastEvaluated
        if selectedFile == nil || !(resolvedFiles.contains(selectedFile ?? "")) {
            selectedFile = resolvedFiles.first
        }
        rebuildSourceWatchers()
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

    private func startWatching() {
        fileWatcher?.cancel()
        let watcher = FileWatcher(url: AppPaths.scopesDir) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshScopeList()
                if !self.activeScopeName.isEmpty {
                    // Reload the active scope from disk so MCP edits propagate.
                    if let scope = try? self.storage.loadScope(self.activeScopeName) {
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
