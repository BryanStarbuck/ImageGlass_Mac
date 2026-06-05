import Foundation
import ImageGlassCore

/// Thin adapter that pushes data from `AppState` into a `FileListViewModel`.
/// Hosted in this file (rather than mutating AppState) so the file-list
/// panel's binding to AppState is one-way and surgical.
@MainActor
public enum FileListBinding {

    /// Apply the current AppState snapshot to the view model. Call this from
    /// the host (panel framework / ContentView) whenever AppState fires its
    /// observable change.
    public static func apply(
        appState: AppState,
        to model: FileListViewModel
    ) {
        let _trace = PerformanceLog.shared.start(
            "FileTree.Reload",
            extra: [
                ("source", "binding.apply"),
                ("files", String(appState.resolvedFiles.count)),
            ]
        )
        defer { _trace.finish() }
        let scopeName: String
        if let scope = appState.activeScope {
            scopeName = scope.description ?? scope.name
        } else {
            scopeName = appState.activeScopeName
        }
        let dirs = appState.activeScope?.include.directories ?? []
        model.update(
            scopeName: scopeName,
            sourceDirectories: dirs,
            resolvedPaths: appState.resolvedFiles
        )
        // Mirror selection so AppState.selectedFile stays the focused/clicked file.
        if let sel = appState.selectedFile,
           model.selectionState.focused != sel {
            model.setSelection(paths: [sel])
        }
    }
}
