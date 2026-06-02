import SwiftUI
import ImageGlassCore

/// Built-in panel instances. Each one wraps a SwiftUI view inside an
/// `AnyView` and exposes the matching `PanelDescriptor` from
/// `ImageGlassCore.BuiltInPanelCatalog`. Spec §4.
///
/// Many of these are intentionally light. The point of this file is the
/// framework wiring — the deep per-panel UX lives in the panel's own
/// subsystem (file_panel = list_of_files.mdx, crop = crop.mdx, etc.).

// MARK: - file_panel (the directory/filename panel)

@MainActor
public struct FilePanel: ImageGlassPanel {
    public static let id = "file_panel"
    public let descriptor = BuiltInPanelCatalog.filePanel

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(DirectoryFilenamePanel(state: state))
    }
}

// MARK: - scope_editor

@MainActor
public struct ScopeEditorPanel: ImageGlassPanel {
    public static let id = "scope_editor"
    public let descriptor = BuiltInPanelCatalog.scopeEditor

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(ScopeEditorPanelView(state: state))
    }
}

private struct ScopeEditorPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scope: \(state.activeScopeName.isEmpty ? "—" : state.activeScopeName)")
                .font(.headline)
            if let scope = state.activeScope {
                if !scope.include.directories.isEmpty {
                    Section("Directories") {
                        ForEach(scope.include.directories, id: \.self) { dir in
                            Text(dir).font(.system(.body, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if !scope.include.extensions.isEmpty {
                    Text("Extensions: " + scope.include.extensions.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                if !scope.include.globs.isEmpty {
                    Text("Include: " + scope.include.globs.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                if !scope.exclude.globs.isEmpty {
                    Text("Exclude: " + scope.exclude.globs.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                Button("Re-evaluate") { Task { await state.reevaluateActive() } }
                    .buttonStyle(.borderless)
            } else {
                Text("No active scope.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - metadata

@MainActor
public struct MetadataPanel: ImageGlassPanel {
    public static let id = "metadata"
    public let descriptor = BuiltInPanelCatalog.metadata

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(MetadataPanelView(state: state))
    }
}

private struct MetadataPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Metadata").font(.headline)
            if let path = state.selectedFile {
                Text((path as NSString).lastPathComponent).font(.system(.body, design: .monospaced))
                Text(path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            } else {
                Text("Select an image to view metadata.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - histogram

@MainActor
public struct HistogramPanel: ImageGlassPanel {
    public static let id = "histogram"
    public let descriptor = BuiltInPanelCatalog.histogram

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(HistogramPanelView(state: state))
    }
}

private struct HistogramPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Histogram").font(.headline)
            Spacer()
            Text(state.selectedFile == nil
                 ? "Select an image."
                 : "Histogram for selected image (placeholder).")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - mcp_activity

@MainActor
public struct MCPActivityPanel: ImageGlassPanel {
    public static let id = "mcp_activity"
    public let descriptor = BuiltInPanelCatalog.mcpActivity

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(MCPActivityPanelView())
    }
}

private struct MCPActivityPanelView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("MCP Activity").font(.headline)
            Text("Live log of MCP tool calls appears here.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - gallery_strip

@MainActor
public struct GalleryStripPanel: ImageGlassPanel {
    public static let id = "gallery_strip"
    public let descriptor = BuiltInPanelCatalog.galleryStrip

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(GalleryStripPanelView(state: state))
    }
}

private struct GalleryStripPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.resolvedFiles, id: \.self) { path in
                    Button {
                        state.selectedFile = path
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "photo")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .foregroundStyle(.secondary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 10))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 96)
                        }
                        .padding(4)
                        .background(state.selectedFile == path ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - status_bar

@MainActor
public struct StatusBarPanel: ImageGlassPanel {
    public static let id = "status_bar"
    public let descriptor = BuiltInPanelCatalog.statusBar

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(StatusBarPanelView(state: state))
    }
}

private struct StatusBarPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("\(state.resolvedFiles.count) files")
                .foregroundStyle(.secondary)
            if let evaluatedAt = state.lastEvaluated {
                Text("· evaluated \(relative(evaluatedAt))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path = state.selectedFile {
                Text(path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - toolbar

@MainActor
public struct ToolbarPanel: ImageGlassPanel {
    public static let id = "toolbar"
    public let descriptor = BuiltInPanelCatalog.toolbar

    public init() {}

    public func content(state: AppState) -> AnyView {
        AnyView(ToolbarPanelView(state: state))
    }
}

private struct ToolbarPanelView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.selectPrevious()
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(state.resolvedFiles.isEmpty)
                .help("Previous image")
            Button {
                state.selectNext()
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(state.resolvedFiles.isEmpty)
                .help("Next image")
            Divider().frame(height: 16)
            Button {
                state.viewer.zoomIn()
            } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom in")
            Button {
                state.viewer.zoomOut()
            } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom out")
            Button {
                state.viewer.zoomToActual()
            } label: { Image(systemName: "1.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Actual size")
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - color_picker / frame_nav / crop / image_info / local_storage / plugins_log
// Stub panels (real implementations live in the linked subsystems).

@MainActor public struct ColorPickerPanel: ImageGlassPanel {
    public static let id = "color_picker"
    public let descriptor = BuiltInPanelCatalog.colorPicker
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Color picker", icon: "eyedropper"))
    }
}

@MainActor public struct FrameNavPanel: ImageGlassPanel {
    public static let id = "frame_nav"
    public let descriptor = BuiltInPanelCatalog.frameNav
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Page / frame navigator", icon: "rectangle.stack"))
    }
}

@MainActor public struct CropPanel: ImageGlassPanel {
    public static let id = "crop"
    public let descriptor = BuiltInPanelCatalog.crop
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Crop", icon: "crop"))
    }
}

@MainActor public struct ImageInfoPanel: ImageGlassPanel {
    public static let id = "image_info"
    public let descriptor = BuiltInPanelCatalog.imageInfo
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Image info", icon: "info.bubble"))
    }
}

@MainActor public struct LocalStoragePanel: ImageGlassPanel {
    public static let id = "local_storage"
    public let descriptor = BuiltInPanelCatalog.localStorage
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Local storage", icon: "externaldrive"))
    }
}

@MainActor public struct PluginsLogPanel: ImageGlassPanel {
    public static let id = "plugins_log"
    public let descriptor = BuiltInPanelCatalog.pluginsLog
    public init() {}
    public func content(state: AppState) -> AnyView {
        AnyView(StubPanelBody(title: "Plugins log", icon: "ladybug"))
    }
}

private struct StubPanelBody: View {
    let title: String
    let icon: String
    var body: some View {
        VStack {
            Image(systemName: icon).font(.title)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text("Placeholder — populated by the panel's own subsystem.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Registration

public extension PanelRegistry {
    /// Register every built-in panel. Called once at app launch.
    @MainActor
    func registerBuiltInPanels() {
        register(ToolbarPanel())
        register(StatusBarPanel())
        register(GalleryStripPanel())
        register(ColorPickerPanel())
        register(FrameNavPanel())
        register(CropPanel())
        register(ImageInfoPanel())
        register(FilePanel())
        register(ScopeEditorPanel())
        register(MetadataPanel())
        register(HistogramPanel())
        register(MCPActivityPanel())
        register(LocalStoragePanel())
        register(PluginsLogPanel())
    }
}
