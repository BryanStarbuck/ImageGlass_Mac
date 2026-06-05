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
            // Left: design file panel inline. It MUST win width against the
            // viewer: the AppKit NSViewRepresentable canvas is greedy and
            // otherwise squeezes a fixed-width sibling to zero. `fixedSize` +
            // `layoutPriority` lock the 300pt column.
            HStack(spacing: 0) {
                DirectoryFilenamePanel(state: state)
                    .frame(width: 300)
                    .layoutPriority(1)
                Divider().overlay(IG.sidebarLineC)
                VStack(spacing: 0) {
                    ImageViewer(state: state, viewer: state.viewer)
                    statusBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)
                .clipped()   // AppKit canvas must not overdraw the panel column.
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
        .task {
            await state.bootstrap()
            // After settings load and the scope resolves, hand the main
            // viewer window to the multi-monitor state controller. See
            // docs/multi_monitor.mdx §5.1.
            WindowStateController.shared.bootstrap(appState: state)
            // Drain any Finder-supplied file URLs that arrived before SwiftUI
            // mounted (cold-launch Open With).
            AboutAppDelegate.registerListenerAndFlush()
            // The detached floating File Tree and the Second Viewer are now
            // opt-in (menu: View ▸ Show Floating File Tree / Show Second
            // Viewer). Auto-spawning extra windows on every cold launch just
            // clutters the screen.

            // These panels are rendered as inline chrome (the file panel in
            // the left column, the native window toolbar, and the slim status
            // bar at the bottom of the viewer). Hide the PanelHostView-docked
            // copies so the window isn't doubled with blank/redundant strips.
            // Clear the settings flags first so `reconcilePanelsWithSettings`
            // (which runs inside bootstrap and re-shows panels whose
            // `show_*` flag is true) does not undo the hides below.
            state.settings.layout.show_toolbar = false
            state.settings.layout.show_status_bar = false
            for id in [BuiltInPanelCatalog.filePanel.id,
                       BuiltInPanelCatalog.toolbar.id,
                       BuiltInPanelCatalog.statusBar.id] {
                if state.panelLayout.layout.isVisible(id) {
                    state.panelLayout.hidePanel(id)
                }
            }
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

    // MARK: - Status bar (design: app.jsx)

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let path = state.selectedFile {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(IG.text3C)
                Text((path as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                    .foregroundStyle(IG.textC)
                    .fixedSize()
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(IG.text3C)
            } else {
                Text("No selection").foregroundStyle(IG.text3C)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(IG.toolbarC)
        .overlay(alignment: .top) { Divider().overlay(IG.lineC) }
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
