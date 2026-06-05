import SwiftUI
import AppKit
import ImageGlassCore

/// docs/list_of_files.mdx §3D.5 — the single switch point that picks the
/// concrete renderer based on `state.treeRenderTechnology`. Both the
/// inline file panel and the floating file tree window call this so the
/// menu toggle propagates to every surface.
///
/// `useYellowBackground` is the floating-window option from §3C.3 — the
/// bright-yellow row background that distinguishes the floating tree
/// from the inline panel.
struct SelectableTreeRenderer: View {
    @Bindable var state: AppState
    var useYellowBackground: Bool = false

    var body: some View {
        switch state.treeRenderTechnology {
        case .appKit:
            AppKitOutlineTreeView(state: state,
                                  useYellowBackground: useYellowBackground)
        case .swiftUI:
            SwiftUIOutlineTreeView(state: state,
                                   useYellowBackground: useYellowBackground)
        case .catalyst:
            CatalystStyledTreeView(state: state,
                                   useYellowBackground: useYellowBackground)
        }
    }
}

// MARK: - SwiftUI renderer
//
// docs/list_of_files.mdx §3D.1 — `OutlineGroup` inside `List`. This is
// the existing path from `DirectoryFilenamePanel.walkerTreeView` and
// `FloatingFileTreeWindow.walkerTreeSection`, refactored into a
// reusable view so the floating window and the inline panel share it.

struct SwiftUIOutlineTreeView: View {
    @Bindable var state: AppState
    var useYellowBackground: Bool

    private static let yellow = Color(red: 1.0, green: 1.0, blue: 0.0)

    @ViewBuilder
    var body: some View {
        if useYellowBackground {
            yellowList
        } else {
            sidebarList
        }
    }

    private var sidebarList: some View {
        List(selection: $state.selectedFile) {
            ForEach(state.walkerRoots, id: \.path) { root in
                Section(header: rootHeader(root)) {
                    if let tree = root.tree,
                       let view = DirectoryFilenamePanel.buildView(
                            node: tree, parentPath: root.path) {
                        OutlineGroup(view, children: \.children) { node in
                            row(node)
                                .tag(node.fullPath as String?)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var yellowList: some View {
        List(selection: $state.selectedFile) {
            ForEach(state.walkerRoots, id: \.path) { root in
                Section(header: rootHeader(root)) {
                    if let tree = root.tree,
                       let view = DirectoryFilenamePanel.buildView(
                            node: tree, parentPath: root.path) {
                        OutlineGroup(view, children: \.children) { node in
                            row(node)
                                .listRowBackground(Self.yellow)
                                .tag(node.fullPath as String?)
                        }
                    }
                }
                .listRowBackground(Self.yellow)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Self.yellow)
    }

    // `List(selection:)` alone is unreliable for single-click selection
    // when the host `NSWindow` is not key (the floating file-tree
    // window typically isn't) and when rows live under nested `Section`
    // + `OutlineGroup`. Drive `state.selectedFile` from an explicit tap
    // handler so the main viewer loads the image on the first click
    // regardless of window-focus state. `.contentShape(Rectangle())`
    // expands the hit target to the whole row width.
    private func row(_ node: DirectoryFilenamePanel.NodeView) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory
                  ? "folder"
                  : TreeIconHelper.iconForKind(node.kind))
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let path = node.fullPath {
                let _trace = PerformanceLog.shared.start(
                    "FileTree.SelectionChange",
                    extra: [("path", path), ("source", "swiftUIOutline")]
                )
                defer { _trace.finish() }
                state.selectedFile = path
            }
        }
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
}

// MARK: - AppKit renderer
//
// docs/list_of_files.mdx §3D.1 — `NSOutlineView` inside `NSScrollView`
// driven by `NSOutlineViewDataSource` / `NSOutlineViewDelegate`. Bridged
// into SwiftUI via `NSViewRepresentable`.

struct AppKitOutlineTreeView: NSViewRepresentable {
    @Bindable var state: AppState
    var useYellowBackground: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, useYellowBackground: useYellowBackground)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView(frame: .zero)
        outline.style = .sourceList
        outline.headerView = nil
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 16
        outline.rowHeight = 22
        outline.autoresizesOutlineColumn = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = useYellowBackground
            ? NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)
            : .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = ""
        column.minWidth = 100
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        context.coordinator.outlineView = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = useYellowBackground
        scroll.backgroundColor = useYellowBackground
            ? NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)
            : .clear
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.state = state
        context.coordinator.useYellowBackground = useYellowBackground
        if let outline = context.coordinator.outlineView {
            outline.reloadData()
            // Re-expand the top-level roots so they default to open
            // (parity with the SwiftUI OutlineGroup behavior).
            for i in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: i) as? AppKitOutlineNode,
                   item.depth == 0 {
                    outline.expandItem(item)
                }
            }
            context.coordinator.syncSelection(in: outline)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var state: AppState
        var useYellowBackground: Bool
        weak var outlineView: NSOutlineView?

        init(state: AppState, useYellowBackground: Bool) {
            self.state = state
            self.useYellowBackground = useYellowBackground
        }

        private var rootNodes: [AppKitOutlineNode] {
            state.walkerRoots.compactMap { root -> AppKitOutlineNode? in
                guard let tree = root.tree,
                      let view = DirectoryFilenamePanel.buildView(
                          node: tree, parentPath: root.path) else { return nil }
                return AppKitOutlineNode(view: view, depth: 0)
            }
        }

        func outlineView(_ outlineView: NSOutlineView,
                         numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? AppKitOutlineNode {
                return node.childNodes.count
            }
            return rootNodes.count
        }

        func outlineView(_ outlineView: NSOutlineView,
                         child index: Int,
                         ofItem item: Any?) -> Any {
            if let node = item as? AppKitOutlineNode {
                return node.childNodes[index]
            }
            return rootNodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView,
                         isItemExpandable item: Any) -> Bool {
            (item as? AppKitOutlineNode)?.view.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView,
                         viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            guard let node = item as? AppKitOutlineNode else { return nil }

            let cell = NSTableCellView()
            let icon = NSImageView()
            let label = NSTextField(labelWithString: node.view.name)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown

            let symbolName: String
            if node.view.isDirectory {
                symbolName = "folder"
                icon.contentTintColor = .systemBlue
            } else {
                symbolName = TreeIconHelper.iconForKind(node.view.kind)
                icon.contentTintColor = .secondaryLabelColor
            }
            icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

            cell.addSubview(icon)
            cell.addSubview(label)
            cell.textField = label
            cell.imageView = icon

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            let _trace = PerformanceLog.shared.start(
                "FileTree.SelectionChange",
                extra: [("source", "appKitOutline")]
            )
            defer { _trace.finish() }
            guard let outline = notification.object as? NSOutlineView else { return }
            let row = outline.selectedRow
            guard row >= 0,
                  let node = outline.item(atRow: row) as? AppKitOutlineNode,
                  let path = node.view.fullPath else { return }
            Task { @MainActor in
                state.selectedFile = path
            }
        }

        func syncSelection(in outline: NSOutlineView) {
            guard let selected = state.selectedFile else {
                outline.deselectAll(nil)
                return
            }
            for i in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: i) as? AppKitOutlineNode,
                   node.view.fullPath == selected {
                    let set = IndexSet(integer: i)
                    if outline.selectedRowIndexes != set {
                        outline.selectRowIndexes(set, byExtendingSelection: false)
                        outline.scrollRowToVisible(i)
                    }
                    return
                }
            }
        }
    }
}

