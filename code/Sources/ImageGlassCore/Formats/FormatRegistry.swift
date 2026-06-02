import Foundation

/// The canonical list of image formats ImageGlass recognizes, plus a
/// user-extensible layer persisted in `formats.json`.
///
/// Spec: `docs/supported-formats.mdx`. Three buckets:
///   * Natively supported via macOS Image I/O (read/write):
///     JPEG, PNG, HEIC, GIF, TIFF, BMP, plus RAW formats Image I/O knows.
///   * Natively supported in read-only via Image I/O / built-in frameworks:
///     SVG (via WebKit/PDFKit fallback at the loader layer), WebP (Image I/O
///     on macOS 11+), HEIF.
///   * Requires-external-delegate stubs registered so MCP and UI can list
///     them but the loader returns a clean error:
///     JXL, AVIF, PSD (layers), AI, EPS, PDF, BPG, PS, FITS, HDR, EXR.
///
/// The registry is purely metadata; actual decoding lives in `FormatLoader`.
public final class FormatRegistry: @unchecked Sendable {

    public static let shared = FormatRegistry()

    private let queue = DispatchQueue(label: "imageglass.formatregistry", attributes: .concurrent)
    private var _builtins: [FormatInfo]
    private var _userExtras: [UserFormatEntry]
    private var didLoadUser = false

    public init() {
        self._builtins = Self.makeBuiltins()
        self._userExtras = []
    }

    // MARK: - Public API

    /// All known formats, builtins first, then user-added entries.
    public var all: [FormatInfo] {
        queue.sync {
            ensureUserLoadedLocked()
            return _builtins + _userExtras.map { $0.asFormatInfo() }
        }
    }

    /// Lookup by canonical id (case-insensitive).
    public func format(forId id: String) -> FormatInfo? {
        let key = id.lowercased()
        return all.first { $0.id == key }
    }

    /// Lookup by file extension (with or without leading dot, case-insensitive).
    public func format(forExtension ext: String) -> FormatInfo? {
        let key = normalize(ext)
        guard !key.isEmpty else { return nil }
        return all.first { $0.extensions.contains(key) }
    }

    /// Convenience: find the format that a file URL belongs to.
    public func format(forURL url: URL) -> FormatInfo? {
        format(forExtension: url.pathExtension)
    }

