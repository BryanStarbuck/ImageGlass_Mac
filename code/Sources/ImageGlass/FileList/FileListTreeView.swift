import SwiftUI
import ImageGlassCore

/// File-Tree mode — grouped by source directory. Spec §2.5.
///
/// Maintains a flat `[Row]` list of currently visible rows that is mutated
/// incrementally on collapse/expand instead of being rebuilt from the
/// recursive tree on every redraw. Rendered through `LazyVStack` with
/// stable string IDs so SwiftUI can diff cheaply.
///
/// Perf trace bounds: `FileTree.Collapse` / `FileTree.Expand` wrap only
/// the `[Row]` mutation — SwiftUI body resolution and the LazyVStack diff
/// are outside the trace.
struct FileListTreeView: View {

    @Bindable var model: FileListViewModel

    @State private var expanded: Set<String> = []

    /// Flat list of currently visible rows. Mutated incrementally on
    /// collapse / expand; rebuilt wholesale only when the underlying tree
    /// fingerprint changes (rootIDs + visible-entry count).
    @State private var rows: [Row] = []

    /// O(1) lookup replacing the previous `visibleEntries.first(where:)`
    /// linear scan. Rebuilt whenever the tree fingerprint changes.
    @State private var pathToEntry: [String: FileEntry] = [:]

    /// Fingerprint of the last rebuild — `(rootIDs joined, visibleEntries.count)`.
    /// Cheap to compute, sufficient to detect a fresh `buildTree()` since
    /// rebuilds funnel through `rebuildVisible()` which drops `cachedTree`.
    @State private var fingerprint: String = ""

    /// Track which roots have been auto-expanded once so reopening the
    /// panel after a tree rebuild doesn't fight a user's explicit collapse.
    @State private var didAutoExpandRoots: Set<String> = []

    struct Row: Identifiable, Equatable {
        let id: String
        let depth: Int
        let kind: Kind

        enum Kind: Equatable {
            case directory(name: String, isExpanded: Bool, hasChildren: Bool)
            case file(path: String)
        }
    }

    var body: some View {
        let tree = model.buildTree()
        let currentFingerprint = Self.fingerprint(tree: tree,
                                                  visibleCount: model.visibleEntries.count)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .onAppear {
            ensureFreshState(tree: tree, fingerprint: currentFingerprint)
        }
        .onChange(of: currentFingerprint) { _, _ in
            ensureFreshState(tree: tree, fingerprint: currentFingerprint)
        }
    }

