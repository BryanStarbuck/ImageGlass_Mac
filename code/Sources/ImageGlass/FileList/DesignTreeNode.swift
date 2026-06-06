import SwiftUI
import ImageGlassCore

/// Pure-SwiftUI recursive tree row for the directory/filename panel,
/// styled to the Claude Design handoff (filepanel.jsx Tree). Directories
/// expand/collapse; files select into `state.selectedFile`. No AppKit
/// `NSOutlineView` dependency — renders reliably inside the docked panel.
///
/// Expansion is owned by the shared `TreeNavigator` (via `AppState`) so
/// the keyboard arrow keys in the viewer (hotkeys.mdx §4) can drive the
/// same expand/collapse the user toggles with the mouse.
struct DesignTreeNode: View {
    let node: DirectoryFilenamePanel.NodeView
    let depth: Int
    @Bindable var nav: TreeNavigator
    @Binding var selected: String?
    let matches: (String) -> Bool
    /// include_checks.mdx §2 — every row renders a swatch keyed off
    /// the walker root the row belongs to. Passing the roots down to
    /// every node lets the swatch resolve the relative path + state
    /// without reaching into AppState.
    var walkerRoots: [RootDirectory] = []
    /// include_checks.mdx §3.1 / §5.6 — the swatch needs to update
    /// `state.walkerRoots` in place after persisting; the AppState
    /// handle is the cleanest way to give it that capability.
    var appState: AppState? = nil

    /// Folder-row "active cursor" highlight when the arrow keys parked
    /// on this folder without changing the viewer's file. hotkeys.mdx §4.2.
    private var isCursorRow: Bool {
        nav.activeRow == (node.fullPath ?? node.id)
    }

    private var expanded: Bool {
        nav.isExpanded(folderPath: node.id, depth: depth)
    }

    var body: some View {
        if node.isDirectory {
            VStack(alignment: .leading, spacing: 2) {
                if hasVisibleDescendant {
                    directoryRow
                    if expanded {
                        ForEach(visibleChildren) { child in
                            DesignTreeNode(node: child, depth: depth + 1,
                                           nav: nav,
                                           selected: $selected, matches: matches,
                                           walkerRoots: walkerRoots,
                                           appState: appState)
                        }
                    }
                }
            }
            // Auto-reveal: when the selected image lands inside this folder,
            // open it once so the user sees where the current image lives.
            // The TreeNavigator handles the explicit-collapse case so a
            // collapsed folder containing the selection stays collapsed.
            .onChange(of: selected) { _, _ in
                if containsSelected && !nav.explicitlyCollapsed.contains(node.id) {
                    nav.setExpanded(node.id, true)
                }
            }
            .onAppear {
                if containsSelected && !nav.explicitlyCollapsed.contains(node.id) {
                    nav.setExpanded(node.id, true)
                }
            }
        } else if matches(node.fullPath ?? node.name) {
            fileRow
        }
    }

    // MARK: - Rows

    private var directoryRow: some View {
        // `onTheSelectedPath` tints every ancestor folder of the current
        // image so the containing folder is obvious at a glance.
        let folderPath = node.id
        let isRoot = walkerRoots.contains { $0.path.path == folderPath }
        return row(name: node.name, isDir: true, isSel: isCursorRow,
                   onPath: containsSelected, expanded: expanded)
            .contentShape(Rectangle())
            .onTapGesture {
                let willExpand = !expanded
                let action = willExpand ? "FileTree.Expand" : "FileTree.Collapse"
                let _trace = PerformanceLog.shared.start(
                    action,
                    extra: [("path", node.id), ("depth", String(depth))]
                )
                defer { _trace.finish() }
                withAnimation(.easeOut(duration: 0.12)) {
                    nav.toggle(node.id, depth: depth)
                }
                nav.activeRow = node.id
                // include_checks.mdx §3.5 — single-selection across
                // rows. Tapping a folder clears `selectedFile` so the
                // previously selected file no longer paints blue.
                // Without this the file panel showed two highlighted
                // rows at once (last-clicked file + newly-clicked
                // folder).
                selected = nil
            }
            .overlay(rowContextMenuBridge(folderPath: folderPath, isRoot: isRoot))
    }

    private var fileRow: some View {
        let isSel = (node.fullPath != nil) && node.fullPath == selected
        let filePath = node.fullPath ?? node.id
        return row(name: node.name, isDir: false, isSel: isSel,
                   onPath: false, expanded: nil)
            .contentShape(Rectangle())
            .onTapGesture {
                if let p = node.fullPath {
                    let _trace = PerformanceLog.shared.start(
                        "FileTree.SelectionChange",
                        extra: [("path", p), ("source", "designTree")]
                    )
                    defer { _trace.finish() }
                    selected = p
                    nav.activeRow = p
                }
            }
            .overlay(fileRowContextMenuBridge(filePath: filePath))
            // dir_ui.mdx §5.4 — `ScrollViewReader` in `DirectoryFilenamePanel`
            // needs each file row tagged with its full path so it can
            // `proxy.scrollTo(path, anchor: .center)` whenever
            // `state.selectedFile` changes (slideshow advance, ↑/↓,
            // MCP select_file, watcher re-sync).
            .id(filePath)
    }

    // MARK: - Context menu bridges (docs/right_click.mdx §7.1 / §7.2 / §7.3)

