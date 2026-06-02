import Foundation

/// On-disk persistence for `PanelLayout`. Spec §6.
///
/// File layout under `AppPaths.layoutDir`:
/// ```
/// layout/
///   layout.json          # current layout
///   layout.json.bak      # previous successful write
///   presets/
///     <name>.json        # user presets
/// ```
///
/// Writes use atomic-rename so a crash mid-write cannot corrupt the file
/// (spec §6.3). Reads validate the schema and fall back to `layout.json.bak`
/// and then to the default preset if both fail (spec §6.3, §2.1 Stability).
///
/// The store is implemented as a `final class` with no internal isolation:
/// file I/O on macOS HFS+/APFS is naturally atomic at the granularity this
/// caller uses (single read or `replaceItemAt` write), and the multi-writer
/// contention story is handled by `MCPLock` at the outer call site for tools
/// that mutate scope state.
public final class LayoutStore: @unchecked Sendable {
    public static let shared = LayoutStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Paths

    private var layoutFile: URL  { AppPaths.layoutFile }
    private var backupFile: URL  { AppPaths.layoutBackupFile }
    private var presetsDir: URL  { AppPaths.layoutPresetsDir }

    // MARK: - Load

    /// Load the layout from disk. If `layout.json` is missing or fails schema
    /// validation, fall back to `layout.json.bak`; if that also fails, return
    /// the built-in default preset and log the failure. Spec §6.3.
    public func load() -> PanelLayout {
        lock.lock()
        defer { lock.unlock() }
        try? AppPaths.ensureLayoutDirectories()
        if let layout = try? readFile(layoutFile), PanelLayoutValidator.validate(layout) == nil {
            return layout
        }
        if let layout = try? readFile(backupFile), PanelLayoutValidator.validate(layout) == nil {
            NSLog("ImageGlass: layout.json invalid — recovered from layout.json.bak")
            return layout
        }
        let dflt = PresetCatalog.defaultLayout
        try? writeFile(dflt, to: layoutFile)
        return dflt
    }

    /// Persist the layout. Validates first; throws if invalid (so a buggy
    /// caller never corrupts the on-disk state). Spec §6.3.
    public func save(_ layout: PanelLayout) throws {
        lock.lock()
        defer { lock.unlock() }
        if let reason = PanelLayoutValidator.validate(layout) {
            throw LayoutStoreError.invalidLayout(reason)
        }
        try AppPaths.ensureLayoutDirectories()
        if fm.fileExists(atPath: layoutFile.path) {
            try? fm.removeItem(at: backupFile)
            try? fm.copyItem(at: layoutFile, to: backupFile)
        }
        try writeFile(layout, to: layoutFile)
    }

    // MARK: - User presets

    public func listUserPresets() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        try? AppPaths.ensureLayoutDirectories()
        let urls = (try? fm.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Save a snapshot of `layout` as a named user preset. Refuses to overwrite
    /// a built-in preset name. Spec §9 (`save_current_layout`).
    public func saveUserPreset(name: String, layout: PanelLayout) throws {
        if PresetCatalog.isBuiltIn(name) {
            throw LayoutStoreError.builtInPresetName(name)
        }
        if name.isEmpty || name.contains("/") || name.hasPrefix(".") {
            throw LayoutStoreError.invalidPresetName(name)
        }
        lock.lock()
        defer { lock.unlock() }
        try AppPaths.ensureLayoutDirectories()
        var snapshot = layout
        snapshot.activePreset = name
        try writeFile(snapshot, to: presetsDir.appendingPathComponent("\(name).json"))
    }

    /// Delete a user preset. Refuses to delete a built-in preset. Spec §9.
    public func deleteUserPreset(name: String) throws {
        if PresetCatalog.isBuiltIn(name) {
            throw LayoutStoreError.builtInPresetName(name)
        }
        lock.lock()
        defer { lock.unlock() }
        let url = presetsDir.appendingPathComponent("\(name).json")
        if !fm.fileExists(atPath: url.path) {
            throw LayoutStoreError.unknownPreset(name)
        }
        try fm.removeItem(at: url)
    }

    public func loadUserPreset(name: String) throws -> PanelLayout {
        lock.lock()
        defer { lock.unlock() }
        let url = presetsDir.appendingPathComponent("\(name).json")
        if !fm.fileExists(atPath: url.path) {
            throw LayoutStoreError.unknownPreset(name)
        }
        return try readFile(url)
    }

    // MARK: - File I/O

    private func readFile(_ url: URL) throws -> PanelLayout {
        let data = try Data(contentsOf: url)
        return try decoder.decode(PanelLayout.self, from: data)
    }

    private func writeFile(_ layout: PanelLayout, to url: URL) throws {
        let data = try encoder.encode(layout)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

public enum LayoutStoreError: Error, CustomStringConvertible {
    case invalidLayout(String)
    case builtInPresetName(String)
    case invalidPresetName(String)
    case unknownPreset(String)

    public var description: String {
        switch self {
        case .invalidLayout(let reason): return "Layout is invalid: \(reason)"
        case .builtInPresetName(let n):  return "Preset name '\(n)' is reserved for a built-in preset."
        case .invalidPresetName(let n):  return "Preset name '\(n)' is invalid (no '/', leading dot, or empty)."
        case .unknownPreset(let n):      return "Preset not found: '\(n)'"
        }
    }
}
