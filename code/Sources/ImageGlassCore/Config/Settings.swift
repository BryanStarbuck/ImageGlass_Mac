import Foundation

// MARK: - Color (Codable RGBA for settings.json)

/// `Codable` color used by `settings.json` color fields. Stored as a four-byte
/// dictionary on disk: `{"r":0,"g":0,"b":0,"a":255}`. Separate from the
/// runtime `RGBA` pixel struct in `ColorChannelMath.swift` because that one is
/// not `Codable` and a settings file should not bind to a renderer type.
public struct SettingsColor: Codable, Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let black = SettingsColor(r: 0, g: 0, b: 0, a: 255)
    public static let white = SettingsColor(r: 255, g: 255, b: 255, a: 255)
}

// MARK: - Enums for the spec's enum-typed fields

public enum ThemeOverride: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum UpdateCadence: String, Codable, CaseIterable, Sendable {
    case never, daily, weekly, monthly
}

/// `hotkeys.mdx` §6.5 / §9 — where Zoom to Width parks the vertical
/// scroll position when the user enters the mode. `top` is the only
/// active value in v1; the other two are reserved.
public enum ZoomToWidthScroll: String, Codable, CaseIterable, Sendable {
    case top
    case center
    case lastViewed = "last_viewed"
}

/// `hotkeys.mdx` §5 / §6 / §9 — what the `N` (Normalize) hotkey snaps to
/// at app launch and on every "reset" press. Also drives the initial
/// zoom applied to a freshly opened image.
public enum DefaultZoomOnOpen: String, Codable, CaseIterable, Sendable {
    case fit          // Zoom to Fit (default — fits longer dimension)
    case actual       // Actual Size (100%)
    case restoreLast = "restore_last"  // Re-enter the user's last-used mode
}

/// Spec §4.3 — `viewer.zoom_mode`. Distinct from the legacy `ZoomMode` in
/// `ZoomMath.swift` because the spec adds `oneToOne` and uses different
/// labels for the existing cases.
public enum ZoomModeSetting: String, Codable, CaseIterable, Sendable {
    case autoZoom, lockZoom, scaleToWidth, scaleToHeight, scaleToFit, scaleToFill, oneToOne
}

public enum ColorProfileChoice: String, Codable, CaseIterable, Sendable {
    case currentMonitor, sRGB, displayP3, adobeRGB, custom
}

public enum Interpolation: String, Codable, CaseIterable, Sendable {
    case nearest, linear, lanczos, cubic, mitchell, gaussian
}

public enum ImageOrder: String, Codable, CaseIterable, Sendable {
    case name, length, creationTime, lastWriteTime, `extension`, random, exifDate
}

public enum SortDirection: String, Codable, CaseIterable, Sendable {
    case asc, desc
}

public enum WindowMaterial: String, Codable, CaseIterable, Sendable {
    case none, sidebar, hudWindow, popover, underWindowBackground, contentBackground, titlebar, menu
}

public enum AfterEditAction: String, Codable, CaseIterable, Sendable {
    case nothing, reloadImage, openSaveAs
}

public enum CropAspect: String, Codable, CaseIterable, Sendable {
    case freeRatio, oneToOne, fourToThree, threeToTwo, sixteenToNine, sixteenToTen, twentyOneToNine, golden, custom
}

public enum CropInitialSelection: String, Codable, CaseIterable, Sendable {
    case useLastSelection, customArea, selectAll, selectNone
    case select10Percent, select20Percent, select25Percent, select30Percent
    case selectOneThird, select40Percent, select50Percent, select60Percent
    case selectTwoThirds, select70Percent, select75Percent, select80Percent, select90Percent
}

// `CropOutputFormat` is defined in `Crop/CropTypes.swift` and shared here.

public enum ColorPickerCopyFormat: String, Codable, CaseIterable, Sendable {
    case rgb, hex, hsl, hsv, cieLab, swift_color, ns_color
}

public enum GalleryViewMode: String, Codable, CaseIterable, Sendable {
    case strip, grid, details, tree, column
}

public enum MCPTransport: String, Codable, CaseIterable, Sendable {
    case stdio, unixSocket, httpSse
}

// MARK: - Section structs

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var theme_override: ThemeOverride
    public var accent_color: SettingsColor?
    public var open_last_image: Bool
    public var multi_instance: Bool
    public var window_top_most: Bool
    public var start_full_screen: Bool
    public var frameless: Bool
    public var window_fit: Bool
    public var window_fit_centered: Bool
    public var confirm_delete: Bool
    public var confirm_overwrite: Bool
    public var preserve_modified_date: Bool
    public var save_as_in_current_dir: Bool
    public var update_cadence: UpdateCadence
    public var show_update_badge: Bool
    public var show_welcome_image: Bool
    public var show_app_icon: Bool
    public var quick_setup_version: Double
    public var toast_duration_ms: Int
    public var last_seen_image: String?
    public var disabled_menus: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = GeneralSettings()
        theme_override = try c.decodeIfPresent(ThemeOverride.self, forKey: .theme_override) ?? d.theme_override
        accent_color = try c.decodeIfPresent(SettingsColor.self, forKey: .accent_color) ?? d.accent_color
        open_last_image = try c.decodeIfPresent(Bool.self, forKey: .open_last_image) ?? d.open_last_image
        multi_instance = try c.decodeIfPresent(Bool.self, forKey: .multi_instance) ?? d.multi_instance
        window_top_most = try c.decodeIfPresent(Bool.self, forKey: .window_top_most) ?? d.window_top_most
        start_full_screen = try c.decodeIfPresent(Bool.self, forKey: .start_full_screen) ?? d.start_full_screen
        frameless = try c.decodeIfPresent(Bool.self, forKey: .frameless) ?? d.frameless
        window_fit = try c.decodeIfPresent(Bool.self, forKey: .window_fit) ?? d.window_fit
        window_fit_centered = try c.decodeIfPresent(Bool.self, forKey: .window_fit_centered) ?? d.window_fit_centered
        confirm_delete = try c.decodeIfPresent(Bool.self, forKey: .confirm_delete) ?? d.confirm_delete
        confirm_overwrite = try c.decodeIfPresent(Bool.self, forKey: .confirm_overwrite) ?? d.confirm_overwrite
        preserve_modified_date = try c.decodeIfPresent(Bool.self, forKey: .preserve_modified_date) ?? d.preserve_modified_date
        save_as_in_current_dir = try c.decodeIfPresent(Bool.self, forKey: .save_as_in_current_dir) ?? d.save_as_in_current_dir
        update_cadence = try c.decodeIfPresent(UpdateCadence.self, forKey: .update_cadence) ?? d.update_cadence
        show_update_badge = try c.decodeIfPresent(Bool.self, forKey: .show_update_badge) ?? d.show_update_badge
        show_welcome_image = try c.decodeIfPresent(Bool.self, forKey: .show_welcome_image) ?? d.show_welcome_image
        show_app_icon = try c.decodeIfPresent(Bool.self, forKey: .show_app_icon) ?? d.show_app_icon
        quick_setup_version = try c.decodeIfPresent(Double.self, forKey: .quick_setup_version) ?? d.quick_setup_version
        toast_duration_ms = try c.decodeIfPresent(Int.self, forKey: .toast_duration_ms) ?? d.toast_duration_ms
        last_seen_image = try c.decodeIfPresent(String.self, forKey: .last_seen_image) ?? d.last_seen_image
        disabled_menus = try c.decodeIfPresent([String].self, forKey: .disabled_menus) ?? d.disabled_menus
    }

    public init(
        theme_override: ThemeOverride = .system,
        accent_color: SettingsColor? = nil,
        open_last_image: Bool = true,
        multi_instance: Bool = true,
        window_top_most: Bool = false,
        start_full_screen: Bool = false,
        frameless: Bool = false,
        window_fit: Bool = false,
        window_fit_centered: Bool = true,
        confirm_delete: Bool = true,
        confirm_overwrite: Bool = true,
        preserve_modified_date: Bool = false,
        save_as_in_current_dir: Bool = true,
        update_cadence: UpdateCadence = .weekly,
        show_update_badge: Bool = false,
        show_welcome_image: Bool = true,
        show_app_icon: Bool = true,
        quick_setup_version: Double = 0,
        toast_duration_ms: Int = 2000,
        last_seen_image: String? = nil,
        disabled_menus: [String] = []
    ) {
        self.theme_override = theme_override
        self.accent_color = accent_color
        self.open_last_image = open_last_image
        self.multi_instance = multi_instance
        self.window_top_most = window_top_most
        self.start_full_screen = start_full_screen
        self.frameless = frameless
        self.window_fit = window_fit
        self.window_fit_centered = window_fit_centered
        self.confirm_delete = confirm_delete
        self.confirm_overwrite = confirm_overwrite
        self.preserve_modified_date = preserve_modified_date
        self.save_as_in_current_dir = save_as_in_current_dir
        self.update_cadence = update_cadence
        self.show_update_badge = show_update_badge
        self.show_welcome_image = show_welcome_image
        self.show_app_icon = show_app_icon
        self.quick_setup_version = quick_setup_version
        self.toast_duration_ms = toast_duration_ms
        self.last_seen_image = last_seen_image
        self.disabled_menus = disabled_menus
    }
}

