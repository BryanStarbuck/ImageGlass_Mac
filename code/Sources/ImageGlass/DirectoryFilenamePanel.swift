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

    /// Live filter over filenames (design: filepanel.jsx search field).
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(IG.sidebarLineC)
            Group {
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
            Divider().overlay(IG.sidebarLineC)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IG.sidebarC)
    }

    /// Case-insensitive filename match against the search field.
    private func matchesSearch(_ path: String) -> Bool {
        searchText.isEmpty
            || (path as NSString).lastPathComponent
                .range(of: searchText, options: .caseInsensitive) != nil
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
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("FILES")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(IG.text3C)
                Spacer()
                // mcp_file.mdx §10.5 — refresh; spinner while walking.
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
                        if state.isWalking { ProgressView().controlSize(.small) }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IG.text2C)
                }
                .buttonStyle(.plain)
                .disabled(state.isWalking)
                .help(state.walkerRoots.isEmpty ? "Re-evaluate scope"
                      : "Re-walk every root in directories.yaml")
            }

            // Segmented List / Tree control (design: filepanel.jsx Seg).
            Picker("View", selection: $state.panelViewMode) {
                ForEach(AppState.PanelViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: state.panelViewMode) { _, mode in
                MCPAuditLogger.shared.log([
                    ("tool", "panel.set_view_mode"),
                    ("mode", mode.rawValue),
                    ("client", "gui"),
                    ("ok", "true"),
                ])
                MCPNotificationBus.shared.emitViewModeChanged(mode: mode.rawValue)
            }

            // Search field.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(IG.text3C)
                TextField("Filter files", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IG.textC)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(IG.text3C)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(IG.fieldC, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(IG.glassLineC, lineWidth: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Footer (design: filepanel.jsx)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(IG.mcpGreenC).frame(width: 6, height: 6)
                Text("\(visibleFileCount) files")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(IG.textC)
                if let evaluatedAt = state.lastEvaluated {
                    Text("· evaluated \(relativeAge(evaluatedAt))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IG.text3C)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
                    .foregroundStyle(IG.accentC)
                Text("Scope: \(scopeLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(IG.text3C)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var visibleFileCount: Int {
        state.walkerRoots.isEmpty
            ? state.resolvedFiles.filter(matchesSearch).count
            : Self.flattenVisible(state.walkerRoots).filter(matchesSearch).count
    }

    private var scopeLabel: String {
        if !state.activeScopeName.isEmpty { return state.activeScopeName }
        if let first = state.walkerRoots.first { return first.path.lastPathComponent }
        return "default"
    }

    private func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
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
        let files: [String] = (state.walkerRoots.isEmpty
            ? state.resolvedFiles
            : Self.flattenVisible(state.walkerRoots)).filter(matchesSearch)
        // Group flat files by their parent folder, preserving folder order,
        // so List mode shows folder headers (and the ↑/↓ folder-jump has a
        // visible structure to land on).
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for f in files {
            let dir = (f as NSString).deletingLastPathComponent
            if groups[dir] == nil { order.append(dir) }
            groups[dir, default: []].append(f)
        }
        let activeFolder = state.selectedFile.map { ($0 as NSString).deletingLastPathComponent }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(order, id: \.self) { folder in
                    Section(header: folderHeader(folder,
                                                 count: groups[folder]?.count ?? 0,
                                                 active: folder == activeFolder)) {
                        ForEach(groups[folder] ?? [], id: \.self) { path in
                            designRow(name: displayName(for: path),
                                      icon: iconForPath(path),
                                      isDir: false,
                                      depth: 1,
                                      selected: state.selectedFile == path)
                                .contentShape(Rectangle())
                                .onTapGesture { state.selectedFile = path }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    /// Folder group header for List mode. Highlights (accent tint) the folder
    /// that holds the current image, so "which folder is active" is obvious.
    private func folderHeader(_ folder: String, count: Int, active: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(IG.accentC)
            Text(folderLabel(folder))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? IG.accentC : IG.text2C)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(IG.text3C)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? IG.accentC.opacity(0.12) : IG.sidebarC,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Folder path shortened relative to its registered root (e.g.
    /// "jfk-social / feed-page"), so headers stay readable in a narrow column.
    private func folderLabel(_ folder: String) -> String {
        for root in state.walkerRoots {
            let rp = root.path.path
            if folder == rp { return root.path.lastPathComponent }
            if folder.hasPrefix(rp + "/") {
                let rel = String(folder.dropFirst(rp.count + 1))
                return root.path.lastPathComponent + " / " + rel.replacingOccurrences(of: "/", with: " / ")
            }
        }
        return (folder as NSString).lastPathComponent
    }

    // MARK: - Design row + pure-SwiftUI tree

    /// One styled row (design: filepanel.jsx). Accent fill when selected.
    private func designRow(name: String, icon: String, isDir: Bool,
                           depth: Int, selected: Bool,
                           expanded: Bool? = nil) -> some View {
        HStack(spacing: 7) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : IG.text3C)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
            }
            Image(systemName: isDir ? "folder.fill" : icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white
                                 : (isDir ? IG.accentC : IG.text2C))
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12.5, weight: isDir ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : IG.textC)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 8)
        .frame(height: isDir ? 28 : 30)
        .background(selected ? IG.selC : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
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
        // Pure-SwiftUI recursive outline (design: filepanel.jsx Tree). The
        // inline panel renders this directly rather than the runtime-selected
        // SelectableTreeRenderer, so it never depends on the AppKit
        // NSOutlineView path. Roots default expanded.
        let roots: [NodeView] = state.walkerRoots.compactMap { root in
            guard let tree = root.tree else { return nil }
            return Self.buildView(node: tree, parentPath: root.path)
        }
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(roots) { root in
                    DesignTreeNode(node: root, depth: 0,
                                   selected: $state.selectedFile,
                                   matches: matchesSearch)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
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

    /// NSViewRepresentable debug border. Rendered as a real NSView subview
    /// so it is z-ordered above the AppKit NSScrollView that backs List —
    /// pure SwiftUI overlays (.border, .overlay with Shape) live in the CA
    /// layer tree and are occluded by List's NSScrollView on macOS.
    private struct DebugBorderOverlay: NSViewRepresentable {
        let color: NSColor
        let lineWidth: CGFloat

        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderColor = color.cgColor
            v.layer?.borderWidth = lineWidth
            v.layer?.backgroundColor = NSColor.clear.cgColor
            return v
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.layer?.borderColor = color.cgColor
            nsView.layer?.borderWidth = lineWidth
        }
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
