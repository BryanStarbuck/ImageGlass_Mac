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
            // The file panel is inline window chrome — it lives in the main
            // window's HStack next to the viewer rather than docked via
            // PanelHostView (FloatingPanelController.inlineSuppressedIDs
            // keeps the dock from materializing a duplicate). The 8 pt
            // grippable divider, the persisted width, and the docking
            // side are all driven by `state.panelLayout` so the inline
            // column and the panel framework cannot diverge — see
            // docs/panels.mdx §5.3.1 + docs/dir_ui.mdx §2.
            HStack(spacing: 0) {
                inlineLayoutContent
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
            // slideshow.mdx §3 — install the app-level bare-`S` monitor
            // so the slideshow toggles no matter where focus is (incl.
            // the "Filter files" text field, which otherwise swallows
            // the keystroke). Idempotent; only the first window installs.
            SlideshowHotkeyMonitor.shared.installIfNeeded(appState: state)
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

    // MARK: - Inline column layout (file panel + viewer + crop)

    /// Minimum draggable width for the inline file panel column.
    /// Below this, the splitter snaps and hides the panel via the
    /// same `hideByUser` path as `⌘L` / the title-bar button.
    /// Matches the snap-min the docked `PanelHostView` uses so the two
    /// resize surfaces feel identical (spec §5.3 / §5.3.1).
    private static let filePanelMinWidth: CGFloat = 160
    /// Default width on first show — matches `BuiltInPanelCatalog.filePanel`'s
    /// `preferredSize.width`. The fork's previous hardcoded 300pt column.
    private static let filePanelDefaultWidth: CGFloat = 300

    /// Builds the inline `HStack` content. Reorders the file panel and
    /// the viewer so the panel sits on whichever side the layout dock
    /// position calls for (.left, default — panel on the left; .right
    /// — panel on the right). The splitter is always on the side
    /// facing the viewer (spec §5.3.1).
    @ViewBuilder
    private var inlineLayoutContent: some View {
        let pos = inlineFilePanelPosition
        if pos == .left {
            filePanelColumn
            splitter(forLeftDock: true)
            viewerColumn
            cropTrailing
        } else if pos == .right {
            viewerColumn
            cropTrailing
            splitter(forLeftDock: false)
            filePanelColumn
        } else {
            // Panel hidden / floating / docked top|bottom|overlay —
            // the framework owns it elsewhere; show viewer + crop only.
            viewerColumn
            cropTrailing
        }
    }

    /// Returns `.left` / `.right` when the file panel is one of the two
    /// supported inline positions; `nil` for any other state (hidden,
    /// floating, top, bottom, centerOverlay). Only `.left` / `.right`
    /// render inline; everything else falls back to the dock so the
    /// inline chrome never duplicates the dock copy.
    private var inlineFilePanelPosition: DockPosition? {
        switch state.panelLayout.layout.position(of: BuiltInPanelCatalog.filePanel.id) {
        case .left:  return .left
        case .right: return .right
        default:     return nil
        }
    }

    /// Current persisted width of the inline file-panel column, with a
    /// 300 pt fallback the first time it is rendered. Reads the same
    /// `size` field from `layout.json` that the docked panels use, so
    /// the inline column and the framework cannot drift apart.
    private var inlineFilePanelWidth: CGFloat {
        let id = BuiltInPanelCatalog.filePanel.id
        if let g = state.panelLayout.layout.groups.first(where: { $0.panelIDs.contains(id) }),
           let size = g.size {
            return size
        }
        return Self.filePanelDefaultWidth
    }

    /// The file panel column. `layoutPriority(1)` is required because
    /// the AppKit `NSViewRepresentable` viewer canvas is a greedy
    /// sibling — without an explicit priority the canvas would
    /// squeeze the fixed-width column to zero. See spec §5.3.1.
    private var filePanelColumn: some View {
        DirectoryFilenamePanel(state: state)
            .frame(width: inlineFilePanelWidth)
            .layoutPriority(1)
    }

    /// Viewer column (canvas + bottom status strip). `.clipped()` is
    /// required so the canvas does not overdraw the file panel column
    /// during a divider drag.
    private var viewerColumn: some View {
        VStack(spacing: 0) {
            ImageViewer(state: state, viewer: state.viewer)
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(0)
        .clipped()
    }

    /// Crop panel — kept inline at the trailing edge of the viewer
    /// column when the crop tool is active. Same behavior as before
    /// the splitter refactor.
    @ViewBuilder
    private var cropTrailing: some View {
        if state.crop.isActive {
            Divider()
            CropPanelView(controller: state.crop)
                .background(.regularMaterial)
        }
    }

    /// The 8 pt grippable splitter. Mirrors the drag direction based
    /// on which side the file panel is docked: when on the left, drag
    /// right widens it; when on the right, drag right narrows it
    /// (because the handle is on the *left* edge of the panel).
    /// Snap-to-hide at `filePanelMinWidth` runs `hideByUser` so the
    /// `settings.layout.show_*` mirror and the audit log stay coherent
    /// with the `⌘L` / title-bar / MCP `hide_panel` code paths.
    @ViewBuilder
    private func splitter(forLeftDock isLeftDock: Bool) -> some View {
        let id = BuiltInPanelCatalog.filePanel.id
        ResizableDivider(orientation: .vertical) { delta in
            let current = inlineFilePanelWidth
            // When the panel is docked left, the handle is on its
            // right edge: positive delta widens it. When docked right,
            // the handle is on its left edge: positive delta narrows it.
            let proposed = isLeftDock ? current + delta : current - delta
            if proposed < Self.filePanelMinWidth {
                state.hideByUser(panelID: id)
            } else {
                state.panelLayout.setSize(panelID: id, size: proposed)
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
