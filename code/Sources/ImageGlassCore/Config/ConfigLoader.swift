import Foundation

/// Implements the three-tier configuration resolution described in
/// `docs/app-configs.mdx`.
///
/// Priority (lowest → highest):
///   1. Built-in developer defaults (`Config.builtIn`).
///   2. `igconfig.default.json` (Startup Dir).
///   3. `igconfig.json` (Config Dir).
///   4. Command-line `/Name=Value` overrides.
///   5. `igconfig.admin.json` (Startup Dir). **Highest — cannot be overridden.**
///
/// After resolving, the merged result is written back to `igconfig.json`
/// (Config Dir) so the next session starts from a coherent snapshot. The
/// write is atomic and the JSON is pretty-printed with sorted keys.
public final class ConfigLoader {

    public let paths: ConfigPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ConfigPaths) {
        self.paths = paths
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    // MARK: - Resolution result

    public struct Resolution: Equatable, Sendable {
        public let config: Config
        public let layers: Layers

        public struct Layers: Equatable, Sendable {
            public let builtIn: Config
            public let defaultFile: Config.Partial?   // nil when file missing
            public let userFile: Config.Partial?      // nil when file missing
            public let cli: Config.Partial            // empty when no overrides
            public let adminFile: Config.Partial?     // nil when file missing

            public init(
                builtIn: Config,
                defaultFile: Config.Partial?,
                userFile: Config.Partial?,
                cli: Config.Partial,
                adminFile: Config.Partial?
            ) {
                self.builtIn = builtIn
                self.defaultFile = defaultFile
                self.userFile = userFile
                self.cli = cli
                self.adminFile = adminFile
            }
        }
    }

    // MARK: - Public API

    /// Resolves the effective config without writing anything back.
    public func resolve(cli: CLIOverrides = CLIOverrides()) throws -> Resolution {
        let defaultLayer = try readPartial(at: paths.defaultFileURL)
        let userLayer    = try readPartial(at: paths.userFileURL)
        let adminLayer   = try readPartial(at: paths.adminFileURL)

        var merged = Config.builtIn
        if let d = defaultLayer { merged = merged.applying(d) }
        if let u = userLayer    { merged = merged.applying(u) }
        merged = merged.applying(cli.partial)
        if let a = adminLayer   { merged = merged.applying(a) }

        let layers = Resolution.Layers(
            builtIn: Config.builtIn,
            defaultFile: defaultLayer,
            userFile: userLayer,
            cli: cli.partial,
            adminFile: adminLayer
        )
        return Resolution(config: merged, layers: layers)
    }

    /// Resolves the effective config and writes the result to
    /// `igconfig.json` in the Config Dir.
    @discardableResult
    public func resolveAndPersist(cli: CLIOverrides = CLIOverrides()) throws -> Resolution {
        let r = try resolve(cli: cli)
        try save(r.config)
        return r
    }

    /// Writes `config` to `igconfig.json` atomically. Creates the Config Dir
    /// if needed.
    public func save(_ config: Config) throws {
        try paths.ensureConfigDir()
        let data = try encoder.encode(config)
        try data.write(to: paths.userFileURL, options: .atomic)
    }

    // MARK: - Internals

    /// Reads a single layer file as a `Config.Partial`. Returns `nil` if the
    /// file does not exist. Throws on malformed JSON so corrupt config can
    /// be surfaced to the user rather than silently swallowed.
    private func readPartial(at url: URL) throws -> Config.Partial? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Config.Partial.self, from: data)
    }
}
