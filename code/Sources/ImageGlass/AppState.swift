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
            themeStore.bootstrap()
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
