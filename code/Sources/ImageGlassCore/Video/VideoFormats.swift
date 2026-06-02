import Foundation
import UniformTypeIdentifiers

/// What kind of media a file represents from the viewer's point of view.
///
/// The viewer dispatches to a different canvas per kind:
///   * `.image` → existing `ImageCanvasView` (AppKit + Core Image).
///   * `.video` → `VideoCanvasView` (AVKit `AVPlayerView`).
///   * `.svg`   → `SVGCanvasView`   (WKWebView for animated;
///                                   NSImage for the static fast-path).
///
/// `MediaKind.detect(at:)` reads the system `UTType` rather than trusting
/// the file extension alone — a `.dat` that is actually MPEG-4 routes to
/// the video canvas, and a misnamed `.png` that is actually SVG routes to
/// the SVG canvas.
public enum MediaKind: String, Sendable, Hashable {
    case image
    case video
    case svg
}

public extension MediaKind {

    /// Detect a file's media kind from its UTI and extension. Returns `.image`
    /// as the default — that matches the historical viewer behavior so any
    /// unknown file routes through the standard Image I/O pipeline.
    static func detect(at url: URL) -> MediaKind {
        // Fast path: the system already knows what this is.
        if let utType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if utType.conforms(to: .svg) { return .svg }
            if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                return .video
            }
            if utType.conforms(to: .image) { return .image }
        }
        // Fallback: trust the extension.
        let ext = url.pathExtension.lowercased()
        if VideoFormats.recognizedExtensions.contains(ext) { return .video }
        if ext == "svg" || ext == "svgz" { return .svg }
        return .image
    }

    /// Convenience overload taking a tilde-expanded or absolute POSIX path.
    static func detect(path: String) -> MediaKind {
        detect(at: URL(fileURLWithPath: AppPaths.expandTilde(path)))
    }
}

/// Container + codec matrix for the AVFoundation-backed video pipeline.
/// See `docs/videos.mdx §2`.
public enum VideoFormats {

    /// Container extensions (lowercased, no leading dot) recognized as
    /// video for the purpose of `MediaKind.detect`.
    public static let recognizedExtensions: Set<String> = [
        // Native AVFoundation containers.
        "mp4", "m4v", "mov", "qt",
        // 3GPP family — AVFoundation reads natively.
        "3gp", "3g2",
        // MPEG transport stream.
        "ts", "m2ts", "mts",
        // AVI — read via AVFoundation (codec-permitting).
        "avi",
        // Matroska / WebM — require the libavformat demuxer plugin
        // (Contents/PlugIns/MKVDemuxer.bundle, docs/videos.mdx §9).
        "mkv", "webm"
    ]

    /// Extensions that need the optional MKV / WebM demuxer plugin to load.
    /// When the plugin is absent we still recognize the file as video so
    /// the canvas can show the "preview unavailable" message instead of
    /// silently falling through to the image canvas.
    public static let pluginRequiredExtensions: Set<String> = ["mkv", "webm"]

    /// Container records (display name, extensions, plugin requirement).
    /// Surfaced by the Format Registry / Settings UI / MCP `video_describe`.
    public static let containers: [VideoContainer] = [
        .init(id: "mp4",  displayName: "MPEG-4",            extensions: ["mp4", "m4v"]),
        .init(id: "mov",  displayName: "QuickTime",         extensions: ["mov", "qt"]),
        .init(id: "3gp",  displayName: "3GPP",              extensions: ["3gp", "3g2"]),
        .init(id: "ts",   displayName: "MPEG Transport",    extensions: ["ts", "m2ts", "mts"]),
        .init(id: "avi",  displayName: "AVI",               extensions: ["avi"]),
        .init(id: "mkv",  displayName: "Matroska",          extensions: ["mkv"],
              requiresPlugin: true),
        .init(id: "webm", displayName: "WebM",              extensions: ["webm"],
              requiresPlugin: true)
    ]

    public static func container(for url: URL) -> VideoContainer? {
        let ext = url.pathExtension.lowercased()
        return containers.first { $0.extensions.contains(ext) }
    }

    public static func requiresPlugin(_ url: URL) -> Bool {
        pluginRequiredExtensions.contains(url.pathExtension.lowercased())
    }
}

public struct VideoContainer: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let extensions: [String]
    public let requiresPlugin: Bool

    public init(id: String,
                displayName: String,
                extensions: [String],
                requiresPlugin: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.extensions = extensions
        self.requiresPlugin = requiresPlugin
    }
}

/// Errors surfaced by the video subsystem. Strings are presented to the
/// user verbatim in the canvas's "preview unavailable" state.
public enum VideoError: Error, LocalizedError, Sendable {
    case unplayable(URL)
    case pluginRequired(URL)
    case loadFailed(URL, String)
    case snapshotFailed(URL, String)
    case noActiveItem

    public var errorDescription: String? {
        switch self {
        case .unplayable(let u):
            return "Video preview is unavailable for \(u.lastPathComponent): the file is not playable."
        case .pluginRequired(let u):
            let ext = u.pathExtension.uppercased()
            return "This video format (\(ext)) is not supported out of the box. " +
                   "Enable the MKV / WebM plugin in Settings ▸ Video to install it."
        case .loadFailed(let u, let why):
            return "Could not load \(u.lastPathComponent): \(why)"
        case .snapshotFailed(let u, let why):
            return "Could not snapshot a frame from \(u.lastPathComponent): \(why)"
        case .noActiveItem:
            return "No video is currently loaded."
        }
    }
}