    /// All recognized extensions (lowercased, no leading dot), deduped.
    /// This is what Scope evaluation uses to filter directories.
    public func allExtensions() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for f in all {
            for e in f.extensions where seen.insert(e).inserted {
                out.append(e)
            }
        }
        return out
    }

    /// Default set of extensions for the starter Scope. Mirrors what the
    /// out-of-box reader handles cleanly: native + builtin formats only,
    /// dropping the requires-external-delegate ones.
    public func defaultScopeExtensions() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for f in _builtins where f.canRead && !f.needsExternalDelegate {
            for e in f.extensions where seen.insert(e).inserted {
                out.append(e)
            }
        }
        return out
    }

    public func isRecognized(extension ext: String) -> Bool {
        format(forExtension: ext) != nil
    }

    // MARK: - User extras (formats.json)

    /// Add a user-defined extra extension that maps to an existing format id,
    /// or registers a brand-new pass-through entry. Persists to disk.
    @discardableResult
    public func addUserExtension(_ ext: String, mappedTo formatId: String? = nil) throws -> UserFormatEntry {
        let cleanExt = normalize(ext)
        guard !cleanExt.isEmpty else {
            throw FormatRegistryError.invalidExtension(ext)
        }
        let entry = UserFormatEntry(
            ext: cleanExt,
            mapsTo: formatId?.lowercased(),
            displayName: nil
        )
        try queue.sync(flags: .barrier) {
            ensureUserLoadedLocked()
            // Skip duplicates.
            if !_userExtras.contains(where: { $0.ext == cleanExt }) {
                _userExtras.append(entry)
            }
            try persistUserLocked()
        }
        return entry
    }

    public func removeUserExtension(_ ext: String) throws {
        let cleanExt = normalize(ext)
        try queue.sync(flags: .barrier) {
            ensureUserLoadedLocked()
            _userExtras.removeAll { $0.ext == cleanExt }
            try persistUserLocked()
        }
    }

    public func userExtensions() -> [UserFormatEntry] {
        queue.sync {
            ensureUserLoadedLocked()
            return _userExtras
        }
    }

    /// Drop in-memory state. Used by tests after rebinding HOME.
    public func reload() {
        queue.sync(flags: .barrier) {
            _userExtras = []
            didLoadUser = false
            ensureUserLoadedLocked()
        }
    }

    // MARK: - Internals

    private func normalize(_ ext: String) -> String {
        var s = ext.lowercased()
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureUserLoadedLocked() {
        guard !didLoadUser else { return }
        didLoadUser = true
        let url = AppPaths.formatsFile
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(UserFormatsFile.self, from: data)
        else { return }
        _userExtras = decoded.extras
    }

    private func persistUserLocked() throws {
        try AppPaths.ensureDirectories()
        let url = AppPaths.formatsFile
        let payload = UserFormatsFile(extras: _userExtras)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Builtin Table

    /// Hand-curated builtin list. Capability flags follow the spec table.
    private static func makeBuiltins() -> [FormatInfo] {
        var out: [FormatInfo] = []

        // ----- Standard raster (native I/O) -----
        out.append(.init(
            id: "jpeg", displayName: "JPEG",
            extensions: ["jpg", "jpeg", "jpe", "jfif"],
            capabilities: [.read, .write],
            icon: "photo"
        ))
        out.append(.init(
            id: "png", displayName: "PNG",
            extensions: ["png", "apng"],
            capabilities: [.read, .write, .animated, .alpha],
            icon: "photo"
        ))
        out.append(.init(
            id: "gif", displayName: "GIF",
            extensions: ["gif"],
            capabilities: [.read, .write, .animated, .alpha],
            icon: "photo"
        ))
        out.append(.init(
            id: "tiff", displayName: "TIFF",
            extensions: ["tif", "tiff"],
            capabilities: [.read, .write, .multiFrame, .alpha],
            icon: "photo"
        ))
        out.append(.init(
            id: "bmp", displayName: "BMP",
            extensions: ["bmp", "dib"],
            capabilities: [.read, .write],
            icon: "photo"
        ))

        // ----- Modern raster -----
        out.append(.init(
            id: "heic", displayName: "HEIC / HEIF",
            extensions: ["heic", "heif"],
            capabilities: [.read, .write, .alpha],
            icon: "photo",
            note: "Built-in via Image I/O. Non-animated only."
        ))
        out.append(.init(
            id: "webp", displayName: "WebP",
            extensions: ["webp"],
            capabilities: [.read, .animated, .alpha],
            icon: "photo",
            note: "Read via Image I/O (macOS 11+). Animated WebP supported."
        ))
        out.append(.init(
            id: "jxl", displayName: "JPEG XL",
            extensions: ["jxl"],
            capabilities: [.read, .alpha, .requiresExternalDelegate],
            icon: "photo",
            note: "Requires external delegate (libjxl) — not bundled."
        ))
        out.append(.init(
            id: "avif", displayName: "AVIF",
            extensions: ["avif"],
            capabilities: [.read, .alpha, .requiresExternalDelegate],
            icon: "photo",
            note: "Native Image I/O support on macOS 13+, fallback otherwise."
        ))

        // ----- Vector / document -----
        out.append(.init(
            id: "svg", displayName: "SVG",
            extensions: ["svg", "svgz"],
            capabilities: [.read, .vector, .alpha, .animated],
            icon: "vector.path",
            note: "Rendered via WebKit; animations supported."
        ))
        out.append(.init(
            id: "pdf", displayName: "PDF",
            extensions: ["pdf"],
            capabilities: [.read, .vector, .multiFrame],
            icon: "doc.richtext",
            note: "Renders via PDFKit (built-in); editing requires Ghostscript."
        ))
        out.append(.init(
            id: "ai", displayName: "Adobe Illustrator",
            extensions: ["ai"],
            capabilities: [.read, .vector, .requiresExternalDelegate],
            icon: "vector.path",
            note: "Requires Ghostscript."
        ))
        out.append(.init(
            id: "eps", displayName: "Encapsulated PostScript",
            extensions: ["eps"],
            capabilities: [.read, .vector, .requiresExternalDelegate],
            icon: "vector.path",
            note: "Requires Ghostscript."
        ))
        out.append(.init(
            id: "ps", displayName: "PostScript",
            extensions: ["ps"],
            capabilities: [.read, .vector, .requiresExternalDelegate],
            icon: "doc.richtext",
            note: "Requires Ghostscript."
        ))

        // ----- Specialized / professional -----
        out.append(.init(
            id: "psd", displayName: "Photoshop",
            extensions: ["psd", "psb"],
            capabilities: [.read, .multiFrame, .alpha, .requiresExternalDelegate],
            icon: "paintbrush",
            note: "Flat composite via Image I/O; layered decoding requires ImageMagick."
        ))
        out.append(.init(
            id: "ico", displayName: "Windows Icon",
            extensions: ["ico", "cur"],
            capabilities: [.read, .multiFrame, .alpha],
            icon: "photo"
        ))
        out.append(.init(
            id: "qoi", displayName: "Quite OK Image",
            extensions: ["qoi"],
            capabilities: [.read, .alpha, .requiresExternalDelegate],
            icon: "photo",
            note: "Requires external decoder."
        ))
        out.append(.init(
            id: "fits", displayName: "FITS (astronomy)",
            extensions: ["fits", "fit", "fts"],
            capabilities: [.read, .requiresExternalDelegate],
            icon: "sparkles",
            note: "Requires ImageMagick delegate."
        ))
        out.append(.init(
            id: "hdr", displayName: "Radiance HDR",
            extensions: ["hdr", "rgbe"],
            capabilities: [.read, .requiresExternalDelegate],
            icon: "sun.max",
            note: "Requires external decoder."
        ))
        out.append(.init(
            id: "exr", displayName: "OpenEXR",
            extensions: ["exr"],
            capabilities: [.read, .alpha, .requiresExternalDelegate],
            icon: "sparkles",
            note: "Requires external decoder."
        ))
        out.append(.init(
            id: "bpg", displayName: "Better Portable Graphics",
            extensions: ["bpg"],
            capabilities: [.read, .alpha, .requiresExternalDelegate],
            icon: "photo",
            note: "Requires BPG tools."
        ))

        // ----- RAW (camera) — handled natively by Image I/O on macOS -----
        // We register the major extensions; Image I/O's RAW decoder handles
        // the actual pixel pull. Capability is read-only.
        let rawExts = [
            "arw", "cr2", "cr3", "crw", "dng", "erf", "fff", "mef",
            "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw",
            "rw2", "rwl", "sr2", "srf", "srw", "x3f", "3fr", "kdc"
        ]
        out.append(.init(
            id: "raw", displayName: "Camera RAW",
            extensions: rawExts,
            capabilities: [.read],
            icon: "camera",
            note: "Decoded via Image I/O RAW support; exact list depends on macOS version."
        ))

        return out
    }
}

// MARK: - Errors

public enum FormatRegistryError: Error, LocalizedError {
    case invalidExtension(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtension(let s):
            return "Invalid file extension: '\(s)'"
        }
    }
}

// MARK: - Persisted user extras file

/// Single entry in `formats.json` describing a user-added extension.
public struct UserFormatEntry: Codable, Sendable, Hashable {
    public let ext: String
    /// Optional canonical format id this extension routes to. If nil, the
    /// loader treats the file as a generic Image I/O blob and reports an
    /// unknown format type.
    public let mapsTo: String?
    /// Optional friendly name (e.g. "Acme RAW").
    public let displayName: String?

    public init(ext: String, mapsTo: String? = nil, displayName: String? = nil) {
        self.ext = ext
        self.mapsTo = mapsTo
        self.displayName = displayName
    }

    func asFormatInfo() -> FormatInfo {
        FormatInfo(
            id: mapsTo ?? "user_\(ext)",
            displayName: displayName ?? "Custom (\(ext.uppercased()))",
            extensions: [ext],
            capabilities: [.read],
            icon: "photo",
            note: "User-added extension."
        )
    }
}

/// On-disk file shape for `formats.json`.
public struct UserFormatsFile: Codable, Sendable {
    public var extras: [UserFormatEntry]
    public init(extras: [UserFormatEntry] = []) {
        self.extras = extras
    }
}
