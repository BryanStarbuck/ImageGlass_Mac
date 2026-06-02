import Foundation

/// Window backdrop style. Names match the spec's command-line example
/// (`/WindowBackdrop="Acrylic"`).
public enum WindowBackdrop: String, Codable, CaseIterable, Sendable {
    case none      = "None"
    case acrylic   = "Acrylic"
    case mica      = "Mica"
    case vibrant   = "Vibrant"
}

/// The merged effective configuration produced by `ConfigLoader`.
///
/// The set of fields tracks the named settings referenced from the spec
/// (`docs/app-configs.mdx`, `docs/command-line.mdx`, `docs/features.mdx`) —
/// `ShowToolbar`, `ShowGallery`, `WindowBackdrop`, `FullScreen`, plus a
/// handful of universally-needed knobs (`Theme`, `Language`, `ZoomMode`).
///
/// New keys can be added without breaking older `igconfig.json` files
/// because every property has a default and `Codable` skips unknown keys.
///
/// JSON keys use PascalCase to match the Windows ImageGlass `/Name=Value`
/// convention exactly — the spec example is
/// `/ShowToolbar=false /ShowGallery=false /WindowBackdrop="Acrylic"`.
public struct Config: Codable, Equatable, Sendable {

    public var showToolbar: Bool
    public var showGallery: Bool
    public var showStatusBar: Bool
    public var fullScreen: Bool
    public var frameless: Bool
    public var windowFit: Bool
    public var windowBackdrop: WindowBackdrop
    public var zoomMode: ZoomMode
    public var theme: String
    public var language: String
    public var startupBoost: Bool

    public init(
        showToolbar: Bool = true,
        showGallery: Bool = true,
        showStatusBar: Bool = true,
        fullScreen: Bool = false,
        frameless: Bool = false,
        windowFit: Bool = false,
        windowBackdrop: WindowBackdrop = .none,
        zoomMode: ZoomMode = .auto,
        theme: String = "Default",
        language: String = "en-US",
        startupBoost: Bool = false
    ) {
        self.showToolbar = showToolbar
        self.showGallery = showGallery
        self.showStatusBar = showStatusBar
        self.fullScreen = fullScreen
        self.frameless = frameless
        self.windowFit = windowFit
        self.windowBackdrop = windowBackdrop
        self.zoomMode = zoomMode
        self.theme = theme
        self.language = language
        self.startupBoost = startupBoost
    }

    /// Built-in developer defaults — priority tier 1 in the spec.
    public static let builtIn = Config()

    // MARK: - Coding

