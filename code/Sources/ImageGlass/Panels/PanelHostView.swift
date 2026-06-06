import SwiftUI
import AppKit
import ImageGlassCore

/// Renders a `PanelLayoutModel` as a multi-dock window layout. Spec §8.1
/// recommends an `NSSplitViewController` for the production fork; this
/// SwiftUI implementation gives the same shape via explicit widths +
/// `ResizableDivider` so the user gets a real draggable gripper bar
/// between the left file panel and the image viewer (the spec's
/// "gripper gap" from CLAUDE.md / dir_ui.mdx). Every drag persists the
/// new size to `layout.json` via `model.setSize`.
///
/// Structure:
/// ```
/// VStack
///   top group              (if present)
///   HStack
///     left group           (if present)  fixed width = g.size
///     ResizableDivider     (if present)  draggable; persists g.size
///     center + overlay     fills remainder
///     ResizableDivider     (if right present)
///     right group          (if present)  fixed width = g.size
///   bottom group           (if present)
/// ```
///
/// The full window + per-panel + viewer geometry is appended to
/// `log.log` on every layout pass via `WindowGeometryReporter` so the
/// "the bar does not show" bug can be diagnosed from outside the app.
@MainActor
struct PanelHostView<Center: View>: View {
    @Bindable var state: AppState
    @Bindable var model: PanelLayoutModel
    let center: () -> Center

