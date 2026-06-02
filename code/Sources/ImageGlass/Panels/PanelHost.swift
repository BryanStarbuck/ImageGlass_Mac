import SwiftUI
import ImageGlassCore

/// The four-zone-plus-center panel host that replaces the previous
/// `NavigationSplitView`. SwiftUI-only first pass: HStack and VStack with
/// resizable splitters via `.frame(width:)` bindings. The spec calls for an
/// `NSSplitViewController` for production-grade divider drag; that AppKit
/// bridging lands in a follow-up — what we ship here is the framework
/// structure other agents can fill in, plus a working initial layout.
@MainActor
public struct PanelHost<Center: View>: View {

    @Bindable var controller: LayoutController
    let viewRegistry: PanelViewRegistry
    @ViewBuilder let center: () -> Center

    /// Live zone sizes, seeded from the active preset on appear.
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    public init(
        controller: LayoutController,
        viewRegistry: PanelViewRegistry? = nil,
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.controller = controller
        self.viewRegistry = viewRegistry ?? PanelViewRegistry.shared
        self.center = center
    }

    public var body: some View {
        VStack(spacing: 0) {
            if topHeight > 0 { topZone }
            HStack(spacing: 0) {
                if leftWidth > 0 { leftZone }
                center()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if rightWidth > 0 { rightZone }
            }
            if bottomHeight > 0 { bottomZone }
        }
        .onAppear { syncZoneSizesFromPreset() }
        .onChange(of: controller.activePresetId) { _, _ in syncZoneSizesFromPreset() }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            // Floating panels render as overlays inside the window for v1;
            // tearing them off into real NSPanels is a follow-up.
            ForEach(controller.floatingPanels(), id: \.id) { d in
                floatingPanel(d)
            }
        }
    }

    // MARK: - Zones

    private var leftZone: some View {
        zoneStack(at: .left)
            .frame(width: leftWidth)
            .overlay(alignment: .trailing) { verticalDivider }
    }

    private var rightZone: some View {
        zoneStack(at: .right)
            .frame(width: rightWidth)
            .overlay(alignment: .leading) { verticalDivider }
    }

    private var topZone: some View {
        zoneStack(at: .top)
            .frame(height: topHeight)
            .overlay(alignment: .bottom) { horizontalDivider }
    }

    private var bottomZone: some View {
        zoneStack(at: .bottom)
            .frame(height: bottomHeight)
            .overlay(alignment: .top) { horizontalDivider }
    }

    private var verticalDivider: some View {
        Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 1)
    }
    private var horizontalDivider: some View {
        Rectangle().fill(Color(NSColor.separatorColor)).frame(height: 1)
    }

    @ViewBuilder
    private func zoneStack(at position: PanelPosition) -> some View {
        let panels = controller.dockedPanels(at: position)
        if panels.isEmpty {
            Color.clear
        } else if let axis = position.stackAxis {
            switch axis {
            case .vertical:
                VStack(spacing: 0) {
                    ForEach(panels, id: \.id) { d in
                        panelChrome(d)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if d.id != panels.last?.id { Divider() }
                    }
                }
            case .horizontal:
                HStack(spacing: 0) {
                    ForEach(panels, id: \.id) { d in
                        panelChrome(d)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if d.id != panels.last?.id { Divider() }
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Panel chrome

    @ViewBuilder
    private func panelChrome(_ d: PanelDescriptor) -> some View {
        VStack(spacing: 0) {
            panelHeader(d)
            Divider()
            if let view = viewRegistry.makeView(for: d.id) {
                view
            } else {
                emptyPlaceholder(d)
            }
        }
    }

    private func panelHeader(_ d: PanelDescriptor) -> some View {
        HStack(spacing: 6) {
            Image(systemName: d.icon)
                .foregroundStyle(.secondary)
            Text(d.title)
                .font(.system(.caption, weight: .semibold))
            Spacer()
            if d.supportsFloating {
                Button {
                    Task { await controller.float(id: d.id) }
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Float panel")
            }
            Button {
                Task { await controller.hide(id: d.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide panel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func emptyPlaceholder(_ d: PanelDescriptor) -> some View {
        VStack(spacing: 6) {
            Image(systemName: d.icon).font(.title2).foregroundStyle(.secondary)
            Text(d.title).font(.callout).foregroundStyle(.secondary)
            Text("Not implemented yet").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func floatingPanel(_ d: PanelDescriptor) -> some View {
        VStack(spacing: 0) {
            panelHeader(d)
            Divider()
            if let view = viewRegistry.makeView(for: d.id) {
                view
            } else {
                emptyPlaceholder(d)
            }
        }
        .frame(
            width: controller.statesById[d.id]?.floatingFrame?.width ?? d.preferredSize.width,
            height: controller.statesById[d.id]?.floatingFrame?.height ?? d.preferredSize.height
        )
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8)
        .padding(.top, 40)
        .padding(.trailing, 16)
    }

    // MARK: - Zone-size seeding

    /// Pulls the per-zone size off the active preset and writes the four
    /// `@State` widths/heights. Called once on appear and again on preset
    /// switch.
    private func syncZoneSizesFromPreset() {
        let preset = controller.document.activePreset
        guard let window = preset.windows.first else {
            leftWidth = 0; rightWidth = 0; topHeight = 0; bottomHeight = 0
            return
        }
        leftWidth = CGFloat(window.zones.left.isEmpty ? 0 : window.zones.left.size)
        rightWidth = CGFloat(window.zones.right.isEmpty ? 0 : window.zones.right.size)
        topHeight = CGFloat(window.zones.top.isEmpty ? 0 : window.zones.top.size)
        bottomHeight = CGFloat(window.zones.bottom.isEmpty ? 0 : window.zones.bottom.size)
    }
}
