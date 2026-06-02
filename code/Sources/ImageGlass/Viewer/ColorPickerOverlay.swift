import SwiftUI
import ImageGlassCore

/// Tiny readout that follows mouse hovers when the color picker is on.
/// Renders the sampled pixel's RGBA in three formats (HEX, RGBA, position).
struct ColorPickerOverlay: View {
    let pixel: CGPoint?
    let color: RGBA?

    var body: some View {
        if let color, let pixel {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(
                        red:   Double(color.r) / 255.0,
                        green: Double(color.g) / 255.0,
                        blue:  Double(color.b) / 255.0,
                        opacity: Double(color.a) / 255.0
                    ))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary.opacity(0.25))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(hex(color))
                    Text("rgba(\(color.r), \(color.g), \(color.b), \(color.a))")
                    Text("(\(Int(pixel.x)), \(Int(pixel.y)))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .padding(10)
        }
    }

    private func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, c.a)
    }
}