public struct ImageSettings: Codable, Equatable, Sendable {
    public var color_profile: ColorProfileChoice
    public var color_profile_all_formats: Bool
    public var async_loading: Bool
    public var embedded_thumb_raw: Bool
    public var embedded_thumb_other: Bool
    public var embedded_thumb_min_width: Int
    public var embedded_thumb_min_height: Int
    public var interp_scale_down: Interpolation
    public var interp_scale_up: Interpolation
    public var info_overlay: Bool
    public var info_tags: [String]
    public var single_frame_formats: [String]
    public var checkerboard: Bool
    public var checkerboard_image_only: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ImageSettings()
        color_profile = try c.decodeIfPresent(ColorProfileChoice.self, forKey: .color_profile) ?? d.color_profile
        color_profile_all_formats = try c.decodeIfPresent(Bool.self, forKey: .color_profile_all_formats) ?? d.color_profile_all_formats
        async_loading = try c.decodeIfPresent(Bool.self, forKey: .async_loading) ?? d.async_loading
        embedded_thumb_raw = try c.decodeIfPresent(Bool.self, forKey: .embedded_thumb_raw) ?? d.embedded_thumb_raw
        embedded_thumb_other = try c.decodeIfPresent(Bool.self, forKey: .embedded_thumb_other) ?? d.embedded_thumb_other
        embedded_thumb_min_width = try c.decodeIfPresent(Int.self, forKey: .embedded_thumb_min_width) ?? d.embedded_thumb_min_width
        embedded_thumb_min_height = try c.decodeIfPresent(Int.self, forKey: .embedded_thumb_min_height) ?? d.embedded_thumb_min_height
        interp_scale_down = try c.decodeIfPresent(Interpolation.self, forKey: .interp_scale_down) ?? d.interp_scale_down
        interp_scale_up = try c.decodeIfPresent(Interpolation.self, forKey: .interp_scale_up) ?? d.interp_scale_up
        info_overlay = try c.decodeIfPresent(Bool.self, forKey: .info_overlay) ?? d.info_overlay
        info_tags = try c.decodeIfPresent([String].self, forKey: .info_tags) ?? d.info_tags
        single_frame_formats = try c.decodeIfPresent([String].self, forKey: .single_frame_formats) ?? d.single_frame_formats
        checkerboard = try c.decodeIfPresent(Bool.self, forKey: .checkerboard) ?? d.checkerboard
        checkerboard_image_only = try c.decodeIfPresent(Bool.self, forKey: .checkerboard_image_only) ?? d.checkerboard_image_only
    }

    public init(
        color_profile: ColorProfileChoice = .currentMonitor,
        color_profile_all_formats: Bool = false,
        async_loading: Bool = true,
        embedded_thumb_raw: Bool = false,
        embedded_thumb_other: Bool = false,
        embedded_thumb_min_width: Int = 0,
        embedded_thumb_min_height: Int = 0,
        interp_scale_down: Interpolation = .lanczos,
        interp_scale_up: Interpolation = .nearest,
        info_overlay: Bool = false,
        info_tags: [String] = SettingsDefaults.imageInfoTags,
        single_frame_formats: [String] = SettingsDefaults.singleFrameFormats,
        checkerboard: Bool = false,
        checkerboard_image_only: Bool = false
    ) {
        self.color_profile = color_profile
        self.color_profile_all_formats = color_profile_all_formats
        self.async_loading = async_loading
        self.embedded_thumb_raw = embedded_thumb_raw
        self.embedded_thumb_other = embedded_thumb_other
        self.embedded_thumb_min_width = embedded_thumb_min_width
        self.embedded_thumb_min_height = embedded_thumb_min_height
        self.interp_scale_down = interp_scale_down
        self.interp_scale_up = interp_scale_up
        self.info_overlay = info_overlay
        self.info_tags = info_tags
        self.single_frame_formats = single_frame_formats
        self.checkerboard = checkerboard
        self.checkerboard_image_only = checkerboard_image_only
    }
}

