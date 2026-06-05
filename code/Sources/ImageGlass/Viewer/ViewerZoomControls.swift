import SwiftUI
import ImageGlassCore

/// Floating glass zoom-control cluster, centered near the bottom of the
/// canvas. Mirrors the Claude Design handoff (`canvas.jsx`): a translucent
/// rounded bar with fit / 100% / fill, zoom −/+, a zoom-mode menu readout,
/// and rotate / flip. Auto-hides when the pointer is idle over the canvas.
struct ViewerZoomControls: View {
    @Bindable var viewer: ViewerState

    /// Driven by the parent — fades the cluster out when the pointer is idle.
    var visible: Bool

    private static let zoomModes: [ZoomMode] = [.auto, .fit, .fill, .width, .height, .lock]

    var body: some View {
        HStack(spacing: 2) {
            iconButton("arrow.down.right.and.arrow.up.left", help: "Scale to Fit",
                       on: viewer.zoomMode == .fit) { viewer.zoomMode = .fit }
            textButton("100%", help: "Actual Size (100%)", width: 44) { viewer.zoomToActual() }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Scale to Fill",
                       on: viewer.zoomMode == .fill) { viewer.zoomMode = .fill }

            divider

            iconButton("minus", help: "Zoom Out") { viewer.zoomOut() }
            zoomReadout
            iconButton("plus", help: "Zoom In") { viewer.zoomIn() }

            divider

            iconButton("rotate.right", help: "Rotate") { viewer.rotateClockwise() }
            iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                       help: "Flip Horizontal", on: viewer.flipHorizontal) {
                viewer.toggleFlipHorizontal()
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(IG.glassLineC, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 14)
        .animation(.easeOut(duration: 0.25), value: visible)
    }

    // MARK: - Pieces

    private var divider: some View {
        Rectangle()
            .fill(IG.glassLineC)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var zoomReadout: some View {
        Menu {
            ForEach(Self.zoomModes, id: \.self) { m in
                Button {
                    if m == .lock { /* keep current lockedZoom */ }
                    viewer.zoomMode = m
                } label: {
                    if viewer.zoomMode == m { Label(m.label, systemImage: "checkmark") }
                    else { Text(m.label) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(readoutText)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(IG.textC)
            .frame(minWidth: 52, minHeight: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var readoutText: String {
        switch viewer.zoomMode {
        case .lock: return "\(Int((viewer.lockedZoom * 100).rounded()))%"
        case .fit:  return "Fit"
        case .fill: return "Fill"
        case .auto: return "Auto"
        case .width: return "Width"
        case .height: return "Height"
        }
    }

    // MARK: - Buttons

    private func iconButton(_ symbol: String, help: String, on: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(on ? Color.white : IG.textC)
                .background(on ? IG.accentC : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ label: String, help: String, width: CGFloat,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: width, height: 30)
                .foregroundStyle(IG.textC)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
