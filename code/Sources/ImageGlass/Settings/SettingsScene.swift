import SwiftUI
import ImageGlassCore

/// SwiftUI Settings scene that surfaces the spec-§2.3 sections. Uses a
/// `TabView` with one tab per page; each page is a `Form` of native
/// controls bound to `AppState.settings`.
///
/// Mutations are written back to disk through `AppState.saveSettings()`
/// debounced via a tiny dispatch. Settings is opened by the system Cmd+,
/// menu item that `SwiftUI.Settings` registers automatically.
public struct SettingsScene: View {

    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            ImageSettingsView(state: state)
                .tabItem { Label("Image", systemImage: "photo") }
            ViewerSettingsView(state: state)
                .tabItem { Label("Viewer", systemImage: "eye") }
            AppearanceSettingsView(state: state)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            LayoutSettingsView(state: state)
                .tabItem { Label("Layout", systemImage: "rectangle.3.group") }
            SlideshowSettingsView(state: state)
                .tabItem { Label("Slideshow", systemImage: "play.rectangle") }
            EditSettingsView(state: state)
                .tabItem { Label("Edit", systemImage: "pencil") }
            GallerySettingsView(state: state)
                .tabItem { Label("Gallery", systemImage: "square.grid.2x2") }
            ToolbarSettingsView(state: state)
                .tabItem { Label("Toolbar", systemImage: "square.stack") }
            AdvancedSettingsView(state: state)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640, height: 480)
        .onChange(of: state.settings) { _, _ in
            Task { await state.saveSettings() }
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Application") {
                Picker("Theme", selection: $state.settings.general.theme_override) {
                    Text("System").tag(ThemeOverride.system)
                    Text("Light").tag(ThemeOverride.light)
                    Text("Dark").tag(ThemeOverride.dark)
                }
                Picker("Check for updates", selection: $state.settings.general.update_cadence) {
                    Text("Never").tag(UpdateCadence.never)
                    Text("Daily").tag(UpdateCadence.daily)
                    Text("Weekly").tag(UpdateCadence.weekly)
                    Text("Monthly").tag(UpdateCadence.monthly)
                }
                Toggle("Show new version indicator", isOn: $state.settings.general.show_update_badge)
                Toggle("Show welcome image", isOn: $state.settings.general.show_welcome_image)
                Toggle("Show app icon in title bar", isOn: $state.settings.general.show_app_icon)
                Toggle("Open with last seen image", isOn: $state.settings.general.open_last_image)
            }
            Section("Window") {
                Toggle("Allow multiple instances", isOn: $state.settings.general.multi_instance)
                Toggle("Always on top", isOn: $state.settings.general.window_top_most)
                Toggle("Open in full screen", isOn: $state.settings.general.start_full_screen)
                Toggle("Frameless window", isOn: $state.settings.general.frameless)
                Toggle("Window fit to image", isOn: $state.settings.general.window_fit)
                Toggle("Center window-fit window", isOn: $state.settings.general.window_fit_centered)
                    .disabled(!state.settings.general.window_fit)
            }
            Section("Confirmations") {
                Toggle("Confirm before delete", isOn: $state.settings.general.confirm_delete)
                Toggle("Confirm before overwrite", isOn: $state.settings.general.confirm_overwrite)
                Toggle("Preserve modified date on save", isOn: $state.settings.general.preserve_modified_date)
                Toggle("Save As opens current directory", isOn: $state.settings.general.save_as_in_current_dir)
            }
            Section {
                Button("Restore Defaults") {
                    state.settings.general = GeneralSettings()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Image

private struct ImageSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Color management") {
                Picker("Color profile", selection: $state.settings.image.color_profile) {
                    Text("Current monitor").tag(ColorProfileChoice.currentMonitor)
                    Text("sRGB").tag(ColorProfileChoice.sRGB)
                    Text("Display P3").tag(ColorProfileChoice.displayP3)
                    Text("Adobe RGB").tag(ColorProfileChoice.adobeRGB)
                    Text("Custom").tag(ColorProfileChoice.custom)
                }
                Toggle("Apply to all formats", isOn: $state.settings.image.color_profile_all_formats)
            }
            Section("Decoding") {
                Toggle("Async loading", isOn: $state.settings.image.async_loading)
                Toggle("Embedded thumb for RAW", isOn: $state.settings.image.embedded_thumb_raw)
                Toggle("Embedded thumb for others", isOn: $state.settings.image.embedded_thumb_other)
                Stepper("Min thumb width: \(state.settings.image.embedded_thumb_min_width)",
                        value: $state.settings.image.embedded_thumb_min_width,
                        in: 0...10_000, step: 100)
                Stepper("Min thumb height: \(state.settings.image.embedded_thumb_min_height)",
                        value: $state.settings.image.embedded_thumb_min_height,
                        in: 0...10_000, step: 100)
            }
            Section("Interpolation") {
                Picker("Scale-down", selection: $state.settings.image.interp_scale_down) {
                    ForEach(Interpolation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Scale-up", selection: $state.settings.image.interp_scale_up) {
                    ForEach(Interpolation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Display") {
                Toggle("Image info overlay", isOn: $state.settings.image.info_overlay)
                Toggle("Checkerboard background", isOn: $state.settings.image.checkerboard)
                Toggle("Checkerboard image-only", isOn: $state.settings.image.checkerboard_image_only)
                    .disabled(!state.settings.image.checkerboard)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Viewer

private struct ViewerSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Zoom") {
                Picker("Default zoom mode", selection: $state.settings.viewer.zoom_mode) {
                    Text("Auto Zoom").tag(ZoomModeSetting.autoZoom)
                    Text("Lock Zoom").tag(ZoomModeSetting.lockZoom)
                    Text("Scale to Width").tag(ZoomModeSetting.scaleToWidth)
                    Text("Scale to Height").tag(ZoomModeSetting.scaleToHeight)
                    Text("Scale to Fit").tag(ZoomModeSetting.scaleToFit)
                    Text("Scale to Fill").tag(ZoomModeSetting.scaleToFill)
                    Text("100% (1:1)").tag(ZoomModeSetting.oneToOne)
                }
                HStack {
                    Text("Lock zoom %")
                    Slider(value: $state.settings.viewer.zoom_lock_percent, in: 10...800)
                    Text("\(Int(state.settings.viewer.zoom_lock_percent))%").monospacedDigit()
                }
                HStack {
                    Text("Zoom speed")
                    Slider(value: $state.settings.viewer.zoom_speed, in: 0...10)
                }
                HStack {
                    Text("Pan speed")
                    Slider(value: $state.settings.viewer.pan_speed, in: 1...200)
                }
            }
            Section("Trackpad & gestures") {
                Toggle("Pinch to zoom", isOn: $state.settings.viewer.gesture_pinch_zoom)
                Toggle("Two-finger pan", isOn: $state.settings.viewer.gesture_two_finger_pan)
                Toggle("Two-finger swipe to navigate", isOn: $state.settings.viewer.gesture_swipe_nav)
                Toggle("Smart magnify (double-tap)", isOn: $state.settings.viewer.gesture_smart_magnify)
                Toggle("Rotate gesture", isOn: $state.settings.viewer.gesture_rotate)
            }
            Section("Navigation") {
                Toggle("Loop back navigation", isOn: $state.settings.viewer.loop_navigation)
                Toggle("Auto-switch sibling directory", isOn: $state.settings.viewer.auto_switch_sibling_dir)
                Toggle("Recursive loading", isOn: $state.settings.viewer.recursive_loading)
                Toggle("Show hidden images", isOn: $state.settings.viewer.show_hidden_files)
                Toggle("Group by directory", isOn: $state.settings.viewer.group_by_dir)
                Toggle("Real-time file update", isOn: $state.settings.viewer.real_time_file_update)
                Toggle("Auto-open new added image", isOn: $state.settings.viewer.auto_open_new)
                Picker("Image order", selection: $state.settings.viewer.image_order) {
                    ForEach(ImageOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Direction", selection: $state.settings.viewer.image_order_direction) {
                    Text("Ascending").tag(SortDirection.asc)
                    Text("Descending").tag(SortDirection.desc)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Theme") {
                TextField("Light theme", text: $state.settings.appearance.light_theme)
                TextField("Dark theme", text: $state.settings.appearance.dark_theme)
            }
            Section("Window") {
                Picker("Window material", selection: $state.settings.appearance.window_material) {
                    ForEach(WindowMaterial.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Allow background drag", isOn: $state.settings.appearance.background_drag)
                Toggle("Show app icon in title bar", isOn: $state.settings.appearance.show_app_icon)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

private struct LayoutSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Layout preset") {
                TextField("Active preset", text: $state.settings.layout.active_preset)
            }
            Section("Default panels") {
                // Each toggle drives the on-disk `settings.layout.show_*`
                // boolean *and* the live `panelLayout`, so flipping a
                // toggle in Settings actually moves the panel on the
                // canvas instead of just saving a flag the runtime
                // ignores. The `.onChange` handlers route through
                // `reconcile` so the same code path as bootstrap
                // reconciliation is exercised. See docs/panels.mdx §6.5.
                Toggle("Show toolbar", isOn: $state.settings.layout.show_toolbar)
                    .onChange(of: state.settings.layout.show_toolbar) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.toolbar.id, visible: v)
                    }
                Toggle("Show status bar", isOn: $state.settings.layout.show_status_bar)
                    .onChange(of: state.settings.layout.show_status_bar) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.statusBar.id, visible: v)
                    }
                Toggle("Show file panel", isOn: $state.settings.layout.show_file_panel)
                    .onChange(of: state.settings.layout.show_file_panel) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.filePanel.id, visible: v, asPrimary: true)
                    }
                Toggle("Show thumbnail strip", isOn: $state.settings.layout.show_thumb_strip)
                    .onChange(of: state.settings.layout.show_thumb_strip) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.galleryStrip.id, visible: v)
                    }
                Toggle("Show metadata panel", isOn: $state.settings.layout.show_metadata)
                    .onChange(of: state.settings.layout.show_metadata) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.metadata.id, visible: v)
                    }
                Toggle("Show scope panel", isOn: $state.settings.layout.show_scope)
                    .onChange(of: state.settings.layout.show_scope) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.scopeEditor.id, visible: v)
                    }
                Toggle("Show MCP panel", isOn: $state.settings.layout.show_mcp)
                    .onChange(of: state.settings.layout.show_mcp) { _, v in
                        state.applyShowFlag(BuiltInPanelCatalog.mcpActivity.id, visible: v)
                    }
            }
            Section("Full-screen / slideshow") {
                Toggle("Hide toolbar in full screen", isOn: $state.settings.layout.hide_toolbar_fullscreen)
                Toggle("Hide gallery in full screen", isOn: $state.settings.layout.hide_gallery_fullscreen)
                Toggle("Hide main window in slideshow", isOn: $state.settings.layout.hide_main_in_slideshow)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Slideshow

private struct SlideshowSettingsView: View {
    @Bindable var state: AppState

    /// Last-audited value, used to compute the `old=` field on the
    /// `app=settings.write` line. Initialized to the on-disk value
    /// when the view appears; updated only after each debounce
    /// settles. This is what makes the §4.5 contract "only settle
    /// values land in log.log" hold even when the slider is dragged
    /// continuously.
    @State private var lastAuditedInterval: Double = -1
    @State private var intervalDebounce: Task<Void, Never>? = nil

    var body: some View {
        Form {
            Section("Timing") {
                // slideshow.mdx §4.1 — a Slider for coarse change AND an
                // editable TextField with a Stepper for exact entry,
                // both bound to the same `slideshow.interval_seconds`
                // field so they stay in lockstep. The TextField clamps
                // to [1, 600] on commit (§4.6); the stepper increments
                // by 0.5 s per click.
                HStack(spacing: 8) {
                    Text("Interval")
                        .frame(width: 70, alignment: .leading)
                    Slider(value: $state.settings.slideshow.interval_seconds, in: 1...600)
                    TextField(
                        "",
                        value: $state.settings.slideshow.interval_seconds,
                        format: .number.precision(.fractionLength(1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onSubmit {
                        clampInterval()
                    }
                    Stepper(
                        "",
                        value: $state.settings.slideshow.interval_seconds,
                        in: 1...600,
                        step: 0.5
                    )
                    .labelsHidden()
                    Text("s")
                        .foregroundStyle(.secondary)
                }
                Toggle("Use random interval", isOn: $state.settings.slideshow.use_random_interval)
                if state.settings.slideshow.use_random_interval {
                    HStack {
                        Text("Random max (s)")
                        Slider(value: $state.settings.slideshow.interval_to_seconds,
                               in: state.settings.slideshow.interval_seconds...600)
                        Text(String(format: "%.1f", state.settings.slideshow.interval_to_seconds)).monospacedDigit()
                    }
                }
                Toggle("Loop", isOn: $state.settings.slideshow.loop)
                Toggle("Fullscreen", isOn: $state.settings.slideshow.fullscreen)
            }
            .onAppear {
                if lastAuditedInterval < 0 {
                    lastAuditedInterval = state.settings.slideshow.interval_seconds
                }
            }
            .onChange(of: state.settings.slideshow.interval_seconds) { _, new in
                scheduleIntervalAudit(new)
            }
            Section("Display") {
                Toggle("Show countdown", isOn: $state.settings.slideshow.show_countdown)
                Toggle("Hide main window during slideshow", isOn: $state.settings.slideshow.hide_main_window)
            }
            Section("Sound") {
                Stepper("Notify every N images: \(state.settings.slideshow.notify_every)",
                        value: $state.settings.slideshow.notify_every, in: 0...1000)
                TextField("Notification sound", text: $state.settings.slideshow.notify_sound)
            }
        }
        .formStyle(.grouped)
    }

    /// slideshow.mdx §4.6 — typed input is clamped to the supported
    /// range on commit. Non-numeric strings can't reach this binding
    /// (SwiftUI's `.number` formatter rejects them and reverts the
    /// field to the prior value automatically), so the only check we
    /// need is range.
    private func clampInterval() {
        let v = state.settings.slideshow.interval_seconds
        if v < 1 {
            state.settings.slideshow.interval_seconds = 1
        } else if v > 600 {
            state.settings.slideshow.interval_seconds = 600
        }
    }
}

// MARK: - Edit

private struct EditSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("After editing") {
                Picker("Action", selection: $state.settings.edit.after_action) {
                    Text("Do nothing").tag(AfterEditAction.nothing)
                    Text("Reload image").tag(AfterEditAction.reloadImage)
                    Text("Open Save As").tag(AfterEditAction.openSaveAs)
                }
            }
            Section("Built-in edits") {
                HStack {
                    Text("Quality")
                    Slider(value: Binding(
                        get: { Double(state.settings.edit.quality) },
                        set: { state.settings.edit.quality = Int($0) }
                    ), in: 1...100)
                    Text("\(state.settings.edit.quality)").monospacedDigit()
                }
                Toggle("Preserve EXIF metadata", isOn: $state.settings.edit.preserve_exif)
                Toggle("Preserve color profile", isOn: $state.settings.edit.preserve_icc)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gallery

private struct GallerySettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Show file panel", isOn: $state.settings.gallery.show)
                Toggle("Show file names", isOn: $state.settings.gallery.show_filenames)
                Toggle("Show scrollbars", isOn: $state.settings.gallery.show_scrollbars)
                Toggle("Hide in full screen", isOn: $state.settings.gallery.hide_fullscreen)
            }
            Section("Layout defaults") {
                Picker("Default view mode", selection: $state.settings.gallery.default_view_mode) {
                    ForEach(GalleryViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Thumbnail size", selection: $state.settings.gallery.thumb_size) {
                    ForEach(SettingsDefaults.galleryThumbSizes, id: \.self) {
                        Text("\($0)px").tag($0)
                    }
                }
                Stepper("Grid columns: \(state.settings.gallery.grid_columns)",
                        value: $state.settings.gallery.grid_columns, in: 1...20)
            }
            Section("Cache") {
                HStack {
                    Text("Disk cache (MB)")
                    Slider(value: Binding(
                        get: { Double(state.settings.gallery.disk_cache_mb) },
                        set: { state.settings.gallery.disk_cache_mb = Int($0) }
                    ), in: 100...4096)
                    Text("\(state.settings.gallery.disk_cache_mb)").monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Toolbar

private struct ToolbarSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Toolbar") {
                Toggle("Show toolbar", isOn: $state.settings.toolbar.show)
                Toggle("Center toolbar items", isOn: $state.settings.toolbar.centered)
                Toggle("Show navigation arrows", isOn: $state.settings.toolbar.show_nav_buttons)
                Picker("Icon height", selection: $state.settings.toolbar.icon_height) {
                    ForEach(SettingsDefaults.toolbarIconHeights, id: \.self) {
                        Text("\($0)pt").tag($0)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Config file") {
                Text(SettingsPaths.resolve().fileURL.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("MCP server") {
                Toggle("Enabled", isOn: $state.settings.advanced.mcp.enabled)
                Picker("Transport", selection: $state.settings.advanced.mcp.transport) {
                    Text("Stdio").tag(MCPTransport.stdio)
                    Text("Unix socket").tag(MCPTransport.unixSocket)
                    Text("HTTP + SSE").tag(MCPTransport.httpSse)
                }
                Toggle("Audit log", isOn: $state.settings.advanced.mcp.audit_log)
            }
            Section("Diagnostics") {
                Toggle("Enable debug logging", isOn: $state.settings.advanced.debug_logging)
                Toggle("Allow unsigned plugins", isOn: $state.settings.advanced.allow_unsigned_plugins)
                Stepper("Log retention (days): \(state.settings.advanced.log_retention_days)",
                        value: $state.settings.advanced.log_retention_days, in: 0...365)
                Stepper("Thumb cache (MB): \(state.settings.advanced.thumb_cache_mb)",
                        value: $state.settings.advanced.thumb_cache_mb, in: 0...32_768, step: 128)
            }
            Section("Reset") {
                Button("Reset settings to defaults") {
                    state.settings = Settings.defaults
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
