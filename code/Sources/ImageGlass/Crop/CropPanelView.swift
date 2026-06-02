import SwiftUI
import AppKit
import ImageGlassCore

/// SwiftUI panel hosting the numeric / preset controls
/// (`docs/crop.mdx §2.3`). Designed to sit either docked in the panel
/// column or floating in a small NSPanel; preferredSize is 280 × 360 pt.
struct CropPanelView: View {
    @Bindable var controller: CropController
    var preferredSize: CGSize = CGSize(width: 280, height: 360)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            aspectControls
            Divider()
            rectControls
            Divider()
            optionsControls
            Spacer(minLength: 4)
            actionButtons
        }
        .padding(12)
        .frame(width: preferredSize.width)
        .frame(minHeight: preferredSize.height, alignment: .topLeading)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Crop").font(.headline)
            Spacer()
            Button(action: { controller.cancel() }) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close crop tool (Esc)")
        }
    }

    private var aspectControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aspect Ratio").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $controller.aspectRatio) {
                ForEach(SelectionAspectRatio.allCases, id: \.self) { a in
                    Text(a.displayName).tag(a)
                }
            }
            .labelsHidden()
            HStack {
                Text("Custom").font(.caption).foregroundStyle(.secondary)
                TextField("W", value: Binding(
                    get: { controller.aspectRatioValues.indices.contains(0) ? controller.aspectRatioValues[0] : 0 },
                    set: { v in
                        if controller.aspectRatioValues.count < 2 { controller.aspectRatioValues = [0, 0] }
                        controller.aspectRatioValues[0] = max(0, v)
                    }
                ), formatter: NumberFormatter())
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.aspectRatio != .custom)
                Text(":")
                TextField("H", value: Binding(
                    get: { controller.aspectRatioValues.indices.contains(1) ? controller.aspectRatioValues[1] : 0 },
                    set: { v in
                        if controller.aspectRatioValues.count < 2 { controller.aspectRatioValues = [0, 0] }
                        controller.aspectRatioValues[1] = max(0, v)
                    }
                ), formatter: NumberFormatter())
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.aspectRatio != .custom)
                Toggle("Lock", isOn: $controller.lockAspect).toggleStyle(.checkbox)
            }
        }
    }

    private var rectControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Selection").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $controller.unitsDisplay) {
                    Text("px").tag(CropUnits.pixels)
                    Text("%").tag(CropUnits.percent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 70)
            }
            HStack(spacing: 4) {
                rectField(label: "X", value: rectBinding(.minX))
                rectField(label: "Y", value: rectBinding(.minY))
            }
            HStack(spacing: 4) {
                rectField(label: "W", value: rectBinding(.width))
                rectField(label: "H", value: rectBinding(.height))
            }
            HStack {
                Picker("Grid", selection: $controller.gridMode) {
                    Text("None").tag(CropGridMode.none)
                    Text("Thirds").tag(CropGridMode.thirds)
                    Text("Golden Ratio").tag(CropGridMode.goldenRatio)
                    Text("Golden Spiral").tag(CropGridMode.goldenSpiralDiagonals)
                    Text("8 × 8").tag(CropGridMode.grid8)
                }
                .pickerStyle(.menu)
            }
            Toggle("Snap to grid", isOn: $controller.snapToGrid).toggleStyle(.checkbox)
            Toggle("Persistent selection", isOn: $controller.persistent).toggleStyle(.checkbox)
        }
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Output", selection: $controller.outputFormat) {
                Text("Auto").tag(CropOutputFormat.auto)
                Text("JPEG").tag(CropOutputFormat.jpeg)
                Text("PNG").tag(CropOutputFormat.png)
                Text("WebP").tag(CropOutputFormat.webp)
                Text("HEIC").tag(CropOutputFormat.heic)
                Text("AVIF").tag(CropOutputFormat.avif)
                Text("TIFF").tag(CropOutputFormat.tiff)
            }
            if showsQualitySlider {
                HStack {
                    Text("Quality").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(controller.outputQuality) },
                        set: { controller.outputQuality = max(1, min(100, Int($0))) }
                    ), in: 1...100)
                    Text("\(controller.outputQuality)").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            Toggle("Lossless JPEG (MCU-aligned)", isOn: $controller.preferLossless).toggleStyle(.checkbox)
            Toggle("Preserve metadata", isOn: $controller.preserveMetadata).toggleStyle(.checkbox)
            Toggle("Strip GPS on Save As", isOn: $controller.stripGPS).toggleStyle(.checkbox)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Crop") { do { _ = try controller.applyAndReplace() } catch { presentError(error) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                Button("Save")   { do { _ = try controller.applySaveInPlace() } catch { presentError(error) } }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Save As…") { do { _ = try controller.applySaveAs() } catch { presentError(error) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            HStack {
                Button("Copy")  { do { try controller.copyToClipboard() } catch { presentError(error) } }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("Reset") { controller.resetSelection() }
                Spacer()
            }
        }
        .controlSize(.regular)
    }

    // MARK: - Helpers

    private var showsQualitySlider: Bool {
        switch controller.outputFormat {
        case .png, .tiff: return false
        default: return true
        }
    }

    private func rectField(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).frame(width: 14, alignment: .leading)
            TextField("", value: value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
        }
    }

    /// Binding into one component of the controller's rect, expressed
    /// in display units (px or %). Writing replaces the rect.
    private func rectBinding(_ field: RectField) -> Binding<Double> {
        Binding<Double>(
            get: {
                let r = controller.rect ?? .zero
                let raw: CGFloat
                switch field {
                case .minX:   raw = r.minX
                case .minY:   raw = r.minY
                case .width:  raw = r.width
                case .height: raw = r.height
                }
                return Double(displayValue(raw, axis: field.axis))
            },
            set: { newVal in
                var r = controller.rect ?? CGRect(origin: .zero, size: controller.activeImageSize)
                let asPixels = CGFloat(pixelValue(newVal, axis: field.axis))
                switch field {
                case .minX:   r.origin.x = asPixels
                case .minY:   r.origin.y = asPixels
                case .width:  r.size.width = max(1, asPixels)
                case .height: r.size.height = max(1, asPixels)
                }
                controller.setRect(CropMath.clip(r, to: controller.activeImageSize))
            }
        )
    }

    private enum RectField {
        case minX, minY, width, height
        var axis: Axis2 { (self == .minX || self == .width) ? .x : .y }
    }
    private enum Axis2 { case x, y }

    private func displayValue(_ px: CGFloat, axis: Axis2) -> CGFloat {
        guard controller.unitsDisplay == .percent else { return px }
        let denom = axis == .x ? controller.activeImageSize.width : controller.activeImageSize.height
        return denom > 0 ? (px / denom * 100) : px
    }

    private func pixelValue(_ display: Double, axis: Axis2) -> Double {
        guard controller.unitsDisplay == .percent else { return display }
        let denom = axis == .x ? Double(controller.activeImageSize.width) : Double(controller.activeImageSize.height)
        return denom > 0 ? (display / 100.0 * denom) : display
    }

    private func presentError(_ error: Error) {
        ErrorLog.log("crop action failed", error: error, class: "CropPanelView")
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
