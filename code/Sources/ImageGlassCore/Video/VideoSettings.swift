import Foundation

/// Persisted video preview preferences. Matches `docs/videos.mdx §7`.
///
/// Stored at `~/Library/Application Support/ImageGlass_Mac/videoSettings.json`
/// — the Mac-fork directory, distinct from the upstream-compatible
/// `appSupportDir` so MCP edits land in a stable, well-known location.
public struct VideoSettings: Codable, Sendable, Equatable {
    public var autoplayOnSelect: Bool
    public var rememberLoopPerFile: Bool
    public var defaultLoop: Bool
    public var defaultMuted: Bool
    public var defaultRate: Double
    public var snapshotFormat: String          // "png", "jpeg", "tiff"
    public var snapshotDir: String             // tilde-encoded
    public var transportBarFadeDelay: Double   // seconds
    public var hardwareDecodePreferred: Bool
    public var hdrToneMapping: String          // "system", "off", "force"
    public var mkvSupportEnabled: Bool
    public var showTimecodeOverlay: Bool

    public init(
        autoplayOnSelect: Bool = true,
        rememberLoopPerFile: Bool = true,
        defaultLoop: Bool = false,
        defaultMuted: Bool = false,
        defaultRate: Double = 1.0,
        snapshotFormat: String = "png",
        snapshotDir: String = "~/Pictures/ImageGlass_Mac/Snapshots",
        transportBarFadeDelay: Double = 2.5,
        hardwareDecodePreferred: Bool = true,
        hdrToneMapping: String = "system",
        mkvSupportEnabled: Bool = false,
        showTimecodeOverlay: Bool = false
    ) {
        self.autoplayOnSelect = autoplayOnSelect
        self.rememberLoopPerFile = rememberLoopPerFile
        self.defaultLoop = defaultLoop
        self.defaultMuted = defaultMuted
        self.defaultRate = defaultRate
        self.snapshotFormat = snapshotFormat
        self.snapshotDir = snapshotDir
        self.transportBarFadeDelay = transportBarFadeDelay
        self.hardwareDecodePreferred = hardwareDecodePreferred
        self.hdrToneMapping = hdrToneMapping
        self.mkvSupportEnabled = mkvSupportEnabled
        self.showTimecodeOverlay = showTimecodeOverlay
    }

    public static let defaults = VideoSettings()
}

/// Disk-backed loader / saver. Reads on bootstrap, writes atomically on
/// every mutation so the file on disk always matches the running state —
/// the Local-Storage / MCP-edit contract from
/// `docs/local_storage.mdx` and `docs/mcp.mdx`.
public final class VideoSettingsStore: @unchecked Sendable {

    public static let shared = VideoSettingsStore()

    private let queue = DispatchQueue(label: "imageglass.videosettings",
                                      qos: .userInitiated)

    private var fileURL: URL {
        AppPaths.macAppSupportDir.appendingPathComponent("videoSettings.json")
    }

    public init() {}

    public func load() -> VideoSettings {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return .defaults
            }
            do {
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder().decode(VideoSettings.self, from: data)
            } catch {
                ErrorLog.log("VideoSettingsStore.load failed", error: error,
                             class: "VideoSettingsStore")
                return .defaults
            }
        }
    }

    public func save(_ settings: VideoSettings) {
        queue.sync {
            do {
                try AppPaths.ensureMacDirectories()
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys,
                                        .withoutEscapingSlashes]
                let data = try enc.encode(settings)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                ErrorLog.log("VideoSettingsStore.save failed", error: error,
                             class: "VideoSettingsStore")
            }
        }
    }
}

/// Per-file overrides — keyed by absolute (tilde-encoded) file path. Backs
/// the "Remember Loop" behavior from `docs/videos.mdx §5.1`. Stored
/// alongside `videoSettings.json` as `videoState.yaml`-equivalent JSON
/// (we use JSON not YAML to stay aligned with the `Codable` everything-
/// is-JSON convention; the spec name "videoState.yaml" is descriptive).
public struct VideoPerFileState: Codable, Sendable, Equatable {
    public var loop: Bool
    public var muted: Bool
    public var rate: Double

    public init(loop: Bool = false, muted: Bool = false, rate: Double = 1.0) {
        self.loop = loop
        self.muted = muted
        self.rate = rate
    }
}

public final class VideoPerFileStateStore: @unchecked Sendable {

    public static let shared = VideoPerFileStateStore()

    private let queue = DispatchQueue(label: "imageglass.videoperfilestate",
                                      qos: .userInitiated)
    private var cache: [String: VideoPerFileState] = [:]
    private var loaded = false

    private var fileURL: URL {
        AppPaths.macAppSupportDir.appendingPathComponent("videoState.json")
    }

    public init() {}

    public func get(for path: String) -> VideoPerFileState {
        queue.sync {
            loadIfNeededLocked()
            return cache[AppPaths.contractTilde(path)] ?? .init()
        }
    }

    public func set(_ state: VideoPerFileState, for path: String) {
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
            cache = try JSONDecoder().decode([String: VideoPerFileState].self,
                                             from: data)
        } catch {
            ErrorLog.log("VideoPerFileStateStore.load failed", error: error,
                         class: "VideoPerFileStateStore")
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
            ErrorLog.log("VideoPerFileStateStore.persist failed", error: error,
                         class: "VideoPerFileStateStore")
        }
    }
}
