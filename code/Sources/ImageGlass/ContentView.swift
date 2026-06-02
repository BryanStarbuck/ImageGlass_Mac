import SwiftUI
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        PanelHostView(state: state, model: state.panelLayout) {
            ImageViewer(state: state, viewer: state.viewer)
        }
        .navigationTitle(windowTitle)
        .tint(state.themeStore.currentTheme.colors.accentColor)
        .preferredColorScheme(state.themeStore.currentTheme.preferredColorScheme)
        .task { await state.bootstrap() }
        .onChange(of: state.panelLayout.layout.floating) { _, _ in
            FloatingPanelController.shared.reconcile(model: state.panelLayout, appState: state)
        }
    }

    private var windowTitle: String {
        if let path = state.selectedFile {
            return (path as NSString).lastPathComponent
        }
        return "ImageGlass"
    }
}