    // PascalCase on disk so `igconfig.json` files are interchangeable with
    // the Windows build's expectations and command-line override examples.
    private enum CodingKeys: String, CodingKey {
        case showToolbar     = "ShowToolbar"
        case showGallery     = "ShowGallery"
        case showStatusBar   = "ShowStatusBar"
        case fullScreen      = "FullScreen"
        case frameless       = "Frameless"
        case windowFit       = "WindowFit"
        case windowBackdrop  = "WindowBackdrop"
        case zoomMode        = "ZoomMode"
        case theme           = "Theme"
        case language        = "Language"
        case startupBoost    = "StartupBoost"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.builtIn
        self.showToolbar    = try c.decodeIfPresent(Bool.self, forKey: .showToolbar)   ?? d.showToolbar
        self.showGallery    = try c.decodeIfPresent(Bool.self, forKey: .showGallery)   ?? d.showGallery
        self.showStatusBar  = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? d.showStatusBar
        self.fullScreen     = try c.decodeIfPresent(Bool.self, forKey: .fullScreen)    ?? d.fullScreen
        self.frameless      = try c.decodeIfPresent(Bool.self, forKey: .frameless)     ?? d.frameless
        self.windowFit      = try c.decodeIfPresent(Bool.self, forKey: .windowFit)     ?? d.windowFit
        self.windowBackdrop = try c.decodeIfPresent(WindowBackdrop.self, forKey: .windowBackdrop) ?? d.windowBackdrop
        self.zoomMode       = try c.decodeIfPresent(ZoomMode.self, forKey: .zoomMode)  ?? d.zoomMode
        self.theme          = try c.decodeIfPresent(String.self, forKey: .theme)       ?? d.theme
        self.language       = try c.decodeIfPresent(String.self, forKey: .language)    ?? d.language
        self.startupBoost   = try c.decodeIfPresent(Bool.self, forKey: .startupBoost)  ?? d.startupBoost
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showToolbar,    forKey: .showToolbar)
        try c.encode(showGallery,    forKey: .showGallery)
        try c.encode(showStatusBar,  forKey: .showStatusBar)
        try c.encode(fullScreen,     forKey: .fullScreen)
        try c.encode(frameless,      forKey: .frameless)
        try c.encode(windowFit,      forKey: .windowFit)
        try c.encode(windowBackdrop, forKey: .windowBackdrop)
        try c.encode(zoomMode,       forKey: .zoomMode)
        try c.encode(theme,          forKey: .theme)
        try c.encode(language,       forKey: .language)
        try c.encode(startupBoost,   forKey: .startupBoost)
    }

    public static func == (lhs: Config, rhs: Config) -> Bool {
        lhs.showToolbar    == rhs.showToolbar
        && lhs.showGallery   == rhs.showGallery
        && lhs.showStatusBar == rhs.showStatusBar
        && lhs.fullScreen    == rhs.fullScreen
        && lhs.frameless     == rhs.frameless
        && lhs.windowFit     == rhs.windowFit
        && lhs.windowBackdrop == rhs.windowBackdrop
        && lhs.zoomMode      == rhs.zoomMode
        && lhs.theme         == rhs.theme
        && lhs.language      == rhs.language
        && lhs.startupBoost  == rhs.startupBoost
    }

    // MARK: - Sparse merge

    /// A sparse view of a `Config` — only fields explicitly present in a
    /// layer (file, CLI). Used so a layer that mentions just `ShowToolbar`
    /// does not silently overwrite `WindowBackdrop` with its built-in
    /// default when merged.
    public struct Partial: Codable, Equatable, Sendable {
        public var showToolbar:    Bool?
        public var showGallery:    Bool?
        public var showStatusBar:  Bool?
        public var fullScreen:     Bool?
        public var frameless:      Bool?
        public var windowFit:      Bool?
        public var windowBackdrop: WindowBackdrop?
        public var zoomMode:       ZoomMode?
        public var theme:          String?
        public var language:       String?
        public var startupBoost:   Bool?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case showToolbar     = "ShowToolbar"
            case showGallery     = "ShowGallery"
            case showStatusBar   = "ShowStatusBar"
            case fullScreen      = "FullScreen"
            case frameless       = "Frameless"
            case windowFit       = "WindowFit"
            case windowBackdrop  = "WindowBackdrop"
            case zoomMode        = "ZoomMode"
            case theme           = "Theme"
            case language        = "Language"
            case startupBoost    = "StartupBoost"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.showToolbar    = try c.decodeIfPresent(Bool.self, forKey: .showToolbar)
            self.showGallery    = try c.decodeIfPresent(Bool.self, forKey: .showGallery)
            self.showStatusBar  = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar)
            self.fullScreen     = try c.decodeIfPresent(Bool.self, forKey: .fullScreen)
            self.frameless      = try c.decodeIfPresent(Bool.self, forKey: .frameless)
            self.windowFit      = try c.decodeIfPresent(Bool.self, forKey: .windowFit)
            self.windowBackdrop = try c.decodeIfPresent(WindowBackdrop.self, forKey: .windowBackdrop)
            self.zoomMode       = try c.decodeIfPresent(ZoomMode.self, forKey: .zoomMode)
            self.theme          = try c.decodeIfPresent(String.self, forKey: .theme)
            self.language       = try c.decodeIfPresent(String.self, forKey: .language)
            self.startupBoost   = try c.decodeIfPresent(Bool.self, forKey: .startupBoost)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(showToolbar,    forKey: .showToolbar)
            try c.encodeIfPresent(showGallery,    forKey: .showGallery)
            try c.encodeIfPresent(showStatusBar,  forKey: .showStatusBar)
            try c.encodeIfPresent(fullScreen,     forKey: .fullScreen)
            try c.encodeIfPresent(frameless,      forKey: .frameless)
            try c.encodeIfPresent(windowFit,      forKey: .windowFit)
            try c.encodeIfPresent(windowBackdrop, forKey: .windowBackdrop)
            try c.encodeIfPresent(zoomMode,       forKey: .zoomMode)
            try c.encodeIfPresent(theme,          forKey: .theme)
            try c.encodeIfPresent(language,       forKey: .language)
            try c.encodeIfPresent(startupBoost,   forKey: .startupBoost)
        }

        /// `true` when no field has been set — used to short-circuit merging.
        public var isEmpty: Bool {
            showToolbar == nil && showGallery == nil && showStatusBar == nil
                && fullScreen == nil && frameless == nil && windowFit == nil
                && windowBackdrop == nil && zoomMode == nil
                && theme == nil && language == nil && startupBoost == nil
        }
    }

    /// Returns a copy with every non-nil field of `partial` applied on top.
    public func applying(_ partial: Partial) -> Config {
        var c = self
        if let v = partial.showToolbar    { c.showToolbar = v }
        if let v = partial.showGallery    { c.showGallery = v }
        if let v = partial.showStatusBar  { c.showStatusBar = v }
        if let v = partial.fullScreen     { c.fullScreen = v }
        if let v = partial.frameless      { c.frameless = v }
        if let v = partial.windowFit      { c.windowFit = v }
        if let v = partial.windowBackdrop { c.windowBackdrop = v }
        if let v = partial.zoomMode       { c.zoomMode = v }
        if let v = partial.theme          { c.theme = v }
        if let v = partial.language       { c.language = v }
        if let v = partial.startupBoost   { c.startupBoost = v }
        return c
    }
}
