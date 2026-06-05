import Foundation

/// A portable, plain-text bundle of one scope plus the rule sets it depends
/// on. Lets Claude Code (or the user) move a scope between machines, share
/// it in chat, or check it into git as a single artifact.
///
/// Spec §4 reasons-for-plain-text apply here too: the bundle is just JSON
/// — diff-able, scriptable, no opaque container.
public struct ScopeBundle: Codable, Equatable, Sendable {
    /// On-disk format version for forward compatibility.
    public var version: Int
    public var exportedAt: Date
    public var scope: Scope
    /// Rule sets referenced by `scope.ruleSets`, embedded so imports survive
    /// transport across machines.
    public var ruleSets: [RuleSet]
    /// Optional supporting scopes referenced by `scope.inheritsFrom`.
    public var parents: [Scope]

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        scope: Scope,
        ruleSets: [RuleSet] = [],
        parents: [Scope] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.scope = scope
        self.ruleSets = ruleSets
        self.parents = parents
    }
}

public enum ScopeBundleService {

    public enum ImportError: Error, CustomStringConvertible {
        case scopeAlreadyExists(String)
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .scopeAlreadyExists(let n):
                return "Scope '\(n)' already exists; pass overwrite=true to replace."
            case .unsupportedVersion(let v):
                return "Unsupported ScopeBundle version: \(v)"
            }
        }
    }

    /// Build a bundle for the given scope, pulling in referenced rule sets
    /// and parent scopes from local storage.
    public static func export(
        scopeName: String,
        scopeStorage: LocalStorage = .shared,
        ruleSetStorage: RuleSetStorage = .shared
    ) throws -> ScopeBundle {
        let _trace = PerformanceLog.shared.start(
            "Scope.LoadBundle",
            extra: [("scope", scopeName)]
        )
        defer { _trace.finish() }
        let scope = try scopeStorage.loadScope(scopeName)
        var ruleSets: [RuleSet] = []
        for name in scope.ruleSets ?? [] {
            do {
                let rs = try ruleSetStorage.loadRuleSet(name)
                ruleSets.append(rs)
            } catch {
                ErrorLog.log("failed to load rule set '\(name)' for export of scope '\(scopeName)'",
                             error: error,
                             class: "ScopeBundleService")
            }
        }
        var parents: [Scope] = []
        for name in scope.inheritsFrom ?? [] {
            do {
                let p = try scopeStorage.loadScope(name)
                parents.append(p)
            } catch {
                ErrorLog.log("failed to load parent scope '\(name)' for export of scope '\(scopeName)'",
                             error: error,
                             class: "ScopeBundleService")
            }
        }
        return ScopeBundle(scope: scope, ruleSets: ruleSets, parents: parents)
    }

    /// Encode a bundle to pretty JSON suitable for stdout / disk.
    public static func encodeJSON(_ bundle: ScopeBundle) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(bundle)
        guard let s = String(data: data, encoding: .utf8) else {
            ErrorLog.log("encoded bundle not valid UTF-8 for scope '\(bundle.scope.name)'",
                         class: "ScopeBundleService")
            return "{}"
        }
        return s
    }

    /// Decode a bundle from JSON text.
    public static func decodeJSON(_ s: String) throws -> ScopeBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = s.data(using: .utf8) else {
            throw NSError(domain: "ScopeBundle", code: -1)
        }
        return try dec.decode(ScopeBundle.self, from: data)
    }

    /// Install a bundle into Local Storage. Embedded rule sets and parents
    /// are saved alongside the primary scope.
    @discardableResult
    public static func install(
        _ bundle: ScopeBundle,
        overwrite: Bool = false,
        scopeStorage: LocalStorage = .shared,
        ruleSetStorage: RuleSetStorage = .shared
    ) throws -> Scope {
        let _trace = PerformanceLog.shared.start(
            "Scope.SaveBundle",
            extra: [("scope", bundle.scope.name)]
        )
        defer { _trace.finish() }
        guard bundle.version == 1 else {
            throw ImportError.unsupportedVersion(bundle.version)
        }
        if scopeStorage.scopeExists(bundle.scope.name) && !overwrite {
            throw ImportError.scopeAlreadyExists(bundle.scope.name)
        }
        for rs in bundle.ruleSets {
            try ruleSetStorage.saveRuleSet(rs)
        }
        for parent in bundle.parents {
            if !scopeStorage.scopeExists(parent.name) || overwrite {
                try scopeStorage.saveScope(parent)
            }
        }
        try scopeStorage.saveScope(bundle.scope)
        return bundle.scope
    }
}
