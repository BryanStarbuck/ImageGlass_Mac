import Foundation

/// Resolves the on-disk locations of the three igconfig.* files described
/// in `docs/app-configs.mdx`.
///
/// There are two directories:
/// * **Startup Dir** — equivalent of the Windows install dir. On macOS this
///   is the directory that contains the running `.app` bundle (typically
///   `/Applications/`). When running outside a bundle (CLI / tests) the
///   parent of the executable is used as a fallback.
/// * **Config Dir** — `~/Library/Application Support/ImageGlass/` by
///   default, or the Startup Dir when **portable mode** is active.
///
/// Portable mode is detected by the presence of a file literally named
/// `portable.flag` in the Startup Dir, OR — for installer-shipped builds —
/// inside the running bundle's `Contents/Resources/` directory.
///
/// Installer-shipped `igconfig.default.json` / `igconfig.admin.json` files
/// are looked up in the Startup Dir first; if absent, the bundle's
/// `Contents/Resources/` directory is consulted as a secondary location.
/// This matches the macOS convention where installer-managed resources
/// live inside the bundle, while the Windows convention puts them next to
/// the executable.
public struct ConfigPaths: Sendable, Equatable {

    public static let defaultFileName  = "igconfig.default.json"
    public static let userFileName     = "igconfig.json"
    public static let adminFileName    = "igconfig.admin.json"
    public static let portableFlagName = "portable.flag"

    /// Where read-only / installer-managed files live (`igconfig.default.json`,
    /// `igconfig.admin.json`, and the `portable.flag` marker).
    public let startupDir: URL

    /// Secondary read-only lookup location for installer-shipped files —
    /// typically the running bundle's `Contents/Resources/` directory. Nil
    /// when no bundle is detected (CLI / unit tests). When set, it is
    /// consulted only if the file is absent from `startupDir`.
    public let bundleResourcesDir: URL?

    /// Where the live, user-writable `igconfig.json` lives. Equals
    /// `startupDir` when portable mode is active.
    public let configDir: URL

    /// `true` when the configuration is being stored next to the executable
    /// (USB-stick / per-machine install pattern from the spec).
    public let isPortable: Bool

    public init(
        startupDir: URL,
        configDir: URL,
        isPortable: Bool,
        bundleResourcesDir: URL? = nil
    ) {
        self.startupDir = startupDir
        self.configDir = configDir
        self.isPortable = isPortable
        self.bundleResourcesDir = bundleResourcesDir
    }

    // MARK: - File URLs

    public var defaultFileURL: URL { startupDir.appendingPathComponent(Self.defaultFileName) }
    public var userFileURL:    URL { configDir.appendingPathComponent(Self.userFileName) }
    public var adminFileURL:   URL { startupDir.appendingPathComponent(Self.adminFileName) }
    public var portableFlagURL: URL { startupDir.appendingPathComponent(Self.portableFlagName) }

    /// Returns the URL the loader should actually read for a given installer
    /// file. Picks `startupDir`/<name> if it exists on disk; otherwise falls
    /// back to `bundleResourcesDir`/<name> (when set and present). Returns
    /// the `startupDir` URL if neither exists — callers detect missing files
    /// via `FileManager.fileExists(atPath:)`.
    public func installerFileURL(named name: String) -> URL {
        let primary = startupDir.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: primary.path) { return primary }
        if let res = bundleResourcesDir {
            let secondary = res.appendingPathComponent(name)
            if fm.fileExists(atPath: secondary.path) { return secondary }
        }
        return primary
    }

    /// Effective read URL for `igconfig.default.json` honoring the bundle
    /// fallback. Loaders should use this rather than `defaultFileURL`.
    public var effectiveDefaultFileURL: URL { installerFileURL(named: Self.defaultFileName) }

    /// Effective read URL for `igconfig.admin.json` honoring the bundle
    /// fallback. Loaders should use this rather than `adminFileURL`.
    public var effectiveAdminFileURL: URL { installerFileURL(named: Self.adminFileName) }

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
        userConfigDir: URL? = nil,
        bundleResourcesDir: URL? = nil
    ) -> ConfigPaths {
        let startup = startupDir ?? Self.defaultStartupDir()
        let bundleRes = bundleResourcesDir ?? Self.defaultBundleResourcesDir()
        let fm = FileManager.default
        // Portable mode is active when `portable.flag` is found either in
        // the Startup Dir or — for installer-shipped bundles — alongside
        // the default config inside `Contents/Resources/`.
        let portableInStartup = fm.fileExists(
            atPath: startup.appendingPathComponent(portableFlagName).path
        )
        let portableInBundle = bundleRes.map {
            fm.fileExists(atPath: $0.appendingPathComponent(portableFlagName).path)
        } ?? false
        let portable = portableInStartup || portableInBundle
        let cfgDir: URL
        if portable {
            cfgDir = startup
        } else {
            cfgDir = userConfigDir ?? AppPaths.appSupportDir
        }
        return ConfigPaths(
            startupDir: startup,
            configDir: cfgDir,
            isPortable: portable,
            bundleResourcesDir: bundleRes
        )
    }

    /// Best-effort detection of the macOS "install directory" — the
    /// directory containing the `.app` bundle on disk (e.g.
    /// `/Applications/`). Falls back to the executable's parent for
    /// non-bundled binaries, then to the current working directory.
    public static func defaultStartupDir() -> URL {
        // `Bundle.main.bundleURL` is the .app bundle URL when running
        // inside one, or the executable URL for CLI binaries. Stripping
        // one component yields the install directory in the bundle case,
        // and the executable's parent dir in the CLI case — exactly the
        // two locations the spec calls the "Startup Dir".
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }
        if let exePath = Bundle.main.executableURL?.deletingLastPathComponent() {
            return exePath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// Returns the running bundle's `Contents/Resources/` directory when
    /// the process is running inside a real `.app` bundle. Nil for CLI
    /// binaries and unit tests so they never accidentally read installer
    /// files out of the test runner's resource directory.
    public static func defaultBundleResourcesDir() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.resourceURL
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
