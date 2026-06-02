import Foundation

/// SVG preview preferences. Matches `docs/svg.mdx §7`.
public struct SVGSettings: Codable, Sendable, Equatable {
    public var autoplayOnSelect: Bool
    public var rememberLoopPerFile: Bool
    public var defaultLoop: Bool
    public var defaultRate: Double
    public var useFastStaticPathWhenSafe: Bool
    public var alwaysUseWebKit: Bool
    public var allowScriptsDefault: Bool
    public var background: String              // transparent, white, black, checker
    public var showViewBoxOutlineByDefault: Bool
    public var exportRasterDefaultScale: Double
    public var exportRasterDefaultFormat: String

    public init(
        autoplayOnSelect: Bool = true,
        rememberLoopPerFile: Bool = true,
        defaultLoop: Bool = false,
        defaultRate: Double = 1.0,
        useFastStaticPathWhenSafe: Bool = true,
        alwaysUseWebKit: Bool = false,
        allowScriptsDefault: Bool = false,
        background: String = "transparent",
        showViewBoxOutlineByDefault: Bool = false,
        exportRasterDefaultScale: Double = 2.0,
        exportRasterDefaultFormat: String = "png"
    ) {
        self.autoplayOnSelect = autoplayOnSelect
        self.rememberLoopPerFile = rememberLoopPerFile
        self.defaultLoop = defaultLoop
        self.defaultRate = defaultRate
        self.useFastStaticPathWhenSafe = useFastStaticPathWhenSafe
        self.alwaysUseWebKit = alwaysUseWebKit
        self.allowScriptsDefault = allowScriptsDefault
        self.background = background
        self.showViewBoxOutlineByDefault = showViewBoxOutlineByDefault
        self.exportRasterDefaultScale = exportRasterDefaultScale
        self.exportRasterDefaultFormat = exportRasterDefaultFormat
    }

    public static let defaults = SVGSettings()
}

public final class SVGSettingsStore: @unchecked Sendable {
    public static let shared = SVGSettingsStore()
    private let queue = DispatchQueue(label: "imageglass.svgsettings",
                                      qos: .userInitiated)

    private var fileURL: URL {
        AppPaths.macAppSupportDir.appendingPathComponent("svgSettings.json")
    }

    public init() {}

    public func load() -> SVGSettings {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return .defaults
            }
            do {
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder().decode(SVGSettings.self, from: data)
            } catch {
                ErrorLog.log("SVGSettingsStore.load failed", error: error,
                             class: "SVGSettingsStore")
                return .defaults
            }
        }
    }

    public func save(_ s: SVGSettings) {
        queue.sync {
            do {
                try AppPaths.ensureMacDirectories()
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys,
                                        .withoutEscapingSlashes]
                let data = try enc.encode(s)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                ErrorLog.log("SVGSettingsStore.save failed", error: error,
                             class: "SVGSettingsStore")
            }
        }
    }
}

/// Per-file overrides — keyed by absolute (tilde-encoded) path.
public struct SVGPerFileState: Codable, Sendable, Equatable {
    public var loop: Bool
    public var rate: Double
    public var allowScripts: Bool

    public init(loop: Bool = false,
                rate: Double = 1.0,
                allowScripts: Bool = false) {
        self.loop = loop
        self.rate = rate
        self.allowScripts = allowScripts
    }
}

public final class SVGPerFileStateStore: @unchecked Sendable {
    public static let shared = SVGPerFileStateStore()
    private let queue = DispatchQueue(label: "imageglass.svgperfilestate",
                                      qos: .userInitiated)
    private var cache: [String: SVGPerFileState] = [:]
    private var loaded = false

    private var fileURL: URL {
        AppPaths.macAppSupportDir.appendingPathComponent("svgState.json")
    }

    public init() {}

    public func get(for path: String) -> SVGPerFileState {
        queue.sync {
            loadIfNeededLocked()
            return cache[AppPaths.contractTilde(path)] ?? .init()
        }
    }

    public func set(_ state: SVGPerFileState, for path: String) {
        queue.sync {
            loadIfNeededLocked()
            cache[AppPaths.contractTilde(path)] = state
            persistLocked()
        }
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            cache = try JSONDecoder().decode([String: SVGPerFileState].self,
                                             from: data)
        } catch {
            ErrorLog.log("SVGPerFileStateStore.load failed", error: error,
                         class: "SVGPerFileStateStore")
        }
    }

    private func persistLocked() {
        do {
            try AppPaths.ensureMacDirectories()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
            let data = try enc.encode(cache)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ErrorLog.log("SVGPerFileStateStore.persist failed", error: error,
                         class: "SVGPerFileStateStore")
        }
    }
}
