import Foundation

/// Decodes base64-encoded image text into a `LoadedImage`. Spec calls this
/// out under "Special Input Methods" — useful when the user has copied
/// image bytes from a web tool, an API response, or a markdown blob.
///
/// The decoder accepts three convenience shapes:
///   1. Bare base64 (`iVBORw0KGgo...`)
///   2. Data URI (`data:image/png;base64,iVBORw0KGgo...`)
///   3. Whitespace-wrapped variants of the above (newlines from
///      `pbpaste`, copied email blobs, etc).
public enum Base64Loader {

    /// Best-effort: pull the base64 payload out of a string, strip whitespace
    /// and any `data:` URI prefix. Returns nil if no base64-looking content
    /// is found.
    public static func extractBase64Payload(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Strip Data URI prefix if present.
        let payload: String
        if let commaIdx = trimmed.range(of: ","),
           trimmed.lowercased().hasPrefix("data:") {
            payload = String(trimmed[commaIdx.upperBound...])
        } else {
            payload = trimmed
        }

        // Remove all whitespace characters (line breaks pasted from terminals).
        let stripped = payload.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let clean = String(String.UnicodeScalarView(stripped))
        return clean.isEmpty ? nil : clean
    }

    /// Decode `text` (raw base64 or data URI) into image bytes.
    public static func decodeData(from text: String) throws -> Data {
        guard let payload = extractBase64Payload(from: text) else {
            throw FormatLoaderError.invalidBase64
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            throw FormatLoaderError.invalidBase64
        }
        return data
    }

    /// Decode `text` and pipe the resulting bytes through `FormatLoader`.
    public static func loadFromBase64(text: String) throws -> LoadedImage {
        // §5.2 `Image.Load.Base64` — the user-perceived entry point for a
        // pasted base64 blob. The inner `FormatLoader.load(data:)` will
        // emit its own `Image.Load.<format>` + decode traces, nested
        // under this one.
        let _trace = PerformanceLog.shared.start(
            "Image.Load.Base64",
            extra: [
                ("source", "text"),
                ("text_chars", String(text.count)),
            ]
        )
        defer { _trace.finish() }
        let data = try decodeData(from: text)
        return try FormatLoader.load(data: data)
    }

    /// Convenience: read a `.txt` (or any text file) from disk, treat its
    /// contents as base64, and decode.
    public static func loadFromBase64File(url: URL) throws -> LoadedImage {
        // §5.2 `Image.Load.Base64` — file-on-disk variant. We instrument
        // the disk path separately so the analyzer can tell apart the
        // pasted vs. file-loaded base64 workflows.
        let _trace = PerformanceLog.shared.start(
            "Image.Load.Base64",
            extra: [
                ("source", "file"),
                ("path", url.path),
            ]
        )
        defer { _trace.finish() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FormatLoaderError.fileNotFound(url)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw FormatLoaderError.unreadable(url, underlying: error)
        }
        return try loadFromBase64(text: text)
    }
}