public struct ViewerSettings: Codable, Equatable, Sendable {
    public var zoom_mode: ZoomModeSetting
    public var zoom_lock_percent: Double
    public var zoom_speed: Double
    public var pan_speed: Double
    public var gesture_pinch_zoom: Bool
    public var gesture_two_finger_pan: Bool
    public var gesture_swipe_nav: Bool
    public var gesture_smart_magnify: Bool
    public var gesture_rotate: Bool
    public var loop_navigation: Bool
    public var auto_switch_sibling_dir: Bool
    public var recursive_loading: Bool
    public var show_hidden_files: Bool
    public var group_by_dir: Bool
    public var real_time_file_update: Bool
    public var auto_open_new: Bool
    public var image_order: ImageOrder
    public var image_order_direction: SortDirection
    public var show_frame_nav: Bool
    public var cache_image_count: Int
    public var cache_max_dim: Int
    public var cache_max_mb: Double
    public var huge_image_threshold: Int
    // hotkeys.mdx §9 — knobs the bare-letter / arrow hotkeys consult.
    /// Multiplicative zoom step for `+` / `-` and ⌘+/⌘-, expressed as a
    /// percent. 20 ⇒ each press scales by ×1.20.
    public var zoom_step_percent: Double
    /// Per-press pan step for ⌃-arrow, as a percent of viewport width
    /// (left/right) or height (up/down).
    public var pan_step_percent: Double
    /// What `N` (Normalize) and the initial zoom on a new image snap to.
    public var default_zoom_on_open: DefaultZoomOnOpen
    /// When true, ↑ on the first visible row wraps to the last, and ↓
    /// on the last row wraps to the first. Off per spec default.
    public var wrap_at_ends: Bool
    /// `Zoom to Width: scroll target`. v1 always honors `top`; `center`
    /// and `lastViewed` are reserved.
    public var zoom_to_width_scroll: ZoomToWidthScroll

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ViewerSettings()
        zoom_mode = try c.decodeIfPresent(ZoomModeSetting.self, forKey: .zoom_mode) ?? d.zoom_mode
        zoom_lock_percent = try c.decodeIfPresent(Double.self, forKey: .zoom_lock_percent) ?? d.zoom_lock_percent
        zoom_speed = try c.decodeIfPresent(Double.self, forKey: .zoom_speed) ?? d.zoom_speed
        pan_speed = try c.decodeIfPresent(Double.self, forKey: .pan_speed) ?? d.pan_speed
        gesture_pinch_zoom = try c.decodeIfPresent(Bool.self, forKey: .gesture_pinch_zoom) ?? d.gesture_pinch_zoom
        gesture_two_finger_pan = try c.decodeIfPresent(Bool.self, forKey: .gesture_two_finger_pan) ?? d.gesture_two_finger_pan
        gesture_swipe_nav = try c.decodeIfPresent(Bool.self, forKey: .gesture_swipe_nav) ?? d.gesture_swipe_nav
        gesture_smart_magnify = try c.decodeIfPresent(Bool.self, forKey: .gesture_smart_magnify) ?? d.gesture_smart_magnify
        gesture_rotate = try c.decodeIfPresent(Bool.self, forKey: .gesture_rotate) ?? d.gesture_rotate
        loop_navigation = try c.decodeIfPresent(Bool.self, forKey: .loop_navigation) ?? d.loop_navigation
        auto_switch_sibling_dir = try c.decodeIfPresent(Bool.self, forKey: .auto_switch_sibling_dir) ?? d.auto_switch_sibling_dir
        recursive_loading = try c.decodeIfPresent(Bool.self, forKey: .recursive_loading) ?? d.recursive_loading
        show_hidden_files = try c.decodeIfPresent(Bool.self, forKey: .show_hidden_files) ?? d.show_hidden_files
        group_by_dir = try c.decodeIfPresent(Bool.self, forKey: .group_by_dir) ?? d.group_by_dir
        real_time_file_update = try c.decodeIfPresent(Bool.self, forKey: .real_time_file_update) ?? d.real_time_file_update
        auto_open_new = try c.decodeIfPresent(Bool.self, forKey: .auto_open_new) ?? d.auto_open_new
        image_order = try c.decodeIfPresent(ImageOrder.self, forKey: .image_order) ?? d.image_order
        image_order_direction = try c.decodeIfPresent(SortDirection.self, forKey: .image_order_direction) ?? d.image_order_direction
        show_frame_nav = try c.decodeIfPresent(Bool.self, forKey: .show_frame_nav) ?? d.show_frame_nav
        cache_image_count = try c.decodeIfPresent(Int.self, forKey: .cache_image_count) ?? d.cache_image_count
        cache_max_dim = try c.decodeIfPresent(Int.self, forKey: .cache_max_dim) ?? d.cache_max_dim
        cache_max_mb = try c.decodeIfPresent(Double.self, forKey: .cache_max_mb) ?? d.cache_max_mb
        huge_image_threshold = try c.decodeIfPresent(Int.self, forKey: .huge_image_threshold) ?? d.huge_image_threshold
        zoom_step_percent = try c.decodeIfPresent(Double.self, forKey: .zoom_step_percent) ?? d.zoom_step_percent
        pan_step_percent = try c.decodeIfPresent(Double.self, forKey: .pan_step_percent) ?? d.pan_step_percent
        default_zoom_on_open = try c.decodeIfPresent(DefaultZoomOnOpen.self, forKey: .default_zoom_on_open) ?? d.default_zoom_on_open
        wrap_at_ends = try c.decodeIfPresent(Bool.self, forKey: .wrap_at_ends) ?? d.wrap_at_ends
        zoom_to_width_scroll = try c.decodeIfPresent(ZoomToWidthScroll.self, forKey: .zoom_to_width_scroll) ?? d.zoom_to_width_scroll
    }

    public init(
        zoom_mode: ZoomModeSetting = .autoZoom,
        zoom_lock_percent: Double = 100,
        zoom_speed: Double = 0,
        pan_speed: Double = 20,
        gesture_pinch_zoom: Bool = true,
        gesture_two_finger_pan: Bool = true,
        gesture_swipe_nav: Bool = true,
        gesture_smart_magnify: Bool = true,
        gesture_rotate: Bool = false,
        loop_navigation: Bool = true,
        auto_switch_sibling_dir: Bool = false,
        recursive_loading: Bool = false,
        show_hidden_files: Bool = false,
        group_by_dir: Bool = false,
        real_time_file_update: Bool = true,
        auto_open_new: Bool = false,
        image_order: ImageOrder = .name,
        image_order_direction: SortDirection = .asc,
        show_frame_nav: Bool = false,
        cache_image_count: Int = 1,
        cache_max_dim: Int = 8000,
        cache_max_mb: Double = 100,
        huge_image_threshold: Int = 16000,
        zoom_step_percent: Double = 20,
        pan_step_percent: Double = 15,
        default_zoom_on_open: DefaultZoomOnOpen = .fit,
        wrap_at_ends: Bool = false,
        zoom_to_width_scroll: ZoomToWidthScroll = .top
    ) {
        self.zoom_mode = zoom_mode
        self.zoom_lock_percent = zoom_lock_percent
        self.zoom_speed = zoom_speed
        self.pan_speed = pan_speed
        self.gesture_pinch_zoom = gesture_pinch_zoom
        self.gesture_two_finger_pan = gesture_two_finger_pan
        self.gesture_swipe_nav = gesture_swipe_nav
        self.gesture_smart_magnify = gesture_smart_magnify
        self.gesture_rotate = gesture_rotate
        self.loop_navigation = loop_navigation
        self.auto_switch_sibling_dir = auto_switch_sibling_dir
        self.recursive_loading = recursive_loading
        self.show_hidden_files = show_hidden_files
        self.group_by_dir = group_by_dir
        self.real_time_file_update = real_time_file_update
        self.auto_open_new = auto_open_new
        self.image_order = image_order
        self.image_order_direction = image_order_direction
        self.show_frame_nav = show_frame_nav
        self.cache_image_count = cache_image_count
        self.cache_max_dim = cache_max_dim
        self.cache_max_mb = cache_max_mb
        self.huge_image_threshold = huge_image_threshold
        self.zoom_step_percent = zoom_step_percent
        self.pan_step_percent = pan_step_percent
        self.default_zoom_on_open = default_zoom_on_open
        self.wrap_at_ends = wrap_at_ends
        self.zoom_to_width_scroll = zoom_to_width_scroll
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var light_theme: String
    public var dark_theme: String
    public var background: SettingsColor?
    public var slideshow_background: SettingsColor
    public var window_material: WindowMaterial
    public var background_drag: Bool
    public var show_app_icon: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = AppearanceSettings()
        light_theme = try c.decodeIfPresent(String.self, forKey: .light_theme) ?? d.light_theme
        dark_theme = try c.decodeIfPresent(String.self, forKey: .dark_theme) ?? d.dark_theme
        background = try c.decodeIfPresent(SettingsColor.self, forKey: .background) ?? d.background
        slideshow_background = try c.decodeIfPresent(SettingsColor.self, forKey: .slideshow_background) ?? d.slideshow_background
        window_material = try c.decodeIfPresent(WindowMaterial.self, forKey: .window_material) ?? d.window_material
        background_drag = try c.decodeIfPresent(Bool.self, forKey: .background_drag) ?? d.background_drag
        show_app_icon = try c.decodeIfPresent(Bool.self, forKey: .show_app_icon) ?? d.show_app_icon
    }

    public init(
        light_theme: String = "Kobe-Light",
        dark_theme: String = "Default",
        background: SettingsColor? = nil,
        slideshow_background: SettingsColor = .black,
        window_material: WindowMaterial = .underWindowBackground,
        background_drag: Bool = true,
        show_app_icon: Bool = true
    ) {
        self.light_theme = light_theme
        self.dark_theme = dark_theme
        self.background = background
        self.slideshow_background = slideshow_background
        self.window_material = window_material
        self.background_drag = background_drag
        self.show_app_icon = show_app_icon
    }
}

