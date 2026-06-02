import SwiftUI
import ImageGlassCore

/// The first modular panel. Two view modes: flat list and file tree.
/// Data source is always `state.resolvedFiles`.
struct DirectoryFilenamePanel: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch state.panelViewMode {
                case .list: listView
                case .tree: treeView
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
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

            Spacer()

            Picker("View", selection: $state.panelViewMode) {
                ForEach(AppState.PanelViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            Button {
                Task { await state.reevaluateActive() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-evaluate scope")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - List

    private var listView: some View {
        List(selection: $state.selectedFile) {
            ForEach(state.resolvedFiles, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: iconForPath(path))
                        .foregroundStyle(.secondary)
                    Text(displayName(for: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(path)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Tree

    private var treeView: some View {
        let roots = FileTreeNode.build(from: state.resolvedFiles)
        return List(selection: $state.selectedFile) {
            ForEach(roots) { root in
                OutlineGroup(root, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory
                              ? "folder"
                              : iconForPath(node.fullPath ?? node.name))
                            .foregroundStyle(node.isDirectory ? .blue : .secondary)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(node.fullPath ?? "" as String?)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Helpers

    private func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func iconForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "tif", "webp", "bmp":
            return "photo"
        case "svg":
            return "vector.path"
        case "psd", "ai":
            return "paintbrush"
        default:
            return "doc"
        }
    }
}