/// AppKit-side wrapper around `DirectoryFilenamePanel.NodeView` that adds
/// the depth so `updateNSView` can re-expand the top-level roots.
final class AppKitOutlineNode: NSObject {
    let view: DirectoryFilenamePanel.NodeView
    let depth: Int
    lazy var childNodes: [AppKitOutlineNode] = {
        (view.children ?? []).map { AppKitOutlineNode(view: $0, depth: depth + 1) }
    }()

    init(view: DirectoryFilenamePanel.NodeView, depth: Int) {
        self.view = view
        self.depth = depth
    }
}

// MARK: - Catalyst-styled renderer
//
// docs/list_of_files.mdx §3D.7 — UIKit-styled rendering implemented in
// SwiftUI/AppKit. The visual cues that signal "Catalyst": iOS chevrons,
// 44 pt row height, tinted rounded-rect selection, no NSOutlineView
// disclosure triangle.

struct CatalystStyledTreeView: View {
    @Bindable var state: AppState
    var useYellowBackground: Bool

    @State private var expanded: Set<String> = []

    private static let yellow = Color(red: 1.0, green: 1.0, blue: 0.0)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(state.walkerRoots, id: \.path) { root in
                    if let tree = root.tree,
                       let view = DirectoryFilenamePanel.buildView(
                            node: tree, parentPath: root.path) {
                        rootSection(view, rootPath: root.path.path)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(useYellowBackground ? Self.yellow : Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Default top-level roots to expanded.
            for root in state.walkerRoots {
                expanded.insert(root.path.path)
            }
        }
    }

    private func rootSection(_ view: DirectoryFilenamePanel.NodeView,
                             rootPath: String) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(rootPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                rows(for: view, depth: 0)
            }
        )
    }

    // Recursive — explicit `AnyView` type erasure breaks the
    // `some View` self-reference (same pattern `FileListTreeView.swift`
    // uses for the recursive `nodeView` helper).
    private func rows(for node: DirectoryFilenamePanel.NodeView,
                      depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                catalystRow(node, depth: depth)
                if node.isDirectory,
                   expanded.contains(node.id),
                   let children = node.children {
                    ForEach(children) { child in
                        rows(for: child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func catalystRow(_ node: DirectoryFilenamePanel.NodeView,
                             depth: Int) -> some View {
        let isExpanded = expanded.contains(node.id)
        let isSelected = (node.fullPath != nil) && (node.fullPath == state.selectedFile)

        return HStack(spacing: 8) {
            // iOS-style chevron — rotates when expanded.
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
            } else {
                Spacer().frame(width: 14)
            }

            Image(systemName: node.isDirectory
                  ? "folder.fill"
                  : TreeIconHelper.iconForKind(node.kind))
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(.body))

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .padding(.trailing, 12)
        .frame(height: 44)  // §3D.7 — Catalyst default row height.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.22)
                      : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                let willExpand = !isExpanded
                let action = willExpand ? "FileTree.Expand" : "FileTree.Collapse"
                let _trace = PerformanceLog.shared.start(
                    action,
                    extra: [("path", node.id), ("depth", String(depth))]
                )
                defer { _trace.finish() }
                if isExpanded { expanded.remove(node.id) }
                else { expanded.insert(node.id) }
            } else if let path = node.fullPath {
                let _trace = PerformanceLog.shared.start(
                    "FileTree.SelectionChange",
                    extra: [("path", path), ("source", "catalystRow")]
                )
                defer { _trace.finish() }
                state.selectedFile = path
            }
        }
    }
}

// MARK: - Shared helpers

enum TreeIconHelper {
    static func iconForKind(_ kind: FileKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .svg:   return "vector.path"
        case .video: return "film"
        case nil:    return "doc"
        }
    }
}

