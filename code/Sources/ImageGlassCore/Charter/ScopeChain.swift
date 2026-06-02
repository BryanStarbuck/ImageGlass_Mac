import Foundation

/// Resolves a scope's effective include / exclude rules by composing in:
///   1. Rule sets referenced by `Scope.ruleSets` (spec §3).
///   2. Other scopes referenced by `Scope.inheritsFrom` — recursively, with
///      cycle detection.
///
/// Composition rules:
///   * Directory lists are concatenated (de-duplicated, order preserved).
///   * Include globs / extensions are unioned.
///   * Exclude globs are unioned.
///   * `recursive`  — true if ANY contributor wants recursion (more permissive
///     wins, since the alternative is silently dropping content the user
///     asked an inherited scope to include).
///   * `hiddenFiles` (exclude) — true if ANY contributor excludes hidden files
///     (stricter exclusion wins — matches the principle that excludes are
///     hard floors).
public enum ScopeChain {

    /// Loaders are pluggable for testability. Default loaders read from the
    /// shared `LocalStorage` / `RuleSetStorage` on disk.
    public struct Loaders {
        public var loadScope: (String) throws -> Scope
        public var loadRuleSet: (String) throws -> RuleSet

        public init(
            loadScope: @escaping (String) throws -> Scope = { try LocalStorage.shared.loadScope($0) },
            loadRuleSet: @escaping (String) throws -> RuleSet = { try RuleSetStorage.shared.loadRuleSet($0) }
        ) {
            self.loadScope = loadScope
            self.loadRuleSet = loadRuleSet
        }
    }

    /// The resolved effective rules for a scope after chaining + rule-set
    /// composition. Use these — not `scope.include` / `scope.exclude` — when
    /// you actually want to walk the filesystem.
    public struct Effective: Equatable, Sendable {
        public var include: Scope.IncludeRules
        public var exclude: Scope.ExcludeRules
        /// Ordered list of contributors visited (for debugging / audit).
        public var sources: [String]
    }

    /// Compose `scope` with everything it references.
    public static func compose(_ scope: Scope, loaders: Loaders = Loaders()) -> Effective {
        var visited = Set<String>()
        var sources: [String] = []
        var include = Scope.IncludeRules(
            directories: [],
            recursive: false,
            globs: [],
            extensions: []
        )
        var exclude = Scope.ExcludeRules(globs: [], hiddenFiles: false)

        absorb(
            scope: scope,
            include: &include,
            exclude: &exclude,
            visited: &visited,
            sources: &sources,
            loaders: loaders
        )

        // Sort / de-duplicate where order doesn't matter.
        include.directories = orderedUnique(include.directories)
        include.globs = orderedUnique(include.globs)
        include.extensions = orderedUnique(include.extensions.map { $0.lowercased() })
        exclude.globs = orderedUnique(exclude.globs)

        return Effective(include: include, exclude: exclude, sources: sources)
    }

    // MARK: - Internals

    private static func absorb(
        scope: Scope,
        include: inout Scope.IncludeRules,
        exclude: inout Scope.ExcludeRules,
        visited: inout Set<String>,
        sources: inout [String],
        loaders: Loaders
    ) {
        let key = "scope:\(scope.name)"
        guard !visited.contains(key) else { return }
        visited.insert(key)
        sources.append(key)

        // Inherited scopes first — gives "this scope wins on overlap" only
        // matters for `recursive` / `hiddenFiles` booleans, where ANY-true
        // semantics already merge correctly.
        for parentName in scope.inheritsFrom ?? [] {
            guard let parent = try? loaders.loadScope(parentName) else { continue }
            absorb(
                scope: parent,
                include: &include,
                exclude: &exclude,
                visited: &visited,
                sources: &sources,
                loaders: loaders
            )
        }

        // Referenced rule sets.
        for ruleSetName in scope.ruleSets ?? [] {
            let ruleSetKey = "ruleset:\(ruleSetName)"
            guard !visited.contains(ruleSetKey) else { continue }
            visited.insert(ruleSetKey)
            sources.append(ruleSetKey)
            guard let rs = try? loaders.loadRuleSet(ruleSetName) else { continue }
            merge(into: &include, from: rs.include)
            merge(into: &exclude, from: rs.exclude)
        }

        merge(into: &include, from: scope.include)
        merge(into: &exclude, from: scope.exclude)
    }

    private static func merge(into base: inout Scope.IncludeRules, from add: Scope.IncludeRules) {
        base.directories.append(contentsOf: add.directories)
        base.globs.append(contentsOf: add.globs)
        base.extensions.append(contentsOf: add.extensions)
        if add.recursive { base.recursive = true }
    }

    private static func merge(into base: inout Scope.ExcludeRules, from add: Scope.ExcludeRules) {
        base.globs.append(contentsOf: add.globs)
        if add.hiddenFiles { base.hiddenFiles = true }
    }

    private static func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
