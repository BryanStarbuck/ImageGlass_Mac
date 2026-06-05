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
                                           selected: $selected, matches: matches)
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
        row(name: node.name, isDir: true, isSel: isCursorRow,
            onPath: containsSelected, expanded: expanded)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) {
                    nav.toggle(node.id, depth: depth)
                }
                nav.activeRow = node.id
            }
    }

    private var fileRow: some View {
        let isSel = (node.fullPath != nil) && node.fullPath == selected
        return row(name: node.name, isDir: false, isSel: isSel,
                   onPath: false, expanded: nil)
            .contentShape(Rectangle())
            .onTapGesture {
                if let p = node.fullPath {
                    selected = p
                    nav.activeRow = p
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
        return HStack(spacing: 7) {
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
        .frame(height: isDir ? 28 : 30)
        .background(
            isSel ? IG.selC : (onPath ? IG.accentC.opacity(0.12) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
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
