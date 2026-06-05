import SwiftUI
import AppKit
import ImageGlassCore

/// Root SwiftUI view for the File List Panel. Spec §4.1.
///
/// Composition:
///   ┌──────────────────────────────────┐
///   │ toolbar (FileListToolbarView)    │
///   ├──────────────────────────────────┤
///   │ mode-specific body               │
///   ├──────────────────────────────────┤
///   │ footer (item / selection count)  │
///   └──────────────────────────────────┘
public struct FileListPanelView: View {

    @Bindable var model: FileListViewModel
    let onRefresh: () -> Void
    let onEditScope: () -> Void
    let onPickScope: () -> Void

    public init(
        model: FileListViewModel,
        onRefresh: @escaping () -> Void = {},
        onEditScope: @escaping () -> Void = {},
        onPickScope: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onRefresh = onRefresh
        self.onEditScope = onEditScope
        self.onPickScope = onPickScope
    }

    public var body: some View {
        VStack(spacing: 0) {
            FileListToolbarView(
                model: model,
                onRefresh: onRefresh,
                onEditScope: onEditScope,
                onPickScope: onPickScope
            )
            Divider()
            modeBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(.regularMaterial)
        .focusable()
        .onKeyPress(action: handleKey)
    }

    @ViewBuilder
    private var modeBody: some View {
        switch model.viewMode {
        case .strip:   FileListStripView(model: model)
        case .grid:    FileListGridView(model: model)
        case .details: FileListDetailsView(model: model)
        case .tree:    FileListTreeView(model: model)
        case .column:  FileListColumnView(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleEntries.count) item\(model.visibleEntries.count == 1 ? "" : "s")")
            if !model.selectionState.selected.isEmpty {
                Text("·")
                Text("\(model.selectionState.selected.count) selected")
            }
            Spacer()
            Text(modeFooterText())
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(.secondary)
    }

    private func modeFooterText() -> String {
        "\(model.viewMode.label) · \(model.sortDescriptor.field.label) \(model.sortDescriptor.direction == .ascending ? "↑" : "↓")"
    }

    // MARK: - Keyboard

    /// Implements spec §4.5 key bindings.
    /// Note: this is best-effort — full multi-mode focus tracking (arrow keys
    /// in Grid moving up/down a row vs. left/right inside a row) is handled
    /// inside the per-mode views in the production fork. The bindings here
    /// cover the panel-level shortcuts.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "FileTree.FocusChange",
            extra: [
                ("key", String(describing: press.key)),
                ("source", "keypress"),
            ]
        )
        defer { _trace.finish() }
        switch press.key {
        case .leftArrow:
            model.moveFocus(by: -1, extending: press.modifiers.contains(.shift))
            return .handled
        case .rightArrow:
            model.moveFocus(by: 1, extending: press.modifiers.contains(.shift))
            return .handled
        case .upArrow where model.viewMode != .strip:
            model.moveFocus(by: -gridRowStride(), extending: press.modifiers.contains(.shift))
            return .handled
        case .downArrow where model.viewMode != .strip:
            model.moveFocus(by: gridRowStride(), extending: press.modifiers.contains(.shift))
            return .handled
        case .home:
            model.moveFocus(by: -model.visibleEntries.count, extending: press.modifiers.contains(.shift))
            return .handled
        case .end:
            model.moveFocus(by: model.visibleEntries.count, extending: press.modifiers.contains(.shift))
            return .handled
        case .return:
            if let f = model.selectionState.focused { model.click(f) }
            return .handled
        case .escape:
            model.clearSelection()
            return .handled
        default: break
        }
        // Number keys 1–5 for view mode.
        if press.characters == "1" { model.setViewMode(.strip);   return .handled }
        if press.characters == "2" { model.setViewMode(.grid);    return .handled }
        if press.characters == "3" { model.setViewMode(.details); return .handled }
        if press.characters == "4" { model.setViewMode(.tree);    return .handled }
        if press.characters == "5" { model.setViewMode(.column);  return .handled }
        // Cmd+A
        if press.modifiers.contains(.command) && press.characters == "a" {
            model.selectAll()
            return .handled
        }
        return .ignored
    }

    /// Best-effort row stride for Grid up/down. Uses a constant fallback
    /// (6) when SwiftUI doesn't surface the rendered column count to us.
    private func gridRowStride() -> Int {
        // Heuristic: in Strip mode left/right is enough. In Details/Tree
        // a single-line row is the visual row. In Grid we approximate 6.
        switch model.viewMode {
        case .grid:    return 6
        case .details: return 1
        case .tree:    return 1
        case .column:  return 1
        case .strip:   return 1
        }
    }
}
