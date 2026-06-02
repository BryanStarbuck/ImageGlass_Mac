import Foundation

/// Tree node used by the Tree view mode.
/// Top-level nodes are source directories (spec §2.5); leaves are files.
public struct FileListTreeNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Non-nil for leaf nodes. Points back at the FileEntry path.
    public let filePath: String?
    public let isDirectory: Bool
    public var children: [FileListTreeNode]?

    /// Source-directory index when this node is the root of a source subtree.
    /// nil for inner directory nodes and leaves.
    public let sourceIndex: Int?

    public var isLeaf: Bool { !isDirectory }

    public init(
        id: String,
        name: String,
        filePath: String?,
        isDirectory: Bool,
        children: [FileListTreeNode]?,
        sourceIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.isDirectory = isDirectory
        self.children = children
        self.sourceIndex = sourceIndex
    }
}

/// Builds a per-source tree from a flat list of FileEntry.
/// Pure / testable. Spec §2.5.
public enum FileListTreeBuilder {

    /// Build a tree where each root is a `SourceCriterion` (i.e. one of
    /// `scope.include.directories`). Files under each root are grouped by
    /// their relative path components, with empty directories pruned.
    ///
    /// - Parameter entries: resolved FileEntry list (output of evaluator).
    /// - Parameter sourceDirectories: the scope's source directory list, in
    ///   the same order as `sourceIndex`. Tilde-expanded.
    public static func build(
        entries: [FileEntry],
        sourceDirectories: [String]
    ) -> [FileListTreeNode] {
        // Normalize source directories — tilde-expand and trim trailing "/".
        let normalizedSources = sourceDirectories.map { Self.normalize($0) }

        // Group entries by their assigned sourceIndex. Spec §3.2.
        var bySource: [Int: [FileEntry]] = [:]
        for entry in entries {
            let idx = entry.sourceIndex
            bySource[idx, default: []].append(entry)
        }

        var roots: [FileListTreeNode] = []
        // Walk source indices in order — keeps a stable visible order in the UI.
        for (i, srcDir) in normalizedSources.enumerated() {
            let list = bySource[i] ?? []
            if list.isEmpty { continue }
            let displayName = srcDir
            var root = FileListTreeNode(
                id: "src:\(i):\(srcDir)",
                name: displayName,
                filePath: nil,
                isDirectory: true,
                children: [],
                sourceIndex: i
            )
            for entry in list {
                let relParts = relativeComponents(for: entry.url.path, under: srcDir)
                insert(parts: relParts, fullPath: entry.path, into: &root)
            }
            sortChildren(of: &root)
            roots.append(root)
        }

        // Any entries with sourceIndex outside the known range (e.g. implicit
        // scope, or stale data) go under a synthetic root so they remain
        // navigable.
        var orphans: [FileEntry] = []
        for (idx, items) in bySource where idx >= normalizedSources.count {
            orphans.append(contentsOf: items)
        }
        if !orphans.isEmpty {
            var orphanRoot = FileListTreeNode(
                id: "src:?:other",
                name: "Other",
                filePath: nil,
                isDirectory: true,
                children: [],
                sourceIndex: nil
            )
            for entry in orphans {
                let parts = entry.url.pathComponents
                insert(parts: Array(parts.dropFirst()), fullPath: entry.path, into: &orphanRoot)
            }
            sortChildren(of: &orphanRoot)
            roots.append(orphanRoot)
        }

        return roots
    }

    // MARK: - Internals

    /// Insert a relative path (array of components) into `parent`. Pure.
    static func insert(
        parts: [String],
        fullPath: String,
        into parent: inout FileListTreeNode
    ) {
        guard let head = parts.first else { return }
        let tail = Array(parts.dropFirst())
        let isLeaf = tail.isEmpty
        let childID = parent.id + "/" + head

        var children = parent.children ?? []
        if let idx = children.firstIndex(where: { $0.name == head }) {
            var existing = children[idx]
            if isLeaf {
                // Replace stub with leaf (preserve any directory beneath only if
                // existing is already a leaf — which is a conflict; pick the new).
                existing = FileListTreeNode(
                    id: childID,
                    name: head,
                    filePath: fullPath,
                    isDirectory: false,
                    children: nil
                )
            } else {
                insert(parts: tail, fullPath: fullPath, into: &existing)
            }
            children[idx] = existing
        } else {
            if isLeaf {
                children.append(FileListTreeNode(
                    id: childID,
                    name: head,
                    filePath: fullPath,
                    isDirectory: false,
                    children: nil
                ))
            } else {
                var newDir = FileListTreeNode(
                    id: childID,
                    name: head,
                    filePath: nil,
                    isDirectory: true,
                    children: []
                )
                insert(parts: tail, fullPath: fullPath, into: &newDir)
                children.append(newDir)
            }
        }
        parent.children = children
    }

    /// Recursively sort a node's children — directories first, then natural
    /// filename order.
    private static func sortChildren(of node: inout FileListTreeNode) {
        guard var children = node.children else { return }
        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return FileListSorter.naturalAscending(lhs.name, rhs.name)
        }
        for i in children.indices {
            sortChildren(of: &children[i])
        }
        node.children = children
    }

    /// Returns the relative path components of `path` under `sourceDir`.
    /// If `path` is not under `sourceDir`, returns the full filename only.
    public static func relativeComponents(for path: String, under sourceDir: String) -> [String] {
        let p = normalize(path)
        let s = normalize(sourceDir)
        if p.hasPrefix(s + "/") {
            let rel = String(p.dropFirst(s.count + 1))
            return rel.split(separator: "/").map(String.init)
        }
        return [(path as NSString).lastPathComponent]
    }

    /// Tilde-expand and drop trailing slash for stable comparison.
    public static func normalize(_ path: String) -> String {
        var p = AppPaths.expandTilde(path)
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
