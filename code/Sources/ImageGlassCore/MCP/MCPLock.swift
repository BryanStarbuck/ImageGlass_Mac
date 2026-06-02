import Foundation

/// Process-local serializer for read-modify-write operations on Local Storage
/// scope files. Spec §8 requires that two concurrent tool calls cannot corrupt
/// the on-disk YAML/JSON. We achieve that by serializing every mutating tool
/// call through a single queue. The on-disk write is then `.atomic` (already
/// done by `LocalStorage.saveScope`), and the lock prevents read-modify-write
/// interleaving across multiple tools running concurrently.
///
/// We use a single global queue rather than per-scope locks because scope
/// names are user-supplied strings and the directory-listing operations
/// (`list_scopes`, bootstrap) touch the directory as a whole.
public final class MCPLock: @unchecked Sendable {

    public static let shared = MCPLock()

    private let queue: DispatchQueue

    public init(label: String = "imageglass.mcp.lock") {
        self.queue = DispatchQueue(label: label)
    }

    /// Run a block while holding the lock. The block can throw; the error
    /// surfaces back to the caller.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync { try body() }
    }
}
