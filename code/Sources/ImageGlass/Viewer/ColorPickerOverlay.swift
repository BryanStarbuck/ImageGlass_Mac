import SwiftUI
import ImageGlassCore

/// Tiny readout that follows mouse hovers when the color picker is on.
/// Shows the active color format (HEX, RGBA, HSL, ...) — togglable via the
/// View > Color Picker Format menu. The format picker is also surfaced
/// inline so the user can cycle without leaving the canvas.
struct ColorPickerOverlay: View {
    let pixel: CGPoint?
    let color: RGBA?
    @Binding var format: ColorFormat

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
                    Text(ColorFormatting.format(color, as: format))
                    Text("(\(Int(pixel.x)), \(Int(pixel.y)))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
                Picker("", selection: $format) {
                    ForEach(ColorFormat.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                .help("Color format")
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
}
