import Foundation

/// Added / removed file lists between two scope evaluations.
///
/// Stored inline in `Scope.lastDiff` so anyone who reads the scope JSON
/// (the GUI, an MCP client, or the user with `cat`) can see what changed
/// in the most recent run. Spec §4 calls out that Local Storage is the
/// debuggable, scriptable, version-controllable surface — surfacing the
/// diff here keeps with that intent.
public struct ScopeDiff: Codable, Equatable, Sendable {
    public var added: [String]
    public var removed: [String]
    public var previousCount: Int
    public var currentCount: Int

    public init(added: [String] = [],
                removed: [String] = [],
                previousCount: Int = 0,
                currentCount: Int = 0) {
        self.added = added
        self.removed = removed
        self.previousCount = previousCount
        self.currentCount = currentCount
    }

    /// True when no files were added or removed between runs.
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    /// Compute a diff from two file lists. Order-independent.
    public static func between(previous: [String], current: [String]) -> ScopeDiff {
        let prev = Set(previous)
        let curr = Set(current)
        return ScopeDiff(
            added: curr.subtracting(prev).sorted(),
            removed: prev.subtracting(curr).sorted(),
            previousCount: previous.count,
            currentCount: current.count
        )
    }
}
