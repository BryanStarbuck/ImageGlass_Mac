import Foundation
import Observation
import ImageGlassCore

/// Hotkey-driven navigation over the file/folder tree rendered by the
/// Directory Panel. Centralizes which folders are open so that the
/// arrow keys (handled at the viewer level) can both **collapse** /
/// **expand** folders and **move** through visible rows in lockstep
/// with what the user sees in the panel. Spec: `docs/hotkeys.mdx` §4.
///
/// One observable instance is owned by `AppState`. The `DesignTreeNode`
/// view reads `isExpanded(_:depth:)` to render, and clicks call
/// `setExpanded(_:_:)`; keyboard arrows route through `moveLeft` /
/// `moveRight` / `moveUp` / `moveDown`.
@MainActor
@Observable
public final class TreeNavigator {
    /// Folder paths the user (or a `moveRight` press) has explicitly
    /// opened. A folder also reads as expanded if it is shallow enough
    /// to fall under `defaultExpandedDepth` and has not been explicitly
    /// collapsed.
    public var explicitlyExpanded: Set<String> = []
    /// Folder paths the user has explicitly collapsed. Suppresses the
    /// default-expand-at-depth-≤1 heuristic so a closed root stays closed.
    public var explicitlyCollapsed: Set<String> = []
    /// Roots and their immediate children are open by default — same
    /// rule the legacy `DesignTreeNode` used (`depth <= 1`).
    public var defaultExpandedDepth: Int = 1

    /// The "cursor" row in the panel. May be either a file path
    /// (mirrored into `state.selectedFile`) or a folder path
    /// (selection-only — no viewer change). hotkeys.mdx §4.2 keeps the
    /// viewer's image stable while the cursor is on a folder row.
    public var activeRow: String? = nil

    /// Invoked after any state change to `explicitlyExpanded` or
    /// `explicitlyCollapsed` so the bound `WindowState` can flush the
    /// new map to `settings_window_<N>.yaml#session.directory_panel.expanded_paths`.
    /// `AppState.bindToFrontmostWindow(_:)` installs this; nil during
    /// tests / before the first window bind.
    public var onPersistRequested: (@MainActor () -> Void)?

    public init() {}

    public func isExpanded(folderPath: String, depth: Int) -> Bool {
        if explicitlyExpanded.contains(folderPath) { return true }
        if explicitlyCollapsed.contains(folderPath) { return false }
        return depth <= defaultExpandedDepth
    }

    public func setExpanded(_ folderPath: String, _ open: Bool) {
        if open {
            explicitlyExpanded.insert(folderPath)
            explicitlyCollapsed.remove(folderPath)
        } else {
            explicitlyCollapsed.insert(folderPath)
            explicitlyExpanded.remove(folderPath)
        }
        onPersistRequested?()
    }

    public func toggle(_ folderPath: String, depth: Int) {
        let wasOpen = isExpanded(folderPath: folderPath, depth: depth)
        setExpanded(folderPath, !wasOpen)
    }

    /// Open every ancestor folder on `path`'s chain so the row for
    /// `path` is visible. Called when the viewer selects a file (e.g.
    /// MCP `select_file`, drag-drop) so the panel reveals it.
    public func revealAncestors(of path: String) {
        var changed = false
        var p = (path as NSString).deletingLastPathComponent
        while !p.isEmpty, p != "/" {
            if !explicitlyExpanded.contains(p) || explicitlyCollapsed.contains(p) {
                explicitlyExpanded.insert(p)
                explicitlyCollapsed.remove(p)
                changed = true
            }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p { break }
            p = parent
        }
        if changed { onPersistRequested?() }
    }

    /// Path → expansion-state map for round-tripping with
    /// `WindowScopedSettings.session.directoryPanel.expandedPaths`.
    /// `true` means explicitly expanded; `false` means explicitly
    /// collapsed. Paths absent from the map fall back to the
    /// depth-based default in `isExpanded(folderPath:depth:)`.
    public var expansionMap: [String: Bool] {
        var m: [String: Bool] = [:]
        for p in explicitlyExpanded { m[p] = true }
        for p in explicitlyCollapsed { m[p] = false }
        return m
    }

    /// Replace the in-memory expansion sets with the persisted map.
    /// Does **not** trigger `onPersistRequested` — this is the
    /// load-from-disk path and would otherwise echo back to disk.
    public func loadExpansionMap(_ map: [String: Bool]) {
        var ex: Set<String> = []
        var co: Set<String> = []
        for (k, v) in map {
            if v { ex.insert(k) } else { co.insert(k) }
        }
        explicitlyExpanded = ex
        explicitlyCollapsed = co
    }
}

// MARK: - Visible-row flattening + arrow-key navigation

public struct TreeRow: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let depth: Int
    /// Parent folder path, or `nil` for a root row.
    public let parentFolder: String?
    /// First child's path (folder or file) when the row is an *expanded*
    /// directory; `nil` otherwise. Used by `→` to step into a folder.
    public let firstChildPath: String?
}

@MainActor
public enum TreeFlatten {
    /// Depth-first walk of every `RootDirectory`, honoring `nav`'s
    /// expansion state. Folder rows are always emitted. File rows are
    /// only emitted when `passesFilter == true`.
    public static func visibleRows(
        roots: [RootDirectory],
        nav: TreeNavigator
    ) -> [TreeRow] {
        var out: [TreeRow] = []
        for root in roots {
            guard let tree = root.tree else { continue }
            walk(node: tree, parentURL: root.path, depth: 0,
                 parentFolder: nil, nav: nav, out: &out)
        }
        return out
    }

    private static func walk(
        node: DirectoryNode,
        parentURL: URL,
        depth: Int,
        parentFolder: String?,
        nav: TreeNavigator,
        out: inout [TreeRow]
    ) {
        switch node {
        case .directory(_, let children):
            let folderPath = parentURL.path
            // First-child resolution for `→`. Match the order the panel
            // renders: first directory child (any), else first file
            // child that passes the filter. Returns `nil` when the
            // directory is empty (a `→` on an expanded empty folder is
            // a no-op).
            let firstChild = firstVisibleChildPath(
                children: children,
                parentURL: parentURL
            )
            out.append(TreeRow(
                path: folderPath,
                isDirectory: true,
                depth: depth,
                parentFolder: parentFolder,
                firstChildPath: firstChild
            ))
            if nav.isExpanded(folderPath: folderPath, depth: depth) {
                for child in children {
                    let childURL = parentURL.appendingPathComponent(child.name)
                    walk(node: child, parentURL: childURL,
                         depth: depth + 1, parentFolder: folderPath,
                         nav: nav, out: &out)
                }
            }
        case .file(_, _, let passes):
            guard passes else { return }
            out.append(TreeRow(
                path: parentURL.path,
                isDirectory: false,
                depth: depth,
                parentFolder: parentFolder,
                firstChildPath: nil
            ))
        }
    }

    private static func firstVisibleChildPath(
        children: [DirectoryNode],
        parentURL: URL
    ) -> String? {
        // Match the panel's render order (walker-sorted, lexicographic).
        // First visible child = first directory or first passing file in
        // that order — what the user sees right below the expanded
        // folder's row. hotkeys.mdx §4.1 → "step into first child".
        for child in children {
            switch child {
            case .directory:
                return parentURL.appendingPathComponent(child.name).path
            case .file(_, _, let passes):
                if passes {
                    return parentURL.appendingPathComponent(child.name).path
                }
            }
        }
        return nil
    }
}