public struct LayoutSettings: Codable, Equatable, Sendable {
    public var active_preset: String
    public var show_toolbar: Bool
    public var show_status_bar: Bool
    public var show_file_panel: Bool
    public var show_thumb_strip: Bool
    public var show_metadata: Bool
    public var show_scope: Bool
    public var show_mcp: Bool
    public var hide_toolbar_fullscreen: Bool
    public var hide_gallery_fullscreen: Bool
    public var hide_main_in_slideshow: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = LayoutSettings()
        active_preset = try c.decodeIfPresent(String.self, forKey: .active_preset) ?? d.active_preset
        show_toolbar = try c.decodeIfPresent(Bool.self, forKey: .show_toolbar) ?? d.show_toolbar
        show_status_bar = try c.decodeIfPresent(Bool.self, forKey: .show_status_bar) ?? d.show_status_bar
        show_file_panel = try c.decodeIfPresent(Bool.self, forKey: .show_file_panel) ?? d.show_file_panel
        show_thumb_strip = try c.decodeIfPresent(Bool.self, forKey: .show_thumb_strip) ?? d.show_thumb_strip
        show_metadata = try c.decodeIfPresent(Bool.self, forKey: .show_metadata) ?? d.show_metadata
        show_scope = try c.decodeIfPresent(Bool.self, forKey: .show_scope) ?? d.show_scope
        show_mcp = try c.decodeIfPresent(Bool.self, forKey: .show_mcp) ?? d.show_mcp
        hide_toolbar_fullscreen = try c.decodeIfPresent(Bool.self, forKey: .hide_toolbar_fullscreen) ?? d.hide_toolbar_fullscreen
        hide_gallery_fullscreen = try c.decodeIfPresent(Bool.self, forKey: .hide_gallery_fullscreen) ?? d.hide_gallery_fullscreen
        hide_main_in_slideshow = try c.decodeIfPresent(Bool.self, forKey: .hide_main_in_slideshow) ?? d.hide_main_in_slideshow
    }

    public init(
        active_preset: String = "Browser",
        show_toolbar: Bool = true,
        show_status_bar: Bool = true,
        show_file_panel: Bool = true,
        show_thumb_strip: Bool = false,
        show_metadata: Bool = false,
        show_scope: Bool = false,
        show_mcp: Bool = false,
        hide_toolbar_fullscreen: Bool = false,
        hide_gallery_fullscreen: Bool = false,
        hide_main_in_slideshow: Bool = true
    ) {
        self.active_preset = active_preset
        self.show_toolbar = show_toolbar
        self.show_status_bar = show_status_bar
        self.show_file_panel = show_file_panel
        self.show_thumb_strip = show_thumb_strip
        self.show_metadata = show_metadata
        self.show_scope = show_scope
        self.show_mcp = show_mcp
        self.hide_toolbar_fullscreen = hide_toolbar_fullscreen
        self.hide_gallery_fullscreen = hide_gallery_fullscreen
        self.hide_main_in_slideshow = hide_main_in_slideshow
    }
}

public struct SlideshowSettings: Codable, Equatable, Sendable {
    public var enabled_on_launch: Bool
    public var interval_seconds: Double
    public var interval_to_seconds: Double
    public var use_random_interval: Bool
    public var loop: Bool
    public var fullscreen: Bool
    public var show_countdown: Bool
    public var hide_main_window: Bool
    public var notify_every: Int
    public var notify_sound: String
    public var background: SettingsColor

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = SlideshowSettings()
        enabled_on_launch = try c.decodeIfPresent(Bool.self, forKey: .enabled_on_launch) ?? d.enabled_on_launch
        interval_seconds = try c.decodeIfPresent(Double.self, forKey: .interval_seconds) ?? d.interval_seconds
        interval_to_seconds = try c.decodeIfPresent(Double.self, forKey: .interval_to_seconds) ?? d.interval_to_seconds
        use_random_interval = try c.decodeIfPresent(Bool.self, forKey: .use_random_interval) ?? d.use_random_interval
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? d.loop
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? d.fullscreen
        show_countdown = try c.decodeIfPresent(Bool.self, forKey: .show_countdown) ?? d.show_countdown
        hide_main_window = try c.decodeIfPresent(Bool.self, forKey: .hide_main_window) ?? d.hide_main_window
        notify_every = try c.decodeIfPresent(Int.self, forKey: .notify_every) ?? d.notify_every
        notify_sound = try c.decodeIfPresent(String.self, forKey: .notify_sound) ?? d.notify_sound
        background = try c.decodeIfPresent(SettingsColor.self, forKey: .background) ?? d.background
    }

    public init(
        enabled_on_launch: Bool = false,
        interval_seconds: Double = 5.0,
        interval_to_seconds: Double = 5.0,
        use_random_interval: Bool = false,
        loop: Bool = true,
        fullscreen: Bool = true,
        show_countdown: Bool = true,
        hide_main_window: Bool = true,
        notify_every: Int = 0,
        notify_sound: String = "Tink",
        background: SettingsColor = .black
    ) {
        self.enabled_on_launch = enabled_on_launch
        self.interval_seconds = interval_seconds
        self.interval_to_seconds = interval_to_seconds
        self.use_random_interval = use_random_interval
        self.loop = loop
        self.fullscreen = fullscreen
        self.show_countdown = show_countdown
        self.hide_main_window = hide_main_window
        self.notify_every = notify_every
        self.notify_sound = notify_sound
        self.background = background
    }
}

public struct EditAppBinding: Codable, Equatable, Hashable, Sendable {
    public var extensions: [String]
    public var appBundleID: String?
    public var appPath: String?
    public var arguments: [String]

    public init(extensions: [String] = [], appBundleID: String? = nil, appPath: String? = nil, arguments: [String] = []) {
        self.extensions = extensions
        self.appBundleID = appBundleID
        self.appPath = appPath
        self.arguments = arguments
    }
}

