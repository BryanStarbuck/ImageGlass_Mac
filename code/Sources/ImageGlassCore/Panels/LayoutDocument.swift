import Foundation

/// In-memory representation of the on-disk `layout.json`.
///
/// The file lives at:
///   ~/Library/Application Support/ImageGlass/layout.json
///
/// (The fork charter requires plain text on disk; JSON is plain text.)
///
/// Forward-compatibility rule from `docs/panels.mdx` §3.4: unknown top-level
/// fields are preserved on read and written back on save. We honor this by
/// keeping a side-bag of `unknown` JSON keys that round-trip untouched.
public struct LayoutDocument: Sendable {

    public static let currentVersion = 1

    public var version: Int
    public var activePresetId: String
    public var presets: [LayoutPreset]
    public var userPresets: [LayoutPreset]
    public var tabGroups: [[String]]
    public var lastSavedAt: Date?

    /// Any top-level JSON keys we did not recognize on read. Preserved verbatim
    /// so writing a doc loaded from a newer ImageGlass does not lose data.
    public var unknownFields: [String: AnyCodable]

    public init(
        version: Int = LayoutDocument.currentVersion,
        activePresetId: String = LayoutPreset.browser.id,
        presets: [LayoutPreset] = LayoutPreset.builtinPresets,
        userPresets: [LayoutPreset] = [],
        tabGroups: [[String]] = [],
        lastSavedAt: Date? = nil,
        unknownFields: [String: AnyCodable] = [:]
    ) {
        self.version = version
        self.activePresetId = activePresetId
        self.presets = presets
        self.userPresets = userPresets
        self.tabGroups = tabGroups
        self.lastSavedAt = lastSavedAt
        self.unknownFields = unknownFields
    }

    /// First-launch default — built-in presets, "browser" active, no user state.
    public static var initial: LayoutDocument { LayoutDocument() }
}

// MARK: - Codable with unknown-field preservation

extension LayoutDocument: Codable {

    /// Keys we explicitly model. Anything else falls into `unknownFields`.
    private static let knownKeys: Set<String> = [
        "$schema",
        "version",
        "activePresetId",
        "presets",
        "userPresets",
        "tabGroups",
        "lastSavedAt",
    ]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        self.version = (try? container.decode(Int.self, forKey: DynamicKey(stringValue: "version")!))
            ?? LayoutDocument.currentVersion
        self.activePresetId = (try? container.decode(String.self,
            forKey: DynamicKey(stringValue: "activePresetId")!))
            ?? LayoutPreset.browser.id
        self.presets = (try? container.decode([LayoutPreset].self,
            forKey: DynamicKey(stringValue: "presets")!))
            ?? LayoutPreset.builtinPresets
        self.userPresets = (try? container.decode([LayoutPreset].self,
            forKey: DynamicKey(stringValue: "userPresets")!))
            ?? []
        self.tabGroups = (try? container.decode([[String]].self,
            forKey: DynamicKey(stringValue: "tabGroups")!))
            ?? []
        self.lastSavedAt = try? container.decode(Date.self,
            forKey: DynamicKey(stringValue: "lastSavedAt")!)

        var unknown: [String: AnyCodable] = [:]
        for key in container.allKeys {
            if LayoutDocument.knownKeys.contains(key.stringValue) { continue }
            if let value = try? container.decode(AnyCodable.self, forKey: key) {
                unknown[key.stringValue] = value
            }
        }
        self.unknownFields = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(version, forKey: DynamicKey(stringValue: "version")!)
        try container.encode(activePresetId, forKey: DynamicKey(stringValue: "activePresetId")!)
        try container.encode(presets, forKey: DynamicKey(stringValue: "presets")!)
        try container.encode(userPresets, forKey: DynamicKey(stringValue: "userPresets")!)
        try container.encode(tabGroups, forKey: DynamicKey(stringValue: "tabGroups")!)
        if let lastSavedAt {
            try container.encode(lastSavedAt, forKey: DynamicKey(stringValue: "lastSavedAt")!)
        }
        for (key, value) in unknownFields {
            try container.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

// MARK: - Convenience lookups

public extension LayoutDocument {

    /// Looks `name` up first in built-in presets, then in user presets.
    /// Returns nil if no match.
    func preset(named name: String) -> LayoutPreset? {
        if let hit = presets.first(where: { $0.id == name || $0.name == name }) { return hit }
        return userPresets.first(where: { $0.id == name || $0.name == name })
    }

    /// All presets in display order (built-ins first, then user presets).
    /// `⌘1`..`⌘9` bind in this order — see §3.5.
    var allPresetsInDisplayOrder: [LayoutPreset] {
        presets + userPresets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The currently active preset, falling back to "browser" if missing.
    var activePreset: LayoutPreset {
        preset(named: activePresetId) ?? LayoutPreset.browser
    }
}
