import SwiftUI
import ImageGlassCore

/// File-Tree mode — grouped by source directory. Spec §2.5.
struct FileListTreeView: View {

    @Bindable var model: FileListViewModel

    @State private var expanded: Set<String> = []

    var body: some View {
        let tree = model.buildTree()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tree) { root in
                    nodeView(root, depth: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .onAppear {
            // Spec §2.5 — top-level source roots default to expanded.
            for root in tree {
                expanded.insert(root.id)
            }
        }
    }

    // Recursive — needs explicit type erasure to avoid `some View` self-reference.
    private func nodeView(_ node: FileListTreeNode, depth: Int) -> AnyView {
        AnyView(nodeViewBody(node, depth: depth))
    }

    @ViewBuilder
    private func nodeViewBody(_ node: FileListTreeNode, depth: Int) -> some View {
        if node.isDirectory {
            let isExpanded = expanded.contains(node.id)
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expanded.remove(node.id) }
                else { expanded.insert(node.id) }
            }
            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    nodeView(child, depth: depth + 1)
                }
            }
        } else if let filePath = node.filePath,
                  let entry = entry(forPath: filePath) {
            HStack(spacing: 4) {
                Spacer().frame(width: 12)
                FileListItemView(
                    entry: entry,
                    pixelSide: 64,
                    pointSide: FileListThumbSize.detailsRowSide,
                    isSelected: model.selectionState.selected.contains(entry.path),
                    isFocused: model.selectionState.focused == entry.path,
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
                model.selectionState.selected.contains(entry.path)
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture { model.click(entry.path) }
        }
    }

    private func entry(forPath path: String) -> FileEntry? {
        model.visibleEntries.first(where: { $0.path == path })
    }
}