public struct CropDefaults: Codable, Equatable, Sendable {
    public var aspect_ratio: CropAspect
    public var aspect_values: [Int]
    public var close_after_save: Bool
    public var init_selection: CropInitialSelection
    public var init_rect: [Int]
    public var auto_center: Bool
    public var persistent_selection: Bool
    public var default_output_format: CropOutputFormat
    public var default_output_quality: Int
    public var lossless_jpeg: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = CropDefaults()
        aspect_ratio = try c.decodeIfPresent(CropAspect.self, forKey: .aspect_ratio) ?? d.aspect_ratio
        aspect_values = try c.decodeIfPresent([Int].self, forKey: .aspect_values) ?? d.aspect_values
        close_after_save = try c.decodeIfPresent(Bool.self, forKey: .close_after_save) ?? d.close_after_save
        init_selection = try c.decodeIfPresent(CropInitialSelection.self, forKey: .init_selection) ?? d.init_selection
        init_rect = try c.decodeIfPresent([Int].self, forKey: .init_rect) ?? d.init_rect
        auto_center = try c.decodeIfPresent(Bool.self, forKey: .auto_center) ?? d.auto_center
        persistent_selection = try c.decodeIfPresent(Bool.self, forKey: .persistent_selection) ?? d.persistent_selection
        default_output_format = try c.decodeIfPresent(CropOutputFormat.self, forKey: .default_output_format) ?? d.default_output_format
        default_output_quality = try c.decodeIfPresent(Int.self, forKey: .default_output_quality) ?? d.default_output_quality
        lossless_jpeg = try c.decodeIfPresent(Bool.self, forKey: .lossless_jpeg) ?? d.lossless_jpeg
    }

    public init(
        aspect_ratio: CropAspect = .freeRatio,
        aspect_values: [Int] = [0, 0],
        close_after_save: Bool = false,
        init_selection: CropInitialSelection = .select50Percent,
        init_rect: [Int] = [0, 0, 0, 0],
        auto_center: Bool = true,
        persistent_selection: Bool = false,
        default_output_format: CropOutputFormat = .auto,
        default_output_quality: Int = 90,
        lossless_jpeg: Bool = true
    ) {
        self.aspect_ratio = aspect_ratio
        self.aspect_values = aspect_values
        self.close_after_save = close_after_save
        self.init_selection = init_selection
        self.init_rect = init_rect
        self.auto_center = auto_center
        self.persistent_selection = persistent_selection
        self.default_output_format = default_output_format
        self.default_output_quality = default_output_quality
        self.lossless_jpeg = lossless_jpeg
    }
}

public struct EditSettings: Codable, Equatable, Sendable {
    public var apps: [EditAppBinding]
    public var after_action: AfterEditAction
    public var quality: Int
    public var preserve_exif: Bool
    public var preserve_icc: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = EditSettings()
        apps = try c.decodeIfPresent([EditAppBinding].self, forKey: .apps) ?? d.apps
        after_action = try c.decodeIfPresent(AfterEditAction.self, forKey: .after_action) ?? d.after_action
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? d.quality
        preserve_exif = try c.decodeIfPresent(Bool.self, forKey: .preserve_exif) ?? d.preserve_exif
        preserve_icc = try c.decodeIfPresent(Bool.self, forKey: .preserve_icc) ?? d.preserve_icc
    }

    public init(
        apps: [EditAppBinding] = [],
        after_action: AfterEditAction = .nothing,
        quality: Int = 80,
        preserve_exif: Bool = true,
        preserve_icc: Bool = true
    ) {
        self.apps = apps
        self.after_action = after_action
        self.quality = quality
        self.preserve_exif = preserve_exif
        self.preserve_icc = preserve_icc
    }
}

public struct MouseSettings: Codable, Equatable, Sendable {
    public var click_actions: [String: String]
    public var wheel_actions: [String: String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = MouseSettings()
        click_actions = try c.decodeIfPresent([String: String].self, forKey: .click_actions) ?? d.click_actions
        wheel_actions = try c.decodeIfPresent([String: String].self, forKey: .wheel_actions) ?? d.wheel_actions
    }

    public init(
        click_actions: [String: String] = SettingsDefaults.mouseClickActions,
        wheel_actions: [String: String] = SettingsDefaults.mouseWheelActions
    ) {
        self.click_actions = click_actions
        self.wheel_actions = wheel_actions
    }
}

public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: [String]
    public init(key: String, modifiers: [String] = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct KeyboardSettings: Codable, Equatable, Sendable {
    public var bindings: [String: [Hotkey]]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = KeyboardSettings()
        bindings = try c.decodeIfPresent([String: [Hotkey]].self, forKey: .bindings) ?? d.bindings
    }

    public init(bindings: [String: [Hotkey]] = SettingsDefaults.keybindings) {
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case bindings }
}

public struct GallerySettings: Codable, Equatable, Sendable {
    public var show: Bool
    public var show_filenames: Bool
    public var show_scrollbars: Bool
    public var default_view_mode: GalleryViewMode
    public var thumb_size: Int
    public var grid_columns: Int
    public var disk_cache_mb: Int
    public var hide_fullscreen: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = GallerySettings()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        show_filenames = try c.decodeIfPresent(Bool.self, forKey: .show_filenames) ?? d.show_filenames
        show_scrollbars = try c.decodeIfPresent(Bool.self, forKey: .show_scrollbars) ?? d.show_scrollbars
        default_view_mode = try c.decodeIfPresent(GalleryViewMode.self, forKey: .default_view_mode) ?? d.default_view_mode
        thumb_size = try c.decodeIfPresent(Int.self, forKey: .thumb_size) ?? d.thumb_size
        grid_columns = try c.decodeIfPresent(Int.self, forKey: .grid_columns) ?? d.grid_columns
        disk_cache_mb = try c.decodeIfPresent(Int.self, forKey: .disk_cache_mb) ?? d.disk_cache_mb
        hide_fullscreen = try c.decodeIfPresent(Bool.self, forKey: .hide_fullscreen) ?? d.hide_fullscreen
    }

    public init(
        show: Bool = true,
        show_filenames: Bool = true,
        show_scrollbars: Bool = false,
        default_view_mode: GalleryViewMode = .strip,
        thumb_size: Int = 128,
        grid_columns: Int = 3,
        disk_cache_mb: Int = 400,
        hide_fullscreen: Bool = false
    ) {
        self.show = show
        self.show_filenames = show_filenames
        self.show_scrollbars = show_scrollbars
        self.default_view_mode = default_view_mode
        self.thumb_size = thumb_size
        self.grid_columns = grid_columns
        self.disk_cache_mb = disk_cache_mb
        self.hide_fullscreen = hide_fullscreen
    }
}

public struct ToolbarItem: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case action, separator, flexibleSpace, fixedSpace
    }
    public enum DisplayMode: String, Codable, Sendable {
        case iconOnly, labelOnly, iconAndLabel
    }
    public var kind: Kind
    public var actionID: String?
    public var icon: String?
    public var displayMode: DisplayMode?

    public init(kind: Kind, actionID: String? = nil, icon: String? = nil, displayMode: DisplayMode? = nil) {
        self.kind = kind
        self.actionID = actionID
        self.icon = icon
        self.displayMode = displayMode
    }
}

