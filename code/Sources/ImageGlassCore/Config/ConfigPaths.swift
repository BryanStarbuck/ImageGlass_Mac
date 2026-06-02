import Foundation

/// Resolves the on-disk locations of the three igconfig.* files described
/// in `docs/app-configs.mdx`.
///
/// There are two directories:
/// * **Startup Dir** — equivalent of the Windows install dir. On macOS this
///   is the directory containing the running executable (the binary inside
///   `ImageGlass.app/Contents/MacOS/`). Tests inject a custom path.
/// * **Config Dir** — `~/Library/Application Support/ImageGlass/` by
///   default, or the Startup Dir when **portable mode** is active.
///
/// Portable mode is detected by the presence of a file literally named
/// `portable.flag` next to the executable (in the Startup Dir).
public struct ConfigPaths: Sendable, Equatable {

    public static let defaultFileName  = "igconfig.default.json"
    public static let userFileName     = "igconfig.json"
    public static let adminFileName    = "igconfig.admin.json"
    public static let portableFlagName = "portable.flag"

    /// Where read-only / installer-managed files live (`igconfig.default.json`,
    /// `igconfig.admin.json`, and the `portable.flag` marker).
    public let startupDir: URL

    /// Where the live, user-writable `igconfig.json` lives. Equals
    /// `startupDir` when portable mode is active.
    public let configDir: URL

    /// `true` when the configuration is being stored next to the executable
    /// (USB-stick / per-machine install pattern from the spec).
    public let isPortable: Bool

    public init(startupDir: URL, configDir: URL, isPortable: Bool) {
        self.startupDir = startupDir
        self.configDir = configDir
        self.isPortable = isPortable
    }

    // MARK: - File URLs

    public var defaultFileURL: URL { startupDir.appendingPathComponent(Self.defaultFileName) }
    public var userFileURL:    URL { configDir.appendingPathComponent(Self.userFileName) }
    public var adminFileURL:   URL { startupDir.appendingPathComponent(Self.adminFileName) }
    public var portableFlagURL: URL { startupDir.appendingPathComponent(Self.portableFlagName) }

    // MARK: - Resolution

    /// Resolves the paths the running app should use.
    ///
    /// - Parameters:
    ///   - startupDir: Override for the Startup Dir. When `nil` the directory
    ///     containing the current executable is used.
    ///   - userConfigDir: Override for the (non-portable) Config Dir. When
    ///     `nil` the standard `Library/Application Support/ImageGlass`
    ///     location is used.
    public static func resolve(
        startupDir: URL? = nil,
        userConfigDir: URL? = nil
    ) -> ConfigPaths {
        let startup = startupDir ?? Self.defaultStartupDir()
        let portableMarker = startup.appendingPathComponent(portableFlagName)
        let portable = FileManager.default.fileExists(atPath: portableMarker.path)
        let cfgDir: URL
        if portable {
            cfgDir = startup
        } else {
            cfgDir = userConfigDir ?? AppPaths.appSupportDir
        }
        return ConfigPaths(startupDir: startup, configDir: cfgDir, isPortable: portable)
    }

    /// Best-effort detection of the directory holding the running binary.
    /// Falls back to the current working directory if the executable URL
    /// cannot be derived (e.g. running under `swift test`).
    public static func defaultStartupDir() -> URL {
        if let exePath = Bundle.main.executableURL?.deletingLastPathComponent() {
            return exePath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// Creates the Config Dir on disk if missing. The Startup Dir is assumed
    /// to be installer-managed and is **not** created.
    public func ensureConfigDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
    }
}
