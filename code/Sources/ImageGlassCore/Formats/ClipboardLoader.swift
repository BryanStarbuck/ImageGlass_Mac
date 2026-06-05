#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Loads images from the system pasteboard. Spec §"Special Input Methods":
/// ImageGlass should accept clipboard image data, pasted file paths, and
/// raw bitmaps via `Ctrl+V` (mapped to `Cmd+V` on macOS).
public enum ClipboardLoader {

    /// Result of inspecting the pasteboard.
    public struct PasteResult: @unchecked Sendable {
        /// Image successfully decoded from clipboard bytes / a referenced file.
        public let image: LoadedImage?
        /// File URLs found on the pasteboard (single or multi-file paste).
        public let fileURLs: [URL]
        /// Source kind of `image` for debugging / UI hints.
        public let source: Source

        public enum Source: String, Sendable {
            case none
            case fileURL
            case imageData
            case rawBitmap
        }

        public init(image: LoadedImage?, fileURLs: [URL], source: Source) {
            self.image = image
            self.fileURLs = fileURLs
            self.source = source
        }
    }

    /// Inspect the system pasteboard and return whatever image-like payload
    /// it contains. Tries, in order:
    ///   1. NSURL file references (pick the first whose extension we recognize).
    ///   2. PNG / TIFF / JPEG data blobs.
    ///   3. NSImage representation (raw bitmap path).
    /// Returns `PasteResult` with `image == nil` if nothing usable is found.
    #if canImport(AppKit)
    @MainActor
    public static func loadFromClipboard(
        pasteboard: NSPasteboard = .general
    ) -> PasteResult {
        // §5.2 `Image.Load.Clipboard` — the user-perceived clipboard paste
        // path. Nested `Image.Load.<format>` + decode traces emitted by
        // `FormatLoader` will appear inside this interval.
        let _trace = PerformanceLog.shared.start("Image.Load.Clipboard")
        defer { _trace.finish() }
        // (1) File URLs.
        let urls = readFileURLs(pasteboard)
        if let firstImageURL = urls.first(where: { FormatRegistry.shared.format(forURL: $0) != nil }) {
            do {
                let loaded = try FormatLoader.load(url: firstImageURL)
                return PasteResult(image: loaded, fileURLs: urls, source: .fileURL)
            } catch {
                ErrorLog.log("failed to decode clipboard file URL \(firstImageURL.path)",
                             error: error,
                             class: "ClipboardLoader")
            }
        }

        // (2) Image data blobs in a known wire format.
        if let (data, ext) = readImageDataBlob(pasteboard) {
            do {
                let loaded = try FormatLoader.load(data: data, hintedExtension: ext)
                return PasteResult(image: loaded, fileURLs: urls, source: .imageData)
            } catch {
                ErrorLog.log("failed to decode clipboard image data (hint=\(ext))",
                             error: error,
                             class: "ClipboardLoader")
            }
        }

        // (3) Raw bitmap → re-encode to PNG and decode through the loader.
        if let bitmap = readNSImage(pasteboard),
           let tiff = bitmap.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            do {
                let loaded = try FormatLoader.load(data: png, hintedExtension: "png")
                return PasteResult(image: loaded, fileURLs: urls, source: .rawBitmap)
            } catch {
                ErrorLog.log("failed to decode raw bitmap from clipboard",
                             error: error,
                             class: "ClipboardLoader")
            }
        }

        return PasteResult(image: nil, fileURLs: urls, source: .none)
    }

    @MainActor
    private static func readFileURLs(_ pb: NSPasteboard) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objs = pb.readObjects(forClasses: [NSURL.self], options: opts) ?? []
        return objs.compactMap { ($0 as? URL)?.standardizedFileURL }
    }

    @MainActor
    private static func readImageDataBlob(_ pb: NSPasteboard) -> (Data, String)? {
        // Order matters — PNG first because Cmd+Shift+4 screenshots land there.
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (.tiff, "tiff"),
            (.init("public.jpeg"), "jpg"),
            (.init("public.heic"), "heic"),
        ]
        for (type, ext) in candidates {
            if let data = pb.data(forType: type), !data.isEmpty {
                return (data, ext)
            }
        }
        return nil
    }

    @MainActor
    private static func readNSImage(_ pb: NSPasteboard) -> NSImage? {
        let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) ?? []
        return objs.first as? NSImage
    }
    #endif

    /// Pure-data fallback for non-AppKit contexts (tests, MCP server).
    /// Given a raw blob the caller already obtained, decode it through
    /// `FormatLoader`.
    public static func loadFromData(_ data: Data, hintedExtension: String? = nil) throws -> LoadedImage {
        return try FormatLoader.load(data: data, hintedExtension: hintedExtension)
    }
}
