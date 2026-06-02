import SwiftUI

/// Minimal SwiftUI app entry-point so the `ImageGlass` executable target
/// links. Other agents are filling in the real `ContentView`,
/// `ImageViewer`, and panel UI in parallel; this file just supplies the
/// `@main` symbol the Swift Package Manager build needs.
@main
struct ImageGlassApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            CropPanelHostView(state: state)
                .frame(minWidth: 720, minHeight: 480)
                .task { await state.bootstrap() }
        }
    }
}

/// Lightweight host view that surfaces the Crop panel + Crop overlay.
/// Replaceable by the broader ContentView landing later.
private struct CropPanelHostView: View {
    @Bindable var state: AppState

    var body: some View {
        HSplitView {
            CropOverlayHost(controller: state.cropController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CropPanel(controller: state.cropController)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        .navigationTitle(state.cropController.imagePath.map { ($0 as NSString).lastPathComponent } ?? "ImageGlass")
    }
}
