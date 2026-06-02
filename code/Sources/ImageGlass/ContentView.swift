import SwiftUI
import AppKit
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState
    @Bindable var layout: LayoutController

    // Tracks the macOS appearance setting. When the user toggles Light /
    // Dark in System Settings, SwiftUI republishes this value and the
    // `onChange` below forwards it to `ThemeStore` so the effective theme
    // recomputes automatically.
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        PanelHost(controller: layout) {
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
        .preferredColorScheme(state.themeStore.appearanceMode.preferredColorScheme)
        .task { await state.bootstrap() }
        .onAppear {
            state.themeStore.updateSystemColorScheme(SystemColorScheme(systemColorScheme))
            applyAppAppearance(state.themeStore.appearanceMode)
        }
        .onChange(of: systemColorScheme) { _, newScheme in
            state.themeStore.updateSystemColorScheme(SystemColorScheme(newScheme))
        }
        .onChange(of: state.themeStore.appearanceMode) { _, newMode in
            applyAppAppearance(newMode)
        }
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

    /// Propagate the appearance mode to `NSApp` so AppKit-owned chrome
    /// (About panel, Releases window, Slideshow, etc.) all follow the same
    /// light/dark setting. SwiftUI's `.preferredColorScheme` only affects
    /// the view it's attached to.
    private func applyAppAppearance(_ mode: ThemeAppearanceMode) {
        let appearance: NSAppearance?
        switch mode {
        case .light:  appearance = NSAppearance(named: .aqua)
        case .dark:   appearance = NSAppearance(named: .darkAqua)
        case .system: appearance = nil
        }
        NSApp.appearance = appearance
    }
}
