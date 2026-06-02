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

    /// Setting overrides captured from `/Name=Value` flags at launch. The
    /// configs subsystem is responsible for layering these on top of the
    /// loaded `igconfig.json` — `AppState` just hands the dictionary along.
    public var cliOverrides: [String: String] = [:]

    /// Positional file/directory paths supplied on the command line. The
    /// UI may pick the first one to display once bootstrap completes.
    public var cliOpenPaths: [String] = []

    /// True if `--startup-boost` was on the command line.
    public var cliStartupBoost: Bool = false

    public enum PanelViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        public var label: String { self == .list ? "List" : "Tree" }
    }

    private let storage = LocalStorage.shared
    private var fileWatcher: FileWatcher?

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
            let bootstrapped = try storage.bootstrapIfNeeded()
            await refreshScopeList()
            await activate(scopeNamed: bootstrapped)
            startWatching()
        } catch {
            NSLog("ImageGlass bootstrap failed: \(error)")
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
}