    /// Minimum draggable width for the left and right panels. Below
    /// this, the divider snaps and hides the panel via `hideByUser`.
    private let dragSnapMin: CGFloat = 160
    /// Maximum draggable width.
    private let dragMaxFraction: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 0) {
            if let g = group(at: .top) {
                groupView(g)
                    .frame(height: g.size ?? 44)
                Divider()
            }
            HStack(spacing: 0) {
                if let g = group(at: .left) {
                    groupView(g)
                        .frame(width: g.size ?? 280)
                    ResizableDivider(
                        orientation: .vertical,
                        onDrag: { delta in
                            let current = g.size ?? 280
                            let proposed = current + delta
                            if proposed < dragSnapMin {
                                // Snap closed; persist explicit hide.
                                state.hideByUser(panelID: g.panelIDs[g.activeIndex])
                            } else {
                                model.setSize(panelID: g.panelIDs[g.activeIndex],
                                              size: proposed)
                            }
                        }
                    )
                }
                ZStack {
                    center()
                    if let g = group(at: .centerOverlay) {
                        groupView(g)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let g = group(at: .right) {
                    ResizableDivider(
                        orientation: .vertical,
                        onDrag: { delta in
                            let current = g.size ?? 320
                            let proposed = current - delta
                            if proposed < dragSnapMin {
                                state.hideByUser(panelID: g.panelIDs[g.activeIndex])
                            } else {
                                model.setSize(panelID: g.panelIDs[g.activeIndex],
                                              size: proposed)
                            }
                        }
                    )
                    groupView(g)
                        .frame(width: g.size ?? 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let g = group(at: .bottom) {
                Divider()
                groupView(g)
                    .frame(height: g.size ?? 120)
            }
        }
        .background(
            // Attaches the geometry reporter to the hosting NSWindow
            // once it is mounted. A zero-sized view that never draws.
            WindowGeometryAttach(state: state)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
        )
        .onChange(of: model.layout.groups.first { $0.position == .left }?.size) { _, _ in
            WindowGeometryReporter.shared.logCurrent(reason: "panel.resize")
        }
        .onChange(of: model.layout.isVisible(BuiltInPanelCatalog.filePanel.id)) { _, _ in
            WindowGeometryReporter.shared.logCurrent(reason: "panel.visibility")
        }
    }

    // MARK: - Group lookup

    private func group(at position: DockPosition) -> TabGroup? {
        guard var g = model.layout.groups.first(where: { $0.position == position })
        else { return nil }
        // Drop panels rendered as inline chrome (file panel) so the dock
        // never shows a duplicate of the inline left column.
        g.panelIDs.removeAll { FloatingPanelController.inlineSuppressedIDs.contains($0) }
        if g.panelIDs.isEmpty { return nil }
        if g.activeIndex >= g.panelIDs.count { g.activeIndex = 0 }
        return g
    }

    // MARK: - Render

    private func groupView(_ group: TabGroup) -> some View {
        let activeID = group.panelIDs.indices.contains(group.activeIndex)
            ? group.panelIDs[group.activeIndex]
            : group.panelIDs.first ?? ""
        return PanelChrome(
            panelID: activeID,
            title: PanelRegistry.shared.panel(for: activeID)?.descriptor.title ?? activeID,
            icon:  PanelRegistry.shared.panel(for: activeID)?.descriptor.icon ?? "square",
            supportsFloating: PanelRegistry.shared.panel(for: activeID)?.descriptor.supportsFloating ?? true,
            isFloating: false,
            tabGroup: group,
            // Close routes through `state.hideByUser` so an explicit
            // user-close also persists to `settings.layout.show_*`
            // (docs/panels.mdx §5.6.1, CLAUDE.md fork contract).
            onClose:        { state.hideByUser(panelID: activeID) },
            onToggleFloat:  { model.toggleFloat(activeID) },
            onMove:         { newPos in model.movePanel(activeID, to: newPos) },
            onActivateTab:  { pid in model.activateTab(in: group.id, panel: pid) }
        ) {
            if let panel = PanelRegistry.shared.panel(for: activeID) {
                panel.content(state: state)
            } else {
                Text("Unknown panel '\(activeID)'")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: PanelRegistry.shared.panel(for: activeID)?.descriptor.minSize.width ?? 64,
               minHeight: PanelRegistry.shared.panel(for: activeID)?.descriptor.minSize.height ?? 32)
    }
}

/// A draggable divider that exposes a visible 1-point (3-point on hover)
/// gripper bar inside an 8-point invisible hit area. Reports the
/// *incremental* drag distance in points to the caller so the caller can
/// update the layout's `size` for the adjacent panel and persist it.
///
/// Used both by `PanelHostView` for docked panels (spec §5.3) and by
/// `ContentView` for the inline file-panel column (spec §5.3.1). The
/// hit area is ≥ 6 pt per the project brief; the visible bar is slim
/// so it does not steal pixels from the panel content.
@MainActor
struct ResizableDivider: View {
    enum Orientation { case vertical, horizontal }
    let orientation: Orientation
    /// Called with the *incremental* drag distance in points since
    /// the last update. Positive vertical delta = drag right;
    /// positive horizontal delta = drag down.
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGSize = .zero
    @State private var hovered: Bool = false

    var body: some View {
        ZStack {
            // Wide invisible hit area so the user can grab the
            // divider without aiming pixel-perfect. ≥ 6 pt — spec
            // §5.3.1.
            Color.clear
                .frame(
                    width: orientation == .vertical ? 8 : nil,
                    height: orientation == .horizontal ? 8 : nil
                )
                .contentShape(Rectangle())
            Rectangle()
                .fill(hovered ? Color.accentColor.opacity(0.6)
                              : Color(NSColor.separatorColor))
                .frame(
                    width: orientation == .vertical ? (hovered ? 3 : 1) : nil,
                    height: orientation == .horizontal ? (hovered ? 3 : 1) : nil
                )
        }
        .onHover { isOver in
            hovered = isOver
            if isOver {
                let cursor: NSCursor = orientation == .vertical
                    ? .resizeLeftRight : .resizeUpDown
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let delta = orientation == .vertical
                        ? g.translation.width  - lastTranslation.width
                        : g.translation.height - lastTranslation.height
                    lastTranslation = g.translation
                    onDrag(delta)
                }
                .onEnded { _ in
                    lastTranslation = .zero
                }
        )
    }
}

/// Floating panels presented as transient `NSPanel`s. SwiftUI counterpart of
/// spec §5.4. Each `FloatingPanel` from the layout is materialized into one
/// `NSPanel` and disposed of when it leaves the layout.
@MainActor
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private var windows: [String: NSPanel] = [:]
    private weak var appState: AppState?
    private weak var model: PanelLayoutModel?

    /// Panels rendered as inline chrome elsewhere (the file panel lives in
    /// ContentView's left column). They must never be materialized by the
    /// panel system — docked or floating — or the window shows a duplicate.
    static let inlineSuppressedIDs: Set<String> = ["file_panel"]

    func reconcile(model: PanelLayoutModel, appState: AppState) {
        self.appState = appState
        self.model = model
        let liveIDs = Set(model.layout.floating.map { $0.id })
            .subtracting(Self.inlineSuppressedIDs)

        // Close windows for panels that are no longer floating (or suppressed).
        for (id, panel) in windows where !liveIDs.contains(id) {
            panel.close()
            windows.removeValue(forKey: id)
        }
        // Open windows for newly floating panels.
        for f in model.layout.floating
        where windows[f.id] == nil && !Self.inlineSuppressedIDs.contains(f.id) {
            present(floating: f, model: model, appState: appState)
        }
    }

    private func present(floating: FloatingPanel, model: PanelLayoutModel, appState: AppState) {
        guard let panel = PanelRegistry.shared.panel(for: floating.id) else {
            ErrorLog.log("floating panel id '\(floating.id)' has no registered panel",
                         class: "FloatingPanelController")
            return
        }
        let nsPanel = NSPanel(
            contentRect: floating.frame,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        nsPanel.title = panel.descriptor.title
        nsPanel.level = .floating
        nsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        nsPanel.isMovableByWindowBackground = true
        nsPanel.isReleasedWhenClosed = false

        let host = NSHostingView(
            rootView: PanelChrome(
                panelID: floating.id,
                title: panel.descriptor.title,
                icon: panel.descriptor.icon,
                supportsFloating: panel.descriptor.supportsFloating,
                isFloating: true,
                tabGroup: nil,
                onClose:        { [weak appState] in appState?.hideByUser(panelID: floating.id) },
                onToggleFloat:  { [weak model] in model?.toggleFloat(floating.id) },
                onMove:         { [weak model] pos in model?.movePanel(floating.id, to: pos) },
                onActivateTab:  { _ in }
            ) {
                panel.content(state: appState)
            }
        )
        nsPanel.contentView = host
        nsPanel.orderFront(nil)
        windows[floating.id] = nsPanel
    }
}
