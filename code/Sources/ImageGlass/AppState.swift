import Foundation
import Observation
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

    /// Merged, effective configuration produced by `ConfigLoader`. Loaded
    /// during `bootstrap()` from the three igconfig.* tiers + CLI overrides.
    public var config: Config = .builtIn

    /// Paths used to load `config`. Useful for diagnostics and for the
    /// Settings UI ("where is my config file?").
    public var configPaths: ConfigPaths = ConfigPaths.resolve()

    /// Theme catalog + current selection (see docs/themes.mdx).
    public let themeStore = ThemeStore()

    public enum PanelViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        public var label: String { self == .list ? "List" : "Tree" }
    }

    private let storage = LocalStorage.shared
    private var fileWatcher: FileWatcher?

    public init() {}

    // MARK: - Bootstrap

    public func bootstrap() async {
        do {
            try AppPaths.ensureDirectories()
            try AppPaths.ensureLayoutDirectories()
            await loadConfig()
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
        }
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
                        self.activeScope = scope
                        self.resolvedFiles = scope.resolvedFiles
                        self.lastEvaluated = scope.lastEvaluated
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
    /// it's a transient browse.
    public func openExternalFile(url: URL) {
        let path = AppPaths.contractTilde(url.path)
        if !resolvedFiles.contains(path) {
            resolvedFiles.insert(path, at: 0)
        }
        selectedFile = path
    }
}