    /// File-row right-click overlay. Pre-selection per §3.3, then build
    /// via `ContextMenuBuilders.fileRow(state:path:)`.
    @ViewBuilder
    private func fileRowContextMenuBridge(filePath: String) -> some View {
        if let app = appState {
            ContextMenuBridge(
                menuBuilder: {
                    ContextMenuBuilders.fileRow(state: app, path: filePath)
                },
                preselect: {
                    app.selectedFile = filePath
                    app.treeNav.activeRow = filePath
                },
                surface: .fileRow,
                targetPath: filePath
            )
            .allowsHitTesting(true)
        }
    }

    /// Folder / root row right-click overlay. Dispatches to either
    /// `folderRow` or `rootRow` builder based on whether this is a
    /// registered walker root.
    @ViewBuilder
    private func rowContextMenuBridge(folderPath: String, isRoot: Bool) -> some View {
        if let app = appState {
            if isRoot {
                let rootURL = URL(fileURLWithPath: folderPath)
                ContextMenuBridge(
                    menuBuilder: {
                        ContextMenuBuilders.rootRow(state: app,
                                                    rootPath: rootURL)
                    },
                    preselect: {
                        app.treeNav.activeRow = folderPath
                    },
                    surface: .rootRow,
                    targetPath: folderPath
                )
                .allowsHitTesting(true)
            } else {
                ContextMenuBridge(
                    menuBuilder: {
                        ContextMenuBuilders.folderRow(state: app,
                                                     path: folderPath)
                    },
                    preselect: {
                        app.treeNav.activeRow = folderPath
                    },
                    surface: .folderRow,
                    targetPath: folderPath
                )
                .allowsHitTesting(true)
            }
        }
    }

    /// `isSel` = this is the selected file (solid accent fill).
    /// `onPath` = this folder is an ancestor of the selected file
    /// (subtle accent tint + accent folder name, so the containing folder
    /// chain stands out).
    private func row(name: String, isDir: Bool, isSel: Bool,
                     onPath: Bool, expanded: Bool?) -> some View {
        let nameColor: Color = isSel ? .white
            : (onPath ? IG.accentC : (isDir ? IG.textC : IG.textC))
        let iconColor: Color = isSel ? .white
            : (isDir ? IG.accentC : IG.text2C)
        let rowHeight: CGFloat = isDir ? 28 : 30
        // include_checks.mdx §2 — the leftmost swatch column. Sits
        // flush with the panel's left padding (never indented per
        // §2.1) so every row's swatch lines up in a single column.
        return HStack(spacing: 6) {
            includeSwatch(rowHeight: rowHeight)
            HStack(spacing: 7) {
                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSel ? Color.white : IG.text3C)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: isDir ? "folder.fill" : iconName(node.kind))
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(name)
                    .font(.system(size: 12.5, weight: (isDir || onPath) ? .semibold : .regular))
                    .foregroundStyle(nameColor)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .background(
                isSel ? IG.selC : (onPath ? IG.accentC.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .padding(.leading, 4)
    }

    /// §2.1 + §2.5 — render the swatch when we can resolve a walker
    /// root for the row; render an inert spacer when we can't (a
    /// legacy scope-driven row that has no walker root). The spacer
    /// preserves column alignment in the mixed case. The swatch is
    /// sized against the file-icon height — not the row — so it does
    /// not bloat the row's vertical extent (§2.1).
    @ViewBuilder
    private func includeSwatch(rowHeight: CGFloat) -> some View {
        if let absPath = node.fullPath ?? (node.isDirectory ? node.id : nil),
           let root = IncludeStateController.root(for: absPath, in: walkerRoots),
           let app = appState {
            IncludeColumnSwatch(
                absolutePath: absPath,
                root: root,
                isRoot: IncludeStateController.isRoot(
                    absolutePath: absPath, in: walkerRoots
                ),
                onCycle: { next in
                    _ = IncludeStateController.setState(
                        absolutePath: absPath,
                        state: next,
                        appState: app
                    )
                }
            )
            .frame(width: IncludeColumnSwatch.swatchSide,
                   height: IncludeColumnSwatch.swatchSide)
        } else {
            Spacer()
                .frame(width: IncludeColumnSwatch.swatchSide,
                       height: IncludeColumnSwatch.swatchSide)
        }
    }

    /// True when this node's subtree contains the currently selected file.
    private var containsSelected: Bool {
        guard let sel = selected, node.isDirectory else { return false }
        return Self.subtreeContains(node, path: sel)
    }

    private static func subtreeContains(_ n: DirectoryFilenamePanel.NodeView,
                                        path: String) -> Bool {
        if !n.isDirectory { return n.fullPath == path }
        return (n.children ?? []).contains { subtreeContains($0, path: path) }
    }

    // MARK: - Filtering

    private var visibleChildren: [DirectoryFilenamePanel.NodeView] {
        (node.children ?? []).filter { child in
            child.isDirectory
                ? Self.anyVisibleDescendant(child, matches: matches)
                : matches(child.fullPath ?? child.name)
        }
    }

    private var hasVisibleDescendant: Bool {
        Self.anyVisibleDescendant(node, matches: matches)
    }

    private static func anyVisibleDescendant(
        _ n: DirectoryFilenamePanel.NodeView,
        matches: (String) -> Bool
    ) -> Bool {
        if !n.isDirectory { return matches(n.fullPath ?? n.name) }
        return (n.children ?? []).contains { anyVisibleDescendant($0, matches: matches) }
    }

    private func iconName(_ kind: FileKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .svg:   return "scribble.variable"
        case .video: return "film"
        case nil:    return "doc"
        }
    }
}
