import Foundation

/// Bitmask-style flags describing what ImageGlass can do with a given format.
/// Mirrors the capability matrix described in `docs/supported-formats.mdx`.
public struct FormatCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// We can decode pixels from this format.
    public static let read         = FormatCapabilities(rawValue: 1 << 0)
    /// We can encode pixels to this format.
    public static let write        = FormatCapabilities(rawValue: 1 << 1)
    /// The format can carry an animation (multiple frames + timing).
    public static let animated     = FormatCapabilities(rawValue: 1 << 2)
    /// The format can carry multiple still frames / pages (multi-page TIFF,
    /// PDF, PSD layers). Distinct from `.animated` — no per-frame timing.
    public static let multiFrame   = FormatCapabilities(rawValue: 1 << 3)
    /// The format is a vector / document container (SVG, PDF, EPS, AI).
    public static let vector       = FormatCapabilities(rawValue: 1 << 4)
    /// The format carries an alpha channel.
    public static let alpha        = FormatCapabilities(rawValue: 1 << 5)
    /// Loading this format requires an external delegate that is not
    /// shipped in-process today (ImageMagick, Ghostscript, libjxl ...).
    /// The spec calls out which formats fall here; `FormatLoader` will
    /// return `.requiresExternalDelegate` rather than attempting a load.
    public static let requiresExternalDelegate = FormatCapabilities(rawValue: 1 << 6)
}

/// Describes a single image format the app knows about.
/// One canonical entry per format; multiple file extensions can map to it.
public struct FormatInfo: Codable, Sendable, Hashable {
    /// Stable, lowercase, no-dot identifier (e.g. "jpeg", "heic", "svg").
    /// Used in MCP tool arguments and config files.
    public let id: String
    /// User-visible display name ("JPEG", "Adobe Photoshop").
    public let displayName: String
    /// Lowercased file extensions (no leading dot) that map to this format.
    /// First entry is the canonical extension used when saving.
    public let extensions: [String]
    /// Capabilities — read/write/animated/etc.
    public let capabilities: FormatCapabilities
    /// SF Symbol the UI layer can use for icons.
    public let icon: String
    /// Free-form note shown in settings / about pages. Used for spec
    /// references like "requires Ghostscript".
    public let note: String?

    public init(
        id: String,
        displayName: String,
        extensions: [String],
        capabilities: FormatCapabilities,
        icon: String = "photo",
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.extensions = extensions
        self.capabilities = capabilities
        self.icon = icon
        self.note = note
    }

    public var canRead: Bool { capabilities.contains(.read) }
    public var canWrite: Bool { capabilities.contains(.write) }
    public var isAnimated: Bool { capabilities.contains(.animated) }
    public var isMultiFrame: Bool { capabilities.contains(.multiFrame) }
    public var isVector: Bool { capabilities.contains(.vector) }
    public var needsExternalDelegate: Bool {
        capabilities.contains(.requiresExternalDelegate)
    }
}
