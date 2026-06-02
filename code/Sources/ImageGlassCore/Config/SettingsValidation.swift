import Foundation

/// Validation pipeline for `Settings`. The spec (§6) requires range,
/// enum, and cross-field invariant enforcement. Validation NEVER throws on
/// load — instead `clamp(_:)` mutates the struct in place to bring it back
/// into the legal envelope so a hand-edited file with an out-of-range value
/// still produces a usable session. The store calls `clamp` on every load
/// and on every write so MCP and GUI paths are consistent.
public enum SettingsValidation {

    public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
        public var description: String { "\(path): \(reason)" }
    }

    /// Validate without mutating. Returns the list of problems found.
    /// Empty array means the settings are fully spec-compliant.
    public static func validate(_ s: Settings) -> [ValidationError] {
        var errors: [ValidationError] = []

        // general
        if s.general.toast_duration_ms < 0 {
            errors.append(.init(path: "general.toast_duration_ms", reason: "must be >= 0"))
        }
        if s.general.quick_setup_version < 0 {
            errors.append(.init(path: "general.quick_setup_version", reason: "must be >= 0"))
        }

        // image
        if s.image.embedded_thumb_min_width < 0 {
            errors.append(.init(path: "image.embedded_thumb_min_width", reason: "must be >= 0"))
        }
        if s.image.embedded_thumb_min_height < 0 {
            errors.append(.init(path: "image.embedded_thumb_min_height", reason: "must be >= 0"))
        }

        // viewer
        if s.viewer.zoom_lock_percent <= 0 {
            errors.append(.init(path: "viewer.zoom_lock_percent", reason: "must be > 0"))
        }
        if s.viewer.cache_image_count < 0 {
            errors.append(.init(path: "viewer.cache_image_count", reason: "must be >= 0"))
        }
        if s.viewer.cache_max_dim < 256 {
            errors.append(.init(path: "viewer.cache_max_dim", reason: "must be >= 256"))
        }
        if s.viewer.cache_max_mb < 0 {
            errors.append(.init(path: "viewer.cache_max_mb", reason: "must be >= 0"))
        }
        if s.viewer.huge_image_threshold < 256 {
            errors.append(.init(path: "viewer.huge_image_threshold", reason: "must be >= 256"))
        }

        // slideshow
        if s.slideshow.interval_seconds <= 0 {
            errors.append(.init(path: "slideshow.interval_seconds", reason: "must be > 0"))
        }
        if s.slideshow.use_random_interval, s.slideshow.interval_to_seconds < s.slideshow.interval_seconds {
            errors.append(.init(
                path: "slideshow.interval_to_seconds",
                reason: "must be >= slideshow.interval_seconds when use_random_interval is true"
            ))
        }
        if s.slideshow.notify_every < 0 {
            errors.append(.init(path: "slideshow.notify_every", reason: "must be >= 0"))
        }

        // edit
        if s.edit.quality < 1 || s.edit.quality > 100 {
            errors.append(.init(path: "edit.quality", reason: "must be in 1...100"))
        }

        // gallery
        if !SettingsDefaults.galleryThumbSizes.contains(s.gallery.thumb_size) {
            errors.append(.init(
                path: "gallery.thumb_size",
                reason: "must be one of \(SettingsDefaults.galleryThumbSizes)"
            ))
        }
        if s.gallery.grid_columns < 1 {
            errors.append(.init(path: "gallery.grid_columns", reason: "must be >= 1"))
        }
        if s.gallery.disk_cache_mb < 0 {
            errors.append(.init(path: "gallery.disk_cache_mb", reason: "must be >= 0"))
        }

        // toolbar
        if !SettingsDefaults.toolbarIconHeights.contains(s.toolbar.icon_height) {
            errors.append(.init(
                path: "toolbar.icon_height",
                reason: "must be one of \(SettingsDefaults.toolbarIconHeights)"
            ))
        }

        // tools.crop
        if s.tools.crop.aspect_values.count != 2 {
            errors.append(.init(path: "tools.crop.aspect_values", reason: "must have exactly 2 entries"))
        }
        if s.tools.crop.init_rect.count != 4 {
            errors.append(.init(path: "tools.crop.init_rect", reason: "must have exactly 4 entries"))
        }
        if s.tools.crop.default_output_quality < 1 || s.tools.crop.default_output_quality > 100 {
            errors.append(.init(path: "tools.crop.default_output_quality", reason: "must be in 1...100"))
        }

        // tools.frame_nav
        if s.tools.frame_nav.frame_step < 1 {
            errors.append(.init(path: "tools.frame_nav.frame_step", reason: "must be >= 1"))
        }

        // advanced
        if s.advanced.thumb_cache_mb < 0 {
            errors.append(.init(path: "advanced.thumb_cache_mb", reason: "must be >= 0"))
        }
        if s.advanced.log_retention_days < 0 {
            errors.append(.init(path: "advanced.log_retention_days", reason: "must be >= 0"))
        }
        if let port = s.advanced.mcp.http_port, port < 1 || port > 65535 {
            errors.append(.init(path: "advanced.mcp.http_port", reason: "must be in 1...65535"))
        }

        return errors
    }

    /// Mutates `s` in place so every constraint is satisfied. Out-of-range
    /// numerics are clamped to their nearest legal value; unknown enum cases
    /// were already rejected by JSON decoding so they cannot reach this point.
    public static func clamp(_ s: inout Settings) {
        s.general.toast_duration_ms = max(0, s.general.toast_duration_ms)
        s.general.quick_setup_version = max(0, s.general.quick_setup_version)

        s.image.embedded_thumb_min_width = max(0, s.image.embedded_thumb_min_width)
        s.image.embedded_thumb_min_height = max(0, s.image.embedded_thumb_min_height)

        if s.viewer.zoom_lock_percent <= 0 { s.viewer.zoom_lock_percent = 100 }
        s.viewer.cache_image_count = max(0, s.viewer.cache_image_count)
        s.viewer.cache_max_dim = max(256, s.viewer.cache_max_dim)
        s.viewer.cache_max_mb = max(0, s.viewer.cache_max_mb)
        s.viewer.huge_image_threshold = max(256, s.viewer.huge_image_threshold)

        if s.slideshow.interval_seconds <= 0 { s.slideshow.interval_seconds = 5 }
        if s.slideshow.use_random_interval, s.slideshow.interval_to_seconds < s.slideshow.interval_seconds {
            s.slideshow.interval_to_seconds = s.slideshow.interval_seconds
        }
        s.slideshow.notify_every = max(0, s.slideshow.notify_every)

        s.edit.quality = min(100, max(1, s.edit.quality))

        if !SettingsDefaults.galleryThumbSizes.contains(s.gallery.thumb_size) {
            s.gallery.thumb_size = snapToNearest(s.gallery.thumb_size, in: SettingsDefaults.galleryThumbSizes)
        }
        s.gallery.grid_columns = max(1, s.gallery.grid_columns)
        s.gallery.disk_cache_mb = max(0, s.gallery.disk_cache_mb)

        if !SettingsDefaults.toolbarIconHeights.contains(s.toolbar.icon_height) {
            s.toolbar.icon_height = snapToNearest(s.toolbar.icon_height, in: SettingsDefaults.toolbarIconHeights)
        }

        // crop
        if s.tools.crop.aspect_values.count != 2 {
            s.tools.crop.aspect_values = [0, 0]
        }
        if s.tools.crop.init_rect.count != 4 {
            s.tools.crop.init_rect = [0, 0, 0, 0]
        }
        s.tools.crop.default_output_quality = min(100, max(1, s.tools.crop.default_output_quality))

        s.tools.frame_nav.frame_step = max(1, s.tools.frame_nav.frame_step)

        s.advanced.thumb_cache_mb = max(0, s.advanced.thumb_cache_mb)
        s.advanced.log_retention_days = max(0, s.advanced.log_retention_days)
        if let port = s.advanced.mcp.http_port, port < 1 || port > 65535 {
            s.advanced.mcp.http_port = nil
        }
    }

    private static func snapToNearest(_ value: Int, in allowed: [Int]) -> Int {
        guard !allowed.isEmpty else { return value }
        return allowed.min(by: { abs($0 - value) < abs($1 - value) }) ?? allowed[0]
    }
}