public struct ToolbarSettings: Codable, Equatable, Sendable {
    public var show: Bool
    public var centered: Bool
    public var icon_height: Int
    public var buttons: [ToolbarItem]
    public var show_nav_buttons: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ToolbarSettings()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        centered = try c.decodeIfPresent(Bool.self, forKey: .centered) ?? d.centered
        icon_height = try c.decodeIfPresent(Int.self, forKey: .icon_height) ?? d.icon_height
        buttons = try c.decodeIfPresent([ToolbarItem].self, forKey: .buttons) ?? d.buttons
        show_nav_buttons = try c.decodeIfPresent(Bool.self, forKey: .show_nav_buttons) ?? d.show_nav_buttons
    }

    public init(
        show: Bool = true,
        centered: Bool = true,
        icon_height: Int = 24,
        buttons: [ToolbarItem] = [],
        show_nav_buttons: Bool = true
    ) {
        self.show = show
        self.centered = centered
        self.icon_height = icon_height
        self.buttons = buttons
        self.show_nav_buttons = show_nav_buttons
    }
}

public struct FileAssocSettings: Codable, Equatable, Sendable {
    public var claimed_utis: [String]
    public var current_defaults: [String: String]
    public var enable_quicklook: Bool
    public var enable_services: Bool
    public var enable_share_ext: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = FileAssocSettings()
        claimed_utis = try c.decodeIfPresent([String].self, forKey: .claimed_utis) ?? d.claimed_utis
        current_defaults = try c.decodeIfPresent([String: String].self, forKey: .current_defaults) ?? d.current_defaults
        enable_quicklook = try c.decodeIfPresent(Bool.self, forKey: .enable_quicklook) ?? d.enable_quicklook
        enable_services = try c.decodeIfPresent(Bool.self, forKey: .enable_services) ?? d.enable_services
        enable_share_ext = try c.decodeIfPresent(Bool.self, forKey: .enable_share_ext) ?? d.enable_share_ext
    }

    public init(
        claimed_utis: [String] = SettingsDefaults.claimedUTIs,
        current_defaults: [String: String] = [:],
        enable_quicklook: Bool = true,
        enable_services: Bool = true,
        enable_share_ext: Bool = false
    ) {
        self.claimed_utis = claimed_utis
        self.current_defaults = current_defaults
        self.enable_quicklook = enable_quicklook
        self.enable_services = enable_services
        self.enable_share_ext = enable_share_ext
    }
}

public struct LanguageSettings: Codable, Equatable, Sendable {
    public var code: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = LanguageSettings()
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? d.code
    }

    public init(code: String = LanguageSettings.systemLanguageCode()) {
        self.code = code
    }

    public static func systemLanguageCode() -> String {
        Locale.current.identifier
    }

    private enum CodingKeys: String, CodingKey { case code }
}

public struct ColorPickerSettings: Codable, Equatable, Sendable {
    public var show_rgb_alpha: Bool
    public var show_hex_alpha: Bool
    public var show_hsl_alpha: Bool
    public var show_hsv_alpha: Bool
    public var show_cielab_alpha: Bool
    public var copy_format: ColorPickerCopyFormat
    public var show_in_panel: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ColorPickerSettings()
        show_rgb_alpha = try c.decodeIfPresent(Bool.self, forKey: .show_rgb_alpha) ?? d.show_rgb_alpha
        show_hex_alpha = try c.decodeIfPresent(Bool.self, forKey: .show_hex_alpha) ?? d.show_hex_alpha
        show_hsl_alpha = try c.decodeIfPresent(Bool.self, forKey: .show_hsl_alpha) ?? d.show_hsl_alpha
        show_hsv_alpha = try c.decodeIfPresent(Bool.self, forKey: .show_hsv_alpha) ?? d.show_hsv_alpha
        show_cielab_alpha = try c.decodeIfPresent(Bool.self, forKey: .show_cielab_alpha) ?? d.show_cielab_alpha
        copy_format = try c.decodeIfPresent(ColorPickerCopyFormat.self, forKey: .copy_format) ?? d.copy_format
        show_in_panel = try c.decodeIfPresent(Bool.self, forKey: .show_in_panel) ?? d.show_in_panel
    }

    public init(
        show_rgb_alpha: Bool = true,
        show_hex_alpha: Bool = true,
        show_hsl_alpha: Bool = true,
        show_hsv_alpha: Bool = true,
        show_cielab_alpha: Bool = true,
        copy_format: ColorPickerCopyFormat = .hex,
        show_in_panel: Bool = false
    ) {
        self.show_rgb_alpha = show_rgb_alpha
        self.show_hex_alpha = show_hex_alpha
        self.show_hsl_alpha = show_hsl_alpha
        self.show_hsv_alpha = show_hsv_alpha
        self.show_cielab_alpha = show_cielab_alpha
        self.copy_format = copy_format
        self.show_in_panel = show_in_panel
    }
}

public struct FrameNavSettings: Codable, Equatable, Sendable {
    public var show: Bool
    public var auto_play: Bool
    public var frame_step: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = FrameNavSettings()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        auto_play = try c.decodeIfPresent(Bool.self, forKey: .auto_play) ?? d.auto_play
        frame_step = try c.decodeIfPresent(Int.self, forKey: .frame_step) ?? d.frame_step
    }

    public init(show: Bool = false, auto_play: Bool = true, frame_step: Int = 1) {
        self.show = show
        self.auto_play = auto_play
        self.frame_step = frame_step
    }

    private enum CodingKeys: String, CodingKey { case show, auto_play, frame_step }
}

public struct ToolsSettings: Codable, Equatable, Sendable {
    public var crop: CropDefaults
    public var color_picker: ColorPickerSettings
    public var frame_nav: FrameNavSettings
    public var registered: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ToolsSettings()
        crop = try c.decodeIfPresent(CropDefaults.self, forKey: .crop) ?? d.crop
        color_picker = try c.decodeIfPresent(ColorPickerSettings.self, forKey: .color_picker) ?? d.color_picker
        frame_nav = try c.decodeIfPresent(FrameNavSettings.self, forKey: .frame_nav) ?? d.frame_nav
        registered = try c.decodeIfPresent([String].self, forKey: .registered) ?? d.registered
    }

    public init(
        crop: CropDefaults = CropDefaults(),
        color_picker: ColorPickerSettings = ColorPickerSettings(),
        frame_nav: FrameNavSettings = FrameNavSettings(),
        registered: [String] = []
    ) {
        self.crop = crop
        self.color_picker = color_picker
        self.frame_nav = frame_nav
        self.registered = registered
    }
}

public enum PluginCapability: String, Codable, Sendable {
    case tool, panel, formatDecoder, mcpTool, action, theme, language
}

public struct PluginRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var version: String
    public var author: String
    public var path: String
    public var capabilities: [PluginCapability]

    public init(bundleID: String, name: String, version: String, author: String, path: String, capabilities: [PluginCapability]) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.author = author
        self.path = path
        self.capabilities = capabilities
    }
}

public struct PluginsSettings: Codable, Equatable, Sendable {
    public var installed: [PluginRecord]
    public var enabled: Set<String>
    public var order: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = PluginsSettings()
        installed = try c.decodeIfPresent([PluginRecord].self, forKey: .installed) ?? d.installed
        enabled = try c.decodeIfPresent(Set<String>.self, forKey: .enabled) ?? d.enabled
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? d.order
    }

    public init(
        installed: [PluginRecord] = [],
        enabled: Set<String> = [],
        order: [String] = []
    ) {
        self.installed = installed
        self.enabled = enabled
        self.order = order
    }
}

