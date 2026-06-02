import SwiftUI
import AppKit
import ImageGlassCore

/// Renders a `PanelLayoutModel` as a multi-dock window layout. Spec §8.1
/// recommends an `NSSplitViewController` for the production fork; this
/// SwiftUI implementation is the same composition expressed with
/// `HSplitView`/`VSplitView`/`HStack`/`VStack` so the framework is fully
/// usable now while the AppKit bridge for snap-and-drag is built out.
///
/// Structure:
/// ```
/// VStack
///   top group          (if present)
///   HSplitView
///     left group       (if present)
///     viewer + centerOverlay
///     right group      (if present)
///   bottom group       (if present)
/// ```
@MainActor
struct PanelHostView<Center: View>: View {
    @Bindable var state: AppState
    @Bindable var model: PanelLayoutModel
    let center: () -> Center

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
                    Divider()
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
                    Divider()
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
    }

    // MARK: - Group lookup

    private func group(at position: DockPosition) -> TabGroup? {
        model.layout.groups.first { $0.position == position }
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
            onClose:        { model.hidePanel(activeID) },
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

/// Floating panels presented as transient `NSPanel`s. SwiftUI counterpart of
/// spec §5.4. Each `FloatingPanel` from the layout is materialized into one
/// `NSPanel` and disposed of when it leaves the layout.
@MainActor
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private var windows: [String: NSPanel] = [:]
    private weak var appState: AppState?
    private weak var model: PanelLayoutModel?

    func reconcile(model: PanelLayoutModel, appState: AppState) {
        self.appState = appState
        self.model = model
        let liveIDs = Set(model.layout.floating.map { $0.id })

        // Close windows for panels that are no longer floating.
        for (id, panel) in windows where !liveIDs.contains(id) {
            panel.close()
            windows.removeValue(forKey: id)
        }
        // Open windows for newly floating panels.
        for f in model.layout.floating where windows[f.id] == nil {
            present(floating: f, model: model, appState: appState)
        }
    }

    private func present(floating: FloatingPanel, model: PanelLayoutModel, appState: AppState) {
        guard let panel = PanelRegistry.shared.panel(for: floating.id) else { return }
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
                onClose:        { [weak model] in model?.hidePanel(floating.id) },
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
