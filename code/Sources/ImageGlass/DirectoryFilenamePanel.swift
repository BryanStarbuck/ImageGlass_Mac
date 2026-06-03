import SwiftUI
import AppKit
import ImageGlassCore

/// The directory / filename panel from `docs/use_cases/mcp_file.mdx`.
///
/// Two view modes:
///
/// * **Tree** — one outline per root in `directories.yaml`, mirroring
///   the `DirectoryTreeWalker`'s in-memory `DirectoryNode` graph. Only
///   files with `passesFilter == true` are rendered. This is the §3 /
///   §10 one-to-one mapping with the YAML.
/// * **List** — a flat union of every visible file across every root,
///   in the same depth-first / lexicographic order the walker uses for
///   `firstImageFound`. The first list row is therefore what §10's
///   auto-select would pick.
///
/// Both modes bind to `state.walkerRoots`, which `AppState` keeps in
/// sync with `DirectoryTreeWalker.shared.snapshot()` via the
/// `didChangeNotification` subscription (Stage E wiring). When the
/// walker has no roots, the panel falls back to the legacy
/// `state.resolvedFiles` scope path so the scope-driven UI still works.
/// When both are empty, the §9.2 / §1.3 empty state is rendered with
/// an `[+ Add directory]` action wired to the same `NSOpenPanel` flow
/// as the Directories menu.
struct DirectoryFilenamePanel: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                // mcp_file.mdx §1.3 / §9.2 — the empty state is only
                // shown when *no* root is registered. If
                // `directories.yaml` has roots but the walker has not
                // finished its first pass, render the root rows up
                // front with a "walking…" indicator so the column is
                // never blank between launch and walk-completion.
                if storedRootCount == 0 && state.resolvedFiles.isEmpty {
                    emptyState
                } else {
                    switch state.panelViewMode {
                    case .list: listView
                    case .tree: treeView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The chrome already gives the panel a background, but the
        // SwiftUI HStack will hide the column if every child returns
        // an "ideal width = 0" view. Force a visible background so
        // the bar is *always* drawn, even when the list is empty.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// `directories.yaml` root count. Reads from `state.directoriesRootCount`
    /// (cached by `AppState.bootstrap` and `reloadDirectoriesFromDisk`) rather
    /// than hitting disk on every SwiftUI render pass.
    private var storedRootCount: Int {
        if !state.walkerRoots.isEmpty { return state.walkerRoots.count }
        return state.directoriesRootCount
    }

    // MARK: - Header (toolbar)

    private var header: some View {
        HStack(spacing: 8) {
            // The legacy multi-scope picker. Hidden when no named scopes
            // exist (the directory tree panel can run scope-free).
            if !state.availableScopes.isEmpty {
                Picker("Scope", selection: $state.activeScopeName) {
                    ForEach(state.availableScopes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: state.activeScopeName) { _, new in
                    Task { await state.activate(scopeNamed: new) }
                }
            } else {
                Text("Files")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("View", selection: $state.panelViewMode) {
                ForEach(AppState.PanelViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: state.panelViewMode) { _, mode in
                // mcp_file.mdx §3.4 — the GUI tree-toggle records a
                // log line under `client=gui` (no `mcp.` prefix) so
                // human-driven mode changes are audit-traceable.
                MCPAuditLogger.shared.log([
                    ("tool", "panel.set_view_mode"),
                    ("mode", mode.rawValue),
                    ("client", "gui"),
                    ("ok", "true"),
                ])
                MCPNotificationBus.shared.emitViewModeChanged(
                    mode: mode.rawValue
                )
            }

            // mcp_file.mdx §10.5 — the refresh button spins while a
            // background walk is in flight. ZStack so the icon and the
            // ProgressView swap in place without shifting the toolbar.
            // When there are walker roots, refresh re-walks every one
            // (the Stage E behavior). Otherwise it falls back to the
            // legacy scope re-evaluation.
            Button {
                if !state.walkerRoots.isEmpty {
                    refreshAllWalkerRoots()
                } else {
                    Task { await state.reevaluateActive() }
                }
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .opacity(state.isWalking ? 0 : 1)
                    if state.isWalking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .help(state.walkerRoots.isEmpty
                  ? "Re-evaluate scope"
                  : "Re-walk every root in directories.yaml")
            .buttonStyle(.borderless)
            .disabled(state.isWalking)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Empty state (mcp_file.mdx §9.2)

    /// Centered SF Symbol, label, and an `[+ Add directory]` button
    /// that opens `NSOpenPanel` (same code path as the Directories
    /// menu's "Add Directory…" item).
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No directories added")
                .foregroundStyle(.secondary)
            Button("+ Add directory") {
                addDirectoryFromPicker()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - List

    /// Flat union of every visible file across every walker root.
    /// Depth-first lexicographic, matching the walker's `firstImage`
    /// traversal so the first row is the §10 auto-select target.
    /// Falls back to `state.resolvedFiles` when the walker has no
    /// roots (legacy multi-scope path).
    private var listView: some View {
        let files: [String] = state.walkerRoots.isEmpty
            ? state.resolvedFiles
            : Self.flattenVisible(state.walkerRoots)
        return List(selection: $state.selectedFile) {
            ForEach(files, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: iconForPath(path))
                        .foregroundStyle(.secondary)
                    Text(displayName(for: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(path as String?)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Tree

    /// One `Section` per walker root with an `OutlineGroup` rendering
    /// the in-memory `DirectoryNode` tree. Directories with no visible
    /// children render as empty expandable rows so the directory
    /// structure is honest even when a filter has narrowed the view
    /// (matches §3A.7 "the panel re-renders only the rows whose
    /// passesFilter flipped"). Falls back to the legacy path-based
    /// tree from `state.resolvedFiles` when the walker has no roots.
    @ViewBuilder
    private var treeView: some View {
        if !state.walkerRoots.isEmpty {
            walkerTreeView
        } else if storedRootCount > 0 {
            // Roots are stored in directories.yaml but the background walk
            // hasn't completed yet — show a spinner instead of the empty
            // legacy fallback.
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading directory tree…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            legacyTreeView
        }
    }

    private var walkerTreeView: some View {
        // docs/list_of_files.mdx §3D.5 — the renderer is selected at
        // runtime from the View ▸ Tree View submenu. The walker / data
        // layer is untouched on a swap.
        SelectableTreeRenderer(state: state, useYellowBackground: false)
    }

    /// Legacy code path: when `directories.yaml` is empty but the
    /// active scope has resolved files, render those as a synthetic
    /// path-based tree. Kept so scope-driven workflows that predate
    /// Stage E still work.
    private var legacyTreeView: some View {
        let roots = FileTreeNode.build(from: state.resolvedFiles)
        // Skip the synthetic "/" / "~" wrapper level so the first real
        // path component (e.g. "Users", "home") is the top-level row.
        let topNodes: [FileTreeNode] = roots.flatMap { $0.children ?? [] }
        return List(selection: $state.selectedFile) {
            OutlineGroup(topNodes, children: \.children) { node in
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory
                          ? "folder"
                          : iconForPath(node.fullPath ?? node.name))
                        .foregroundStyle(node.isDirectory ? .blue : .secondary)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(node.fullPath as String?)
            }
        }
        .listStyle(.sidebar)
    }

    private func rootHeader(_ root: RootDirectory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(root.path.path)
                .lineLimit(1)
                .truncationMode(.head)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func row(for node: NodeView) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory
                  ? "folder"
                  : iconForKind(node.kind))
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    /// Re-walk every root in `directories.yaml`. Equivalent to MCP
    /// `refresh_directory()` with no `path` argument. Used by the
    /// refresh button when the walker is the active data source.
    private func refreshAllWalkerRoots() {
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        let corr = MCPAuditLogger.newCorrelationId()
        MCPAuditLogger.shared.logDirectoryToolCall(
            toolName: "refresh_directory",
            path: nil,
            client: "gui",
            corr: corr,
            ok: true,
            extra: [("roots", String(file.roots.count))]
        )
        for r in file.roots {
            DirectoryTreeWalker.shared.scheduleWalk(
                root: r.path, filter: r.filter, corr: corr
            )
        }
    }

    /// Opens `NSOpenPanel` restricted to folders. Each picked folder
    /// becomes a new root in `directories.yaml` and triggers a walk
    /// via `DirectoryTreeWalker.scheduleWalk`. Same code path as the
    /// Directories menu's "Add Directory…" item.
    private func addDirectoryFromPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let corr = MCPAuditLogger.newCorrelationId()
            do {
                let (_, already) = try DirectoriesStore.shared.addRoot(path: url.path)
                if !already {
                    MCPAuditLogger.shared.logDirectoryToolCall(
                        toolName: "add_directory",
                        path: url.path,
                        client: "gui",
                        corr: corr,
                        ok: true
                    )
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: url,
                        filter: .empty,
                        corr: corr
                    )
                }
            } catch {
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "add_directory",
                    path: url.path,
                    client: "gui",
                    corr: corr,
                    ok: false,
                    err: "path_not_found"
                )
            }
        }
    }

    // MARK: - Helpers

    private func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func iconForPath(_ path: String) -> String {
        if let kind = FileKind.classify(path: path) {
            return iconForKind(kind)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "psd", "ai": return "paintbrush"
        default:          return "doc"
        }
    }

    private func iconForKind(_ kind: FileKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .svg:   return "vector.path"
        case .video: return "film"
        case nil:    return "doc"
        }
    }

    // MARK: - Tree flatten + projection

    /// Depth-first lexicographic flatten of every visible file across
    /// every root. Mirrors the walker's order so List mode's first row
    /// matches §10's `firstImage` selection rule.
    static func flattenVisible(_ roots: [RootDirectory]) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let tree = root.tree else { continue }
            flatten(node: tree, parentPath: root.path, into: &out)
        }
        return out
    }

    private static func flatten(
        node: DirectoryNode,
        parentPath: URL,
        into out: inout [String]
    ) {
        switch node {
        case .directory(_, let children):
            // The walker sorts children lexicographically; trust it.
            // Recurse depth-first so the result order matches the
            // walker's `firstImage` traversal (§10.2).
            for child in children {
                let childPath = parentPath.appendingPathComponent(child.name)
                flatten(node: child, parentPath: childPath, into: &out)
            }
        case .file(_, _, let passes):
            if passes {
                out.append(parentPath.path)
            }
        }
    }

    /// `OutlineGroup` needs an `Identifiable` value type with a stable
    /// child accessor. The walker's `DirectoryNode` doesn't know its
    /// own path (only its name), so we project a small view-model that
    /// carries the resolved full path and prunes filtered-out files.
    struct NodeView: Identifiable {
        let id: String       // full path
        let name: String
        let fullPath: String?  // nil for directory rows
        let kind: FileKind?
        let isDirectory: Bool
        let children: [NodeView]?
    }

    /// Recursive projection. Drops `.file` nodes whose `passesFilter == false`
    /// so the tree only shows files the active filter allows. Directories are
    /// always preserved in full — `children` is never `nil` for a directory
    /// node, even when every descendant file is filtered out. This keeps the
    /// full directory skeleton visible so the user can navigate the hierarchy
    /// regardless of which file types the filter currently admits.
    static func buildView(node: DirectoryNode, parentPath: URL) -> NodeView? {
        switch node {
        case .file(let name, let kind, let passes):
            guard passes else { return nil }
            // parentPath is already the file's own URL (the caller appended
            // the child name before passing), so use it directly. Appending
            // `name` again would double the filename in the path.
            let path = parentPath.path
            return NodeView(
                id: path, name: name,
                fullPath: path, kind: kind,
                isDirectory: false, children: nil
            )
        case .directory(let name, let children):
            let projected: [NodeView] = children.compactMap {
                buildView(
                    node: $0,
                    parentPath: parentPath.appendingPathComponent($0.name)
                )
            }
            // Always return a non-nil children array for directories so the
            // full hierarchy is visible even when no descendant files pass
            // the current filter. OutlineGroup treats [] as a leaf (no
            // disclosure triangle) on macOS, which is correct for a truly
            // empty directory; the user still sees the directory row.
            return NodeView(
                id: parentPath.path, name: name,
                fullPath: nil, kind: nil,
                isDirectory: true,
                children: projected
            )
        }
    }
}
