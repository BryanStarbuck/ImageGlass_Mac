import SwiftUI
import ImageGlassCore

/// Minimal @main entry point so the ImageGlass executable links.
///
/// NOTE: This is a placeholder added by the File List Panel agent solely so
/// `swift build` succeeds. The panels-framework / app-shell agent owns the
/// real app entry point — when that lands, it should supersede this file.
///
/// Until then, this stub hosts a `FileListViewModel` and the `FileListPanelView`
/// so the file-list panel can be exercised in isolation.
@main
struct ImageGlassApp: App {
    @State private var appState = AppState()
    @State private var fileListModel = FileListViewModel()

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentRootView(appState: appState, fileListModel: fileListModel)
                .task { await bootstrap() }
                .frame(minWidth: 600, minHeight: 400)
        }
    }

    private func bootstrap() async {
        await appState.bootstrap()
        FileListBinding.apply(appState: appState, to: fileListModel)
        fileListModel.onLoadInViewer = { path in
            appState.selectedFile = path
        }
    }
}

/// Tiny shell view — hosts the File List Panel and a placeholder for the
/// image viewer. The panels-framework agent will replace this layout.
private struct ContentRootView: View {
    @Bindable var appState: AppState
    @Bindable var fileListModel: FileListViewModel

    var body: some View {
        HSplitView {
            FileListPanelView(
                model: fileListModel,
                onRefresh: {
                    Task { await appState.reevaluateActive() }
                },
                onEditScope: {},
                onPickScope: {}
            )
            .frame(minWidth: 280, idealWidth: 360)
            VStack {
                if let path = appState.selectedFile {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(8)
                } else {
                    Text("Select a file from the list").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minWidth: 200)
            .background(.background)
        }
        .onChange(of: appState.resolvedFiles) { _, _ in
            FileListBinding.apply(appState: appState, to: fileListModel)
        }
        .onChange(of: appState.activeScopeName) { _, _ in
            FileListBinding.apply(appState: appState, to: fileListModel)
        }
    }
}
