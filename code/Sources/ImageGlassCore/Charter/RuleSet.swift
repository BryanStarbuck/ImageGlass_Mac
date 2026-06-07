import Foundation

/// A named, reusable bundle of include / exclude rules (spec §3:
/// "Named rule sets that can be referenced and reused").
///
/// Persisted as plain JSON under
/// `~/Library/Application Support/ImageGlass/rulesets/<name>.json`.
/// Scopes attach rule sets by name via `Scope.ruleSets`; at evaluation time
/// the rule set's include / exclude rules are unioned into the scope. This
/// gives the user (and Claude Code) a vocabulary like "tag a scope with the
/// `web_screenshots` rule set" rather than duplicating glob lists.
public struct RuleSet: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var include: Scope.IncludeRules
    public var exclude: Scope.ExcludeRules

    public init(
        name: String,
        description: String? = nil,
        include: Scope.IncludeRules = .init(directories: [], recursive: true),
        exclude: Scope.ExcludeRules = .init()
    ) {
        self.name = name
        self.description = description
        self.include = include
        self.exclude = exclude
    }
}

/// Plain-text on-disk store for `RuleSet` values.
public final class RuleSetStorage: @unchecked Sendable {

    public static let shared = RuleSetStorage()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Discovery

    public func listRuleSets() throws -> [String] {
        try AppPaths.ensureDirectories()
        let fm = FileManager.default
        guard fm.fileExists(atPath: AppPaths.ruleSetsDir.path) else { return [] }
        let urls = try fm.contentsOfDirectory(
            at: AppPaths.ruleSetsDir,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func ruleSetURL(for name: String) -> URL {
        AppPaths.ruleSetsDir.appendingPathComponent("\(name).json")
    }

    public func ruleSetExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: ruleSetURL(for: name).path)
    }

    // MARK: - Read / Write

    public func loadRuleSet(_ name: String) throws -> RuleSet {
        let url = ruleSetURL(for: name)
        let data = try Data(contentsOf: url)
        var rs = try decoder.decode(RuleSet.self, from: data)
        rs.name = name // filename is authoritative
        return rs
    }

    public func saveRuleSet(_ ruleSet: RuleSet) throws {
        try AppPaths.ensureDirectories()
        let url = ruleSetURL(for: ruleSet.name)
        let data = try encoder.encode(ruleSet)
        try data.write(to: url, options: .atomic)
    }

    public func deleteRuleSet(_ name: String) throws {
        let url = ruleSetURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
