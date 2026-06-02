import Foundation

/// Codable mirror of `~/Library/Application Support/ImageGlass/scopes/crop.json`.
/// Schema documented in `docs/crop.mdx` section 4.6.
public struct CropConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var aspectRatio: AspectRatio
    public var customAspect: [Int]              // [w, h]
    public var lockAspect: Bool
    public var gridMode: GridMode
    public var snapToPixel: Bool
    public var snapToEdges: Bool
    public var snapEdgeGravityPx: Int
    public var persistAcrossImages: Bool
    public var losslessJPEGWhenPossible: Bool
    public var stripMetadataOnSave: Bool
    public var closeToolAfterSaving: Bool
    public var defaultSelection: DefaultSelectionType
    public var lastUsedSelection: CropRect?
    public var outputDefaults: OutputDefaults

    public init(
        schemaVersion: Int = 1,
        aspectRatio: AspectRatio = .free,
        customAspect: [Int] = [16, 9],
        lockAspect: Bool = false,
        gridMode: GridMode = .thirds,
        snapToPixel: Bool = true,
        snapToEdges: Bool = false,
        snapEdgeGravityPx: Int = 8,
        persistAcrossImages: Bool = false,
        losslessJPEGWhenPossible: Bool = true,
        stripMetadataOnSave: Bool = false,
        closeToolAfterSaving: Bool = false,
        defaultSelection: DefaultSelectionType = .percent(0.5),
        lastUsedSelection: CropRect? = nil,
        outputDefaults: OutputDefaults = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.aspectRatio = aspectRatio
        self.customAspect = customAspect
        self.lockAspect = lockAspect
        self.gridMode = gridMode
        self.snapToPixel = snapToPixel
        self.snapToEdges = snapToEdges
        self.snapEdgeGravityPx = snapEdgeGravityPx
        self.persistAcrossImages = persistAcrossImages
        self.losslessJPEGWhenPossible = losslessJPEGWhenPossible
        self.stripMetadataOnSave = stripMetadataOnSave
        self.closeToolAfterSaving = closeToolAfterSaving
        self.defaultSelection = defaultSelection
        self.lastUsedSelection = lastUsedSelection
        self.outputDefaults = outputDefaults
    }

    public static let `default` = CropConfig()
}

// MARK: - Output Defaults

public struct OutputDefaults: Codable, Equatable, Sendable {
    public var jpeg: JPEGDefaults
    public var heic: HEICDefaults
    public var avif: AVIFDefaults
    public var webp: WebPDefaults
    public var png: PNGDefaults
    public var tiff: TIFFDefaults

    public init(
        jpeg: JPEGDefaults = .init(),
        heic: HEICDefaults = .init(),
        avif: AVIFDefaults = .init(),
        webp: WebPDefaults = .init(),
        png: PNGDefaults = .init(),
        tiff: TIFFDefaults = .init()
    ) {
        self.jpeg = jpeg
        self.heic = heic
        self.avif = avif
        self.webp = webp
        self.png = png
        self.tiff = tiff
    }
}

public struct JPEGDefaults: Codable, Equatable, Sendable {
    public var quality: Double
    public var progressive: Bool
    public var chroma: String
    public init(quality: Double = 0.92, progressive: Bool = true, chroma: String = "4:2:0") {
        self.quality = quality
        self.progressive = progressive
        self.chroma = chroma
    }
}

public struct HEICDefaults: Codable, Equatable, Sendable {
    public var quality: Double
    public var colorSpace: String
    public init(quality: Double = 0.85, colorSpace: String = "displayP3") {
        self.quality = quality
        self.colorSpace = colorSpace
    }
}

public struct AVIFDefaults: Codable, Equatable, Sendable {
    public var quality: Double
    public var speed: Int
    public init(quality: Double = 0.80, speed: Int = 6) {
        self.quality = quality
        self.speed = speed
    }
}

public struct WebPDefaults: Codable, Equatable, Sendable {
    public var quality: Double
    public var lossless: Bool
    public init(quality: Double = 0.88, lossless: Bool = false) {
        self.quality = quality
        self.lossless = lossless
    }
}

public struct PNGDefaults: Codable, Equatable, Sendable {
    public var interlaced: Bool
    public init(interlaced: Bool = false) { self.interlaced = interlaced }
}

public struct TIFFDefaults: Codable, Equatable, Sendable {
    public var compression: String
    public init(compression: String = "lzw") { self.compression = compression }
}

// MARK: - On-disk persistence

public enum CropConfigStore {
    /// `~/Library/Application Support/ImageGlass/scopes/crop.json`
    public static var fileURL: URL {
        AppPaths.scopesDir.appendingPathComponent("crop.json")
    }

    public static func load() -> CropConfig {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return .default
        }
        let dec = JSONDecoder()
        return (try? dec.decode(CropConfig.self, from: data)) ?? .default
    }

    public static func save(_ config: CropConfig) throws {
        try AppPaths.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
