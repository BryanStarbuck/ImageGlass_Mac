import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageGlassCore

/// SwiftUI implementation of the Crop panel described in
/// `docs/crop.mdx` section 2.3. It binds to the shared `CropController`
/// and surfaces every control listed in the spec's panel-control reference
/// table (section 2.4) — aspect ratio popup, custom W:H, position/size
/// numeric fields, units toggle, grid mode, snap switches, presets row,
/// and the action buttons (Crop, Save As..., Copy, Reset, Cancel).
public struct CropPanel: View {
    @Bindable public var controller: CropController

    @State private var unitPercent: Bool = false
    @State private var aspectIndex: Int = 0
    @State private var customW: String = "16"
    @State private var customH: String = "9"

    public init(controller: CropController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            aspectSection
            positionSection
            sizeSection
            Divider()
            gridSection
            Divider()
            presetRow
            Divider()
            actionRow
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 260)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: syncFromController)
        .onChange(of: controller.aspectRatio) { _, _ in syncFromController() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "crop")
            Text("Crop")
                .font(.headline)
            Spacer()
            if let path = controller.imagePath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aspectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aspect Ratio").font(.caption).foregroundStyle(.secondary)
            Picker("Aspect Ratio", selection: $aspectIndex) {
                ForEach(0..<AspectRatio.presets.count, id: \.self) { idx in
                    Text(AspectRatio.presets[idx].description).tag(idx)
                }
            }
            .labelsHidden()
            .onChange(of: aspectIndex) { _, newValue in
                controller.aspectRatio = AspectRatio.presets[newValue]
                pushCustom()
                applyAspectRatioToSelection()
            }
            if case .custom = controller.aspectRatio {
                HStack {
                    Text("Custom W:H").font(.caption)
                    TextField("W", text: $customW)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pushCustom)
                    Text(":")
                    TextField("H", text: $customH)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pushCustom)
                }
            }
            Toggle("Lock aspect ratio", isOn: $controller.lockAspect)
                .font(.caption)
        }
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position").font(.caption).foregroundStyle(.secondary)
            HStack {
                LabeledNumberField(label: "X", value: positionBinding(\.x), enabled: controller.selection != nil)
                LabeledNumberField(label: "Y", value: positionBinding(\.y), enabled: controller.selection != nil)
                unitsToggle
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Size").font(.caption).foregroundStyle(.secondary)
            HStack {
                LabeledNumberField(label: "W", value: positionBinding(\.width), enabled: controller.selection != nil)
                LabeledNumberField(label: "H", value: positionBinding(\.height), enabled: controller.selection != nil)
            }
        }
    }

    private var unitsToggle: some View {
        Picker("Units", selection: $unitPercent) {
            Text("px").tag(false)
            Text("%").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 80)
        .labelsHidden()
    }

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grid").font(.caption).foregroundStyle(.secondary)
            Picker("Grid", selection: $controller.gridMode) {
                Text("None").tag(GridMode.none)
                Text("Rule of thirds").tag(GridMode.thirds)
                Text("Golden ratio").tag(GridMode.goldenRatio)
                Text("Diagonals").tag(GridMode.diagonals)
                Text("8×8 grid").tag(GridMode.grid8)
            }
            .labelsHidden()
            Toggle("Snap to pixel grid", isOn: $controller.snapToPixel).font(.caption)
            Toggle("Snap to edges (8 px gravity)", isOn: $controller.snapToEdges).font(.caption)
            Toggle("Remember selection across images", isOn: $controller.persistAcrossImages).font(.caption)
            Toggle("Lossless JPEG when possible", isOn: $controller.losslessJPEGWhenPossible).font(.caption)
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset selection").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("None")  { controller.applyPreset(.none) }
                Button("25%")   { controller.applyPreset(.percent(0.25)) }
                Button("50%")   { controller.applyPreset(.percent(0.50)) }
                Button("2/3")   { controller.applyPreset(.percent(2.0/3.0)) }
                Button("All")   { controller.applyPreset(.all) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Crop") { _ = try? controller.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.selection == nil)
                Button("Save As…") { presentSaveAs() }
                    .disabled(controller.selection == nil)
            }
            HStack {
                Button("Copy") { try? controller.copyToPasteboard() }
                    .disabled(controller.selection == nil)
                Button("Reset") { controller.reset() }
                Button("Cancel") { controller.reset() }
            }
        }
    }

    // MARK: - Bindings / helpers

    private func positionBinding(_ keyPath: WritableKeyPath<CropRect, Int>) -> Binding<Int> {
        Binding(
            get: { controller.selection?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                guard var sel = controller.selection else { return }
                sel[keyPath: keyPath] = newValue
                controller.setNumeric(
                    x: keyPath == \CropRect.x ? newValue : sel.x,
                    y: keyPath == \CropRect.y ? newValue : sel.y,
                    w: keyPath == \CropRect.width ? newValue : sel.width,
                    h: keyPath == \CropRect.height ? newValue : sel.height
                )
            }
        )
    }

    private func syncFromController() {
        if let idx = AspectRatio.presets.firstIndex(where: { aspectMatches($0, controller.aspectRatio) }) {
            aspectIndex = idx
        }
        customW = "\(controller.customAspectW)"
        customH = "\(controller.customAspectH)"
    }

    private func pushCustom() {
        if let w = Int(customW), let h = Int(customH), w > 0, h > 0 {
            controller.customAspectW = w
            controller.customAspectH = h
            if case .custom = controller.aspectRatio {
                controller.aspectRatio = .custom(w: w, h: h)
            }
            applyAspectRatioToSelection()
        }
    }

    /// Recompute the selection rectangle to match the active aspect ratio.
    private func applyAspectRatioToSelection() {
        guard controller.sourceWidth > 0, controller.sourceHeight > 0 else { return }
        guard let ratio = controller.effectiveRatio() else { return }
        let rect = CropRect.centeredRatio(
            w: ratio.w,
            h: ratio.h,
            sourceWidth: controller.sourceWidth,
            sourceHeight: controller.sourceHeight
        )
        controller.setSelection(rect)
    }

    private func aspectMatches(_ a: AspectRatio, _ b: AspectRatio) -> Bool {
        switch (a, b) {
        case (.free, .free):           return true
        case (.original, .original):   return true
        case (.custom, .custom):       return true
        case (.ratio(let w1, let h1), .ratio(let w2, let h2)):
            return w1 == w2 && h1 == h2
        default:
            return false
        }
    }

    private func presentSaveAs() {
        guard let path = controller.imagePath else { return }
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        let originalURL = URL(fileURLWithPath: path)
        let base = originalURL.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(base)-cropped.\(originalURL.pathExtension)"
        savePanel.allowedContentTypes = allowedTypes(forExtension: originalURL.pathExtension)
        if savePanel.runModal() == .OK, let url = savePanel.url {
            _ = try? controller.save(.init(outputURL: url, format: .auto))
        }
    }

    private func allowedTypes(forExtension ext: String) -> [UTType] {
        let utis: [UTType] = [.jpeg, .png, .heic, .tiff, .gif]
        return utis
    }
}

// MARK: - Reusable numeric field

private struct LabeledNumberField: View {
    let label: String
    @Binding var value: Int
    var enabled: Bool = true
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .disabled(!enabled)
                .onAppear { text = "\(value)" }
                .onChange(of: value) { _, newValue in
                    let s = "\(newValue)"
                    if text != s { text = s }
                }
                .onSubmit(commit)
        }
    }

    private func commit() {
        if let v = Int(text) {
            value = v
        } else {
            text = "\(value)"
        }
    }
}
