import Foundation

/// Charter-flavored evaluation:
///   1. Compose the scope's effective rules via `ScopeChain` (rule sets +
///      inheritsFrom).
///   2. Resolve files using the existing `ScopeEvaluator`.
///   3. Compute `ScopeDiff` against the previous resolved list and store it
///      on the scope.
///   4. Append a `ScopeAuditEntry` to the per-scope JSONL audit log.
///
/// Existing callers of `ScopeEvaluator.evaluate(_:)` keep working — this is
/// a drop-in superset that adds provenance without changing the simple path.
public extension ScopeEvaluator {

    /// Returns a new copy of `scope` with `resolvedFiles`, `lastEvaluated`,
    /// and `lastDiff` populated. Also writes an audit-log entry.
    /// Pass `auditLog: nil` to skip audit logging (used by tests that don't
    /// want to touch the audit dir).
    static func evaluateWithProvenance(
        _ scope: Scope,
        chainLoaders: ScopeChain.Loaders = .init(),
        auditLog: ScopeAuditLog? = ScopeAuditLog.shared
    ) -> Scope {
        let effective = ScopeChain.compose(scope, loaders: chainLoaders)

        // Build a synthetic scope that carries only the effective rules,
        // then run the existing file-walk.
        let effScope = Scope(
            name: scope.name,
            include: effective.include,
            exclude: effective.exclude
        )
        let resolved = ScopeEvaluator.resolveFiles(for: effScope)
        let diff = ScopeDiff.between(previous: scope.resolvedFiles, current: resolved)

        var out = scope
        out.resolvedFiles = resolved
        out.lastEvaluated = Date()
        out.lastDiff = diff.isEmpty ? nil : diff

        // Audit log — append-only JSONL.
        if let auditLog {
            let entry = ScopeAuditEntry(
                timestamp: out.lastEvaluated ?? Date(),
                fileCount: resolved.count,
                added: diff.added,
                removed: diff.removed,
                sources: effective.sources
            )
            try? auditLog.append(entry, scopeName: scope.name)
        }

        return out
    }
}
