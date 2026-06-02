import SwiftUI
import ImageGlassCore

/// Minimal `@main` entry so the executable target links during local
/// development and CI. Other agents will replace the body with the real
/// viewer / panel composition; this file only exists to keep the build
/// green when running unit tests against `ImageGlassCore`.
@main
struct ImageGlassApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("ImageGlass") {
            VStack(spacing: 12) {
                Text("ImageGlass — scaffold")
                    .font(.headline)
                Text("Active scope: \(state.activeScopeName.isEmpty ? "—" : state.activeScopeName)")
                    .foregroundStyle(.secondary)
                Text("\(state.resolvedFiles.count) files resolved")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 400, minHeight: 200)
            .task { await state.bootstrap() }
        }
    }
}