    // MARK: - Row rendering

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case let .directory(name, isExpanded, _):
            directoryRow(id: row.id, name: name, depth: row.depth,
                         isExpanded: isExpanded)
        case let .file(path):
            if let entry = pathToEntry[path] {
                fileRow(entry: entry, depth: row.depth)
            }
        }
    }

    private func directoryRow(id: String, name: String, depth: Int,
                              isExpanded: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 12)
                .foregroundStyle(.secondary)
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            toggle(id: id)
        }
    }

    private func fileRow(entry: FileEntry, depth: Int) -> some View {
        let isSelected = model.selectionState.selected.contains(entry.path)
        let isFocused = model.selectionState.focused == entry.path
        return HStack(spacing: 4) {
            Spacer().frame(width: 12)
            FileListItemView(
                entry: entry,
                pixelSide: 64,
                pointSide: FileListThumbSize.detailsRowSide,
                isSelected: isSelected,
                isFocused: isFocused,
                showsLabel: false
            )
            .frame(width: FileListThumbSize.detailsRowSide,
                   height: FileListThumbSize.detailsRowSide)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + 4)
        .padding(.vertical, 1)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { model.click(entry.path) }
    }

    // MARK: - Toggle (incremental mutation, traced)

    private func toggle(id: String) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == id }),
              case let .directory(name, isExpanded, hasChildren) = rows[rowIndex].kind
        else { return }

        if isExpanded {
            let _trace = PerformanceLog.shared.start(
                "FileTree.Collapse",
                extra: [("path", id), ("depth", String(rows[rowIndex].depth))]
            )
            defer { _trace.finish() }
            expanded.remove(id)
            collapseRows(at: rowIndex, name: name, hasChildren: hasChildren)
        } else {
            let _trace = PerformanceLog.shared.start(
                "FileTree.Expand",
                extra: [("path", id), ("depth", String(rows[rowIndex].depth))]
            )
            defer { _trace.finish() }
            expanded.insert(id)
            expandRows(at: rowIndex, name: name, hasChildren: hasChildren)
        }
    }

    /// Splice out the contiguous range of rows whose `depth >` the collapsed
    /// row's depth — the next sibling (or end of list) terminates the range.
    /// O(visible descendants).
    private func collapseRows(at rowIndex: Int, name: String, hasChildren: Bool) {
        let depth = rows[rowIndex].depth
        var end = rowIndex + 1
        while end < rows.count && rows[end].depth > depth {
            end += 1
        }
        if end > rowIndex + 1 {
            rows.removeSubrange((rowIndex + 1)..<end)
        }
        rows[rowIndex] = Row(
            id: rows[rowIndex].id,
            depth: depth,
            kind: .directory(name: name, isExpanded: false, hasChildren: hasChildren)
        )
    }

    /// DFS the node's subtree honoring `expanded`; splice the resulting rows
    /// in immediately after `rowIndex`. O(visible-descendants-of-toggled-node).
    private func expandRows(at rowIndex: Int, name: String, hasChildren: Bool) {
        let depth = rows[rowIndex].depth
        let id = rows[rowIndex].id
        guard let node = findNode(id: id, in: model.buildTree()) else {
            rows[rowIndex] = Row(
                id: id,
                depth: depth,
                kind: .directory(name: name, isExpanded: true, hasChildren: hasChildren)
            )
            return
        }
        var inserted: [Row] = []
        if let children = node.children {
            for child in children {
                appendRows(for: child, depth: depth + 1, into: &inserted)
            }
        }
        rows[rowIndex] = Row(
            id: id,
            depth: depth,
            kind: .directory(name: name, isExpanded: true, hasChildren: hasChildren)
        )
        if !inserted.isEmpty {
            rows.insert(contentsOf: inserted, at: rowIndex + 1)
        }
    }

    // MARK: - Full rebuild on fingerprint change

    private func ensureFreshState(tree: [FileListTreeNode], fingerprint newFP: String) {
        if newFP == self.fingerprint && !rows.isEmpty { return }
        self.fingerprint = newFP

        // Default-expand top-level source roots the first time we see them.
        for root in tree where !didAutoExpandRoots.contains(root.id) {
            expanded.insert(root.id)
            didAutoExpandRoots.insert(root.id)
        }
        // Drop auto-expand bookkeeping for roots that disappeared so a
        // future reappearance triggers the auto-expand again.
        let liveRootIDs = Set(tree.map(\.id))
        didAutoExpandRoots.formIntersection(liveRootIDs)

        // Rebuild path -> entry dictionary (O(N) once per tree rebuild).
        var dict: [String: FileEntry] = [:]
        dict.reserveCapacity(model.visibleEntries.count)
        for entry in model.visibleEntries {
            dict[entry.path] = entry
        }
        self.pathToEntry = dict

        // Rebuild flat row list via DFS honoring `expanded`.
        var newRows: [Row] = []
        newRows.reserveCapacity(model.visibleEntries.count + tree.count)
        for root in tree {
            appendRows(for: root, depth: 0, into: &newRows)
        }
        self.rows = newRows
    }

    /// DFS append: emit a row for `node`, recurse into children only if
    /// `expanded.contains(node.id)`. The flat list never holds rows for
    /// hidden subtrees.
    private func appendRows(for node: FileListTreeNode,
                            depth: Int,
                            into out: inout [Row]) {
        if node.isDirectory {
            let isExpanded = expanded.contains(node.id)
            let hasChildren = (node.children?.isEmpty == false)
            out.append(Row(
                id: node.id,
                depth: depth,
                kind: .directory(name: node.name,
                                 isExpanded: isExpanded,
                                 hasChildren: hasChildren)
            ))
            if isExpanded, let children = node.children {
                for child in children {
                    appendRows(for: child, depth: depth + 1, into: &out)
                }
            }
        } else if let filePath = node.filePath {
            out.append(Row(
                id: node.id,
                depth: depth,
                kind: .file(path: filePath)
            ))
        }
    }

    /// Locate a node by its stable `id`. The tree is small relative to the
    /// flat row list (folders only) and this is invoked once per expand,
    /// so a simple DFS is fine.
    private func findNode(id: String,
                          in tree: [FileListTreeNode]) -> FileListTreeNode? {
        for root in tree {
            if let found = findNode(id: id, in: root) { return found }
        }
        return nil
    }

    private func findNode(id: String,
                          in node: FileListTreeNode) -> FileListTreeNode? {
        if node.id == id { return node }
        guard node.isDirectory, let children = node.children else { return nil }
        for child in children {
            if let found = findNode(id: id, in: child) { return found }
        }
        return nil
    }

    /// Cheap snapshot of the tree's identity. Concatenates root IDs and
    /// pins the visible-entry count. A fresh `buildTree()` after a
    /// `rebuildVisible()` (which drops `cachedTree`) will change one of
    /// these unless the visible set is byte-for-byte identical, in which
    /// case skipping the rebuild is correct.
    private static func fingerprint(tree: [FileListTreeNode],
                                    visibleCount: Int) -> String {
        var s = "\(visibleCount)|"
        for root in tree {
            s += root.id
            s += ";"
        }
        return s
    }
}
