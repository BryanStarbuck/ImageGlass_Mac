import SwiftUI
import AppKit
import Combine
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState

    // Tracks the macOS appearance setting. When the user toggles Light /
    // Dark in System Settings, SwiftUI republishes this value and the
    // `onChange` below forwards it to `ThemeStore` so the effective theme
    // recomputes automatically.
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        PanelHostView(state: state, model: state.panelLayout) {
            VStack(spacing: 0) {
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
        }
        .navigationTitle(windowTitle)
        .tint(state.themeStore.currentTheme.colors.accentColor)
        .preferredColorScheme(state.themeStore.appearanceMode.preferredColorScheme)
        .task {
            await state.bootstrap()
            // After settings load and the scope resolves, hand the main
            // viewer window to the multi-monitor state controller. See
            // docs/multi_monitor.mdx §5.1.
            WindowStateController.shared.bootstrap(appState: state)
            // Drain any Finder-supplied file URLs that arrived before SwiftUI
            // mounted (cold-launch Open With).
            AboutAppDelegate.registerListenerAndFlush()
        }
        .onAppear {
            state.themeStore.updateSystemColorScheme(SystemColorScheme(systemColorScheme))
            applyAppAppearance(state.themeStore.appearanceMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageGlassOpenURLs)) { note in
            guard let urls = note.userInfo?["urls"] as? [URL] else { return }
            for url in urls { state.openExternalFile(url: url) }
        }
        .onChange(of: systemColorScheme) { _, newScheme in
            state.themeStore.updateSystemColorScheme(SystemColorScheme(newScheme))
        }
        .onChange(of: state.themeStore.appearanceMode) { _, newMode in
            applyAppAppearance(newMode)
        }
        .onChange(of: state.panelLayout.layout.floating) { _, _ in
            FloatingPanelController.shared.reconcile(model: state.panelLayout, appState: state)
        }
        .toolbar {
            // docs/panels.mdx §5.6.1 — the title-bar sidebar toggle.
            // Drives `togglePanel("file_panel")` directly and reads its
            // selected state from `layout.isVisible(...)` so the button
            // can never drift from what is actually on the canvas.
            ToolbarItem(placement: .navigation) {
                let filePanelID = BuiltInPanelCatalog.filePanel.id
                let isShown = state.panelLayout.layout.isVisible(filePanelID)
                Button {
                    state.toggleByUser(panelID: filePanelID, asPrimary: true)
                } label: {
                    Image(systemName: "sidebar.left")
                        .symbolVariant(isShown ? .none : .fill)
                }
                .help(isShown ? "Hide file panel" : "Show file panel")
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
