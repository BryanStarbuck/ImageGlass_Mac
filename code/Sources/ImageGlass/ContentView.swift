import SwiftUI
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState
    @Bindable var layout: LayoutController

    var body: some View {
        PanelHost(controller: layout) {
            VStack(spacing: 0) {
                ImageViewer(filePath: state.selectedFile)
                statusBar
            }
        }
        .navigationTitle(windowTitle)
        .task { await state.bootstrap() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.showPanelColumn.toggle()
                    Task {
                        if state.showPanelColumn {
                            await layout.show(id: BuiltinPanels.directoryFilename.id)
                        } else {
                            await layout.hide(id: BuiltinPanels.directoryFilename.id)
                            await layout.hide(id: BuiltinPanels.filePanel.id)
                            await layout.hide(id: BuiltinPanels.fileTree.id)
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle panel column")
            }
        }
    }

    private var windowTitle: String {
        if let path = state.selectedFile {
            return (path as NSString).lastPathComponent
        }
        return "ImageGlass"
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(state.resolvedFiles.count) files")
                .foregroundStyle(.secondary)
            if let evaluatedAt = state.lastEvaluated {
                Text("· evaluated \(relative(evaluatedAt))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path = state.selectedFile {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
