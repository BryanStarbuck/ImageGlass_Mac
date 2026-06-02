import SwiftUI
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            DirectoryFilenamePanel(state: state)
                .frame(minWidth: 220, idealWidth: 280)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ImageViewer(state: state, viewer: state.viewer)
                    statusBar
                }
                if state.crop.isActive {
                    Divider()
                    CropPanelView(controller: state.crop)
                        .background(.regularMaterial)
                }
            }
        }
        .navigationTitle(windowTitle)
        .tint(state.themeStore.currentTheme.colors.accentColor)
        .preferredColorScheme(state.themeStore.currentTheme.preferredColorScheme)
        .task { await state.bootstrap() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.showPanelColumn.toggle()
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
