import SwiftUI
import ImageGlassCore

/// Minimal root view — wires the current theme into tint and background.
/// The full panel/viewer composition is owned by other agents; this view
/// exists so the SwiftUI app target compiles and demonstrates the theme
/// surface from `ThemeStore` actually drives UI.
struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Text(state.selectedFile ?? "No image selected")
                .font(.system(.body, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(state.themeStore.currentTheme.colors.viewerBackgroundColor)

            HStack {
                Text("\(state.resolvedFiles.count) files")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("theme: \(state.themeStore.currentTheme.info.name)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(state.themeStore.currentTheme.colors.toolbarBackgroundColor)
        }
        .tint(state.themeStore.currentTheme.colors.accentColor)
        .preferredColorScheme(state.themeStore.currentTheme.preferredColorScheme)
        .task { await state.bootstrap() }
    }
}
