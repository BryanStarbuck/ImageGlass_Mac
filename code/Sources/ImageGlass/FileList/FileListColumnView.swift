import SwiftUI
import ImageGlassCore

/// Column mode — Finder-style multi-column. Spec §2.6 — stretch goal.
///
/// v1 implementation: a horizontal stack of three SwiftUI columns derived from
/// the per-source tree, with the rightmost column showing metadata about the
/// focused file. NSCollectionView-backed version is a later refinement (spec
/// flags this mode as a stretch goal).
struct FileListColumnView: View {

    @Bindable var model: FileListViewModel

    var body: some View {
        let tree = model.buildTree()

        HStack(spacing: 0) {
            ColumnList(
                title: "Sources",
                items: tree.map { TreeColumnItem(id: $0.id, name: $0.name, node: $0) },
                onSelect: { selectedRootId = $0.id; selectedSubId = nil }
            )
            Divider()

            if let root = tree.first(where: { $0.id == selectedRootId ?? "" }) {
                let subItems = (root.children ?? []).map {
                    TreeColumnItem(id: $0.id, name: $0.name, node: $0)
                }
                ColumnList(
                    title: "Subfolders",
                    items: subItems,
                    onSelect: { selectedSubId = $0.id }
                )
                Divider()
            }

            if let rootNode = tree.first(where: { $0.id == selectedRootId ?? "" }),
               let subNode = (rootNode.children ?? []).first(where: { $0.id == selectedSubId ?? "" }) {
                let leaves = collectLeaves(of: subNode)
                ColumnList(
                    title: "Files",
                    items: leaves.map { TreeColumnItem(id: $0.id, name: $0.name, node: $0) },
                    onSelect: { item in
                        if let p = item.node.filePath {
                            model.click(p)
                        }
                    }
                )
                Divider()
            }

            VStack(alignment: .leading) {
                Text("Preview")
                    .font(.headline)
                    .padding(.bottom, 4)
                if let focused = model.selectionState.focused,
                   let entry = model.visibleEntries.first(where: { $0.path == focused }) {
                    FileListItemView(
                        entry: entry,
                        pixelSide: 512,
                        pointSide: 200,
                        isSelected: true,
                        isFocused: true,
                        showsLabel: false
                    )
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                    if let s = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No selection")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minWidth: 200)
            .padding(10)
        }
    }

    @State private var selectedRootId: String?
    @State private var selectedSubId: String?

    private func collectLeaves(of node: FileListTreeNode) -> [FileListTreeNode] {
        var out: [FileListTreeNode] = []
        for child in node.children ?? [] {
            if child.isLeaf { out.append(child) }
            else { out.append(contentsOf: collectLeaves(of: child)) }
        }
        return out
    }
}

private struct TreeColumnItem: Identifiable {
    let id: String
    let name: String
    let node: FileListTreeNode
}

private struct ColumnList: View {
    let title: String
    let items: [TreeColumnItem]
    let onSelect: (TreeColumnItem) -> Void

    @State private var hoveredId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HStack {
                            Image(systemName: item.node.isDirectory ? "folder" : "doc")
                            Text(item.name).lineLimit(1)
                            Spacer()
                            if item.node.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            hoveredId == item.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onHover { inside in hoveredId = inside ? item.id : nil }
                        .onTapGesture { onSelect(item) }
                    }
                }
            }
        }
        .frame(minWidth: 140, idealWidth: 160)
    }
}
