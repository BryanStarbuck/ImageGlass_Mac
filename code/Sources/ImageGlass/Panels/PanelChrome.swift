import SwiftUI
import ImageGlassCore

/// Shared chrome wrapped around every panel's content view. Provides the
/// drag-handle header (with title + icon), the close button, the float/dock
/// toggle, the "Move to →" context menu, and the tab strip when the panel
/// lives in a multi-panel `TabGroup`. Spec §3.3, §5.2, §5.4, §5.5.
@MainActor
struct PanelChrome<Content: View>: View {
    let panelID: String
    let title: String
    let icon: String
    let supportsFloating: Bool
    let isFloating: Bool
    let tabGroup: TabGroup?
    let onClose: () -> Void
    let onToggleFloat: () -> Void
    let onMove: (DockPosition) -> Void
    let onActivateTab: (String) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            if let g = tabGroup, g.panelIDs.count > 1 {
                tabStrip(g)
            }
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.subheadline).bold()
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Menu {
                Button("Move to → Left")          { onMove(.left) }
                Button("Move to → Right")         { onMove(.right) }
                Button("Move to → Top")           { onMove(.top) }
                Button("Move to → Bottom")        { onMove(.bottom) }
                if supportsFloating {
                    Divider()
                    Button(isFloating ? "Dock" : "Float") { onToggleFloat() }
                }
                Divider()
                Button("Hide") { onClose() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Hide \(title)")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    private func tabStrip(_ group: TabGroup) -> some View {
        HStack(spacing: 0) {
            ForEach(group.panelIDs, id: \.self) { pid in
                let isActive = group.panelIDs[group.activeIndex] == pid
                Button {
                    onActivateTab(pid)
                } label: {
                    Text(BuiltInPanelCatalog.descriptor(for: pid)?.title ?? pid)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.bar.opacity(0.6))
    }
}