public struct MCPAdvancedSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var transport: MCPTransport
    public var socket_path: String?
    public var http_port: Int?
    public var client_allowlist: [String]
    public var audit_log: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = MCPAdvancedSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        transport = try c.decodeIfPresent(MCPTransport.self, forKey: .transport) ?? d.transport
        socket_path = try c.decodeIfPresent(String.self, forKey: .socket_path) ?? d.socket_path
        http_port = try c.decodeIfPresent(Int.self, forKey: .http_port) ?? d.http_port
        client_allowlist = try c.decodeIfPresent([String].self, forKey: .client_allowlist) ?? d.client_allowlist
        audit_log = try c.decodeIfPresent(Bool.self, forKey: .audit_log) ?? d.audit_log
    }

    public init(
        enabled: Bool = true,
        transport: MCPTransport = .stdio,
        socket_path: String? = "~/Library/Application Support/ImageGlass_Mac/mcp.sock",
        http_port: Int? = nil,
        client_allowlist: [String] = ["*"],
        audit_log: Bool = true
    ) {
        self.enabled = enabled
        self.transport = transport
        self.socket_path = socket_path
        self.http_port = http_port
        self.client_allowlist = client_allowlist
        self.audit_log = audit_log
    }
}

public struct AdvancedSettings: Codable, Equatable, Sendable {
    public var debug_logging: Bool
    public var allow_unsigned_plugins: Bool
    public var mcp: MCPAdvancedSettings
    public var thumb_cache_mb: Int
    public var log_retention_days: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = AdvancedSettings()
        debug_logging = try c.decodeIfPresent(Bool.self, forKey: .debug_logging) ?? d.debug_logging
        allow_unsigned_plugins = try c.decodeIfPresent(Bool.self, forKey: .allow_unsigned_plugins) ?? d.allow_unsigned_plugins
        mcp = try c.decodeIfPresent(MCPAdvancedSettings.self, forKey: .mcp) ?? d.mcp
        thumb_cache_mb = try c.decodeIfPresent(Int.self, forKey: .thumb_cache_mb) ?? d.thumb_cache_mb
        log_retention_days = try c.decodeIfPresent(Int.self, forKey: .log_retention_days) ?? d.log_retention_days
    }

    public init(
        debug_logging: Bool = false,
        allow_unsigned_plugins: Bool = false,
        mcp: MCPAdvancedSettings = MCPAdvancedSettings(),
        thumb_cache_mb: Int = 1024,
        log_retention_days: Int = 14
    ) {
        self.debug_logging = debug_logging
        self.allow_unsigned_plugins = allow_unsigned_plugins
        self.mcp = mcp
        self.thumb_cache_mb = thumb_cache_mb
        self.log_retention_days = log_retention_days
    }
}

// MARK: - Actions

/// `docs/use_cases/actions.mdx` §10 — knobs for the file-action verbs
/// (Rename, Move to Trash, Copy Image, Copy File Path, Print).
public struct ActionsSettings: Codable, Equatable, Sendable {
    /// Show the confirmation dialog before *Move to Trash*. The dialog
    /// also has a "Don't ask again" checkbox that writes this key.
    public var confirm_move_to_trash: Bool
    /// When the user clears the extension while renaming, append the
    /// original extension on commit. Matches Finder behavior.
    public var rename_preserve_extension: Bool
    /// Toast feedback for *Copy Image* and *Copy File Path*. Off
    /// silences the toast but still emits the audit line.
    public var show_copy_toast: Bool
    /// Default copies for the MCP `print_current_image` tool when the
    /// caller does not supply `copies`.
    public var default_print_copies: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ActionsSettings()
        confirm_move_to_trash = try c.decodeIfPresent(Bool.self, forKey: .confirm_move_to_trash) ?? d.confirm_move_to_trash
        rename_preserve_extension = try c.decodeIfPresent(Bool.self, forKey: .rename_preserve_extension) ?? d.rename_preserve_extension
        show_copy_toast = try c.decodeIfPresent(Bool.self, forKey: .show_copy_toast) ?? d.show_copy_toast
        default_print_copies = try c.decodeIfPresent(Int.self, forKey: .default_print_copies) ?? d.default_print_copies
    }

    public init(
        confirm_move_to_trash: Bool = true,
        rename_preserve_extension: Bool = true,
        show_copy_toast: Bool = true,
        default_print_copies: Int = 1
    ) {
        self.confirm_move_to_trash = confirm_move_to_trash
        self.rename_preserve_extension = rename_preserve_extension
        self.show_copy_toast = show_copy_toast
        self.default_print_copies = default_print_copies
    }

    private enum CodingKeys: String, CodingKey {
        case confirm_move_to_trash, rename_preserve_extension
        case show_copy_toast, default_print_copies
    }
}

// MARK: - Root settings struct

public struct Settings: Codable, Equatable, Sendable {
    /// Schema version sentinel. Bumped when a breaking migration is required.
    public static let currentSchemaVersion: Int = 1

    public var version: Int
    public var general: GeneralSettings
    public var image: ImageSettings
    public var viewer: ViewerSettings
    public var appearance: AppearanceSettings
    public var layout: LayoutSettings
    public var slideshow: SlideshowSettings
    public var edit: EditSettings
    public var mouse: MouseSettings
    public var keyboard: KeyboardSettings
    public var gallery: GallerySettings
    public var toolbar: ToolbarSettings
    public var fileAssoc: FileAssocSettings
    public var language: LanguageSettings
    public var tools: ToolsSettings
    public var plugins: PluginsSettings
    public var advanced: AdvancedSettings
    /// `docs/use_cases/actions.mdx` §10 — file-action knobs.
    public var actions: ActionsSettings
    /// Multi-monitor window state. See `docs/multi_monitor.mdx`.
    public var window: WindowSettings

    public init(
        version: Int = Settings.currentSchemaVersion,
        general: GeneralSettings = .init(),
        image: ImageSettings = .init(),
        viewer: ViewerSettings = .init(),
        appearance: AppearanceSettings = .init(),
        layout: LayoutSettings = .init(),
        slideshow: SlideshowSettings = .init(),
        edit: EditSettings = .init(),
        mouse: MouseSettings = .init(),
        keyboard: KeyboardSettings = .init(),
        gallery: GallerySettings = .init(),
        toolbar: ToolbarSettings = .init(),
        fileAssoc: FileAssocSettings = .init(),
        language: LanguageSettings = .init(),
        tools: ToolsSettings = .init(),
        plugins: PluginsSettings = .init(),
        advanced: AdvancedSettings = .init(),
        actions: ActionsSettings = .init(),
        window: WindowSettings = .init()
    ) {
        self.version = version
        self.general = general
        self.image = image
        self.viewer = viewer
        self.appearance = appearance
        self.layout = layout
        self.slideshow = slideshow
        self.edit = edit
        self.mouse = mouse
        self.keyboard = keyboard
        self.gallery = gallery
        self.toolbar = toolbar
        self.fileAssoc = fileAssoc
        self.language = language
        self.tools = tools
        self.plugins = plugins
        self.advanced = advanced
        self.actions = actions
        self.window = window
    }

    /// Built-in defaults; equivalent to `Settings()` but kept for symmetry
    /// with `Config.builtIn`.
    public static let defaults: Settings = Settings()

    // Decoder is permissive — missing sections fall back to defaults so an
    // older `settings.json` (or a hand-edited one with one section dropped)
    // loads without throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        self.general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? d.general
        self.image = try c.decodeIfPresent(ImageSettings.self, forKey: .image) ?? d.image
        self.viewer = try c.decodeIfPresent(ViewerSettings.self, forKey: .viewer) ?? d.viewer
        self.appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? d.appearance
        self.layout = try c.decodeIfPresent(LayoutSettings.self, forKey: .layout) ?? d.layout
        self.slideshow = try c.decodeIfPresent(SlideshowSettings.self, forKey: .slideshow) ?? d.slideshow
        self.edit = try c.decodeIfPresent(EditSettings.self, forKey: .edit) ?? d.edit
        self.mouse = try c.decodeIfPresent(MouseSettings.self, forKey: .mouse) ?? d.mouse
        self.keyboard = try c.decodeIfPresent(KeyboardSettings.self, forKey: .keyboard) ?? d.keyboard
        self.gallery = try c.decodeIfPresent(GallerySettings.self, forKey: .gallery) ?? d.gallery
        self.toolbar = try c.decodeIfPresent(ToolbarSettings.self, forKey: .toolbar) ?? d.toolbar
        self.fileAssoc = try c.decodeIfPresent(FileAssocSettings.self, forKey: .fileAssoc) ?? d.fileAssoc
        self.language = try c.decodeIfPresent(LanguageSettings.self, forKey: .language) ?? d.language
        self.tools = try c.decodeIfPresent(ToolsSettings.self, forKey: .tools) ?? d.tools
        self.plugins = try c.decodeIfPresent(PluginsSettings.self, forKey: .plugins) ?? d.plugins
        self.advanced = try c.decodeIfPresent(AdvancedSettings.self, forKey: .advanced) ?? d.advanced
        self.actions = try c.decodeIfPresent(ActionsSettings.self, forKey: .actions) ?? d.actions
        self.window = try c.decodeIfPresent(WindowSettings.self, forKey: .window) ?? d.window
    }

    private enum CodingKeys: String, CodingKey {
        case version, general, image, viewer, appearance, layout, slideshow
        case edit, mouse, keyboard, gallery, toolbar
        case fileAssoc = "file_assoc"
        case language, tools, plugins, advanced, actions, window
    }
}

// MARK: - Defaults

public enum SettingsDefaults {

    public static let imageInfoTags: [String] = [
        "name", "size", "dimensions", "color_space",
        "exif_camera", "exif_lens",
        "exif_iso", "exif_shutter", "exif_aperture", "exif_focal_length",
        "exif_date_taken"
    ]

    public static let singleFrameFormats: [String] = [
        "avif", "heic", "heif", "psd", "jxl"
    ]

    public static let mouseClickActions: [String: String] = [
        "leftDoubleClick":     "toggleFullScreen",
        "middleClick":         "resetZoom",
        "backButtonClick":     "previousImage",
        "forwardButtonClick":  "nextImage",
        "ctrlLeftClick":       "showContextMenu",
        "optionLeftClick":     "startPan"
    ]

    public static let mouseWheelActions: [String: String] = [
        "scroll":        "browseImages",
        "commandScroll": "zoom",
        "optionScroll":  "pan",
        "shiftScroll":   "none"
    ]

    /// Default keybindings from Appendix D. Modifier names are stable strings
    /// that map to `EventModifierFlags` at runtime (see `Hotkey.modifiers`).
    public static let keybindings: [String: [Hotkey]] = [
        "openFile":          [Hotkey(key: "O", modifiers: ["command"])],
        "saveAs":            [Hotkey(key: "S", modifiers: ["command", "shift"])],
        "close":             [Hotkey(key: "W", modifiers: ["command"])],
        "previousImage":     [Hotkey(key: "ArrowLeft", modifiers: [])],
        "nextImage":         [Hotkey(key: "ArrowRight", modifiers: [])],
        "firstImage":        [Hotkey(key: "ArrowLeft", modifiers: ["option"])],
        "lastImage":         [Hotkey(key: "ArrowRight", modifiers: ["option"])],
        "zoomIn":            [Hotkey(key: "=", modifiers: ["command"])],
        "zoomOut":           [Hotkey(key: "-", modifiers: ["command"])],
        "resetZoom":         [Hotkey(key: "0", modifiers: ["command"])],
        "fitToWindow":       [Hotkey(key: "1", modifiers: ["command"])],
        "rotateLeft":        [Hotkey(key: "[", modifiers: ["command"])],
        "rotateRight":       [Hotkey(key: "]", modifiers: ["command"])],
        "flipHorizontal":    [Hotkey(key: "[", modifiers: ["command", "shift"])],
        "flipVertical":      [Hotkey(key: "]", modifiers: ["command", "shift"])],
        "toggleFullScreen":  [Hotkey(key: "F", modifiers: ["control", "command"])],
        // slideshow.mdx §0 / §1 / §10 — bare `S` is the focus-aware
        // viewer hotkey, `⌥⌘S` is the unconditional menu shortcut.
        // Two entries so a user-edited keyboard map can override either
        // without losing the other.
        "toggleSlideshow":   [
            Hotkey(key: "S", modifiers: []),
            Hotkey(key: "S", modifiers: ["command", "option"]),
        ],
        "toggleGallery":     [Hotkey(key: "L", modifiers: ["command"])],
        "toggleToolbar":     [Hotkey(key: "T", modifiers: ["option", "command"])],
        "togglePanelMode":   [Hotkey(key: "P", modifiers: ["control", "command"])],
        "openSettings":      [Hotkey(key: ",", modifiers: ["command"])],
        "search":            [Hotkey(key: "F", modifiers: ["command"])],
        "copy":              [Hotkey(key: "C", modifiers: ["command"])],
        "copyImageData":     [Hotkey(key: "C", modifiers: ["option", "command"])],
        "paste":             [Hotkey(key: "V", modifiers: ["command"])],
        "delete":            [Hotkey(key: "Backspace", modifiers: [])],
        "showInFinder":      [Hotkey(key: "R", modifiers: ["option", "command"])],
        "editIn":            [Hotkey(key: "E", modifiers: ["command"])],
        "cropTool":          [Hotkey(key: "K", modifiers: ["command"])],
        "colorPicker":       [Hotkey(key: "C", modifiers: ["command", "shift"])]
    ]

    public static let claimedUTIs: [String] = [
        "public.jpeg",
        "public.png",
        "public.tiff",
        "public.heic",
        "public.heif",
        "public.svg-image",
        "public.webp",
        "public.camera-raw-image",
        "org.aomedia.avif-image",
        "org.openjpeg.jpeg-xl",
        "com.adobe.photoshop-image",
        "com.compuserve.gif",
        "com.microsoft.bmp",
        "com.microsoft.ico",
        "com.apple.icns",
        "public.xbitmap-image",
        "public.mpo-image"
    ]

    public static let galleryThumbSizes: [Int] = [32, 48, 64, 96, 128, 192, 256, 384, 512]
    public static let toolbarIconHeights: [Int] = [16, 20, 24, 28, 32, 40, 48]
}
