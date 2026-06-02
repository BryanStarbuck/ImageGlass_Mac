import Foundation
import ImageGlassCore

/// Hierarchical view of resolved files for the tree mode of the Directory/Filename panel.
struct FileTreeNode: Identifiable {
    let id: String           // full path
    let name: String         // last path component
    let fullPath: String?    // non-nil for leaf files
    let isDirectory: Bool
    var children: [FileTreeNode]?

    static func build(from paths: [String]) -> [FileTreeNode] {
        var roots: [String: FileTreeNode] = [:]

        for raw in paths {
            let parts = raw.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            let rootKey = raw.hasPrefix("~") ? "~" : "/"
            var node = roots[rootKey] ?? FileTreeNode(
                id: rootKey, name: rootKey, fullPath: nil, isDirectory: true, children: []
            )
            insert(parts: parts, fullPath: raw, into: &node)
            roots[rootKey] = node
        }
        return roots.values.sorted { $0.name < $1.name }
    }

    private static func insert(parts: [String], fullPath: String, into parent: inout FileTreeNode) {
        guard let head = parts.first else { return }
        let tail = Array(parts.dropFirst())
        let isLeaf = tail.isEmpty
        let childID = (parent.id == "/" || parent.id == "~")
            ? parent.id + head
            : parent.id + "/" + head

        var children = parent.children ?? []
        if let idx = children.firstIndex(where: { $0.name == head }) {
            var existing = children[idx]
            if isLeaf {
                existing = FileTreeNode(
                    id: childID, name: head, fullPath: fullPath,
                    isDirectory: false, children: nil
                )
            } else {
                insert(parts: tail, fullPath: fullPath, into: &existing)
            }
            children[idx] = existing
        } else {
            if isLeaf {
                children.append(FileTreeNode(
                    id: childID, name: head, fullPath: fullPath,
                    isDirectory: false, children: nil
                ))
            } else {
                var newDir = FileTreeNode(
                    id: childID, name: head, fullPath: nil,
                    isDirectory: true, children: []
                )
                insert(parts: tail, fullPath: fullPath, into: &newDir)
                children.append(newDir)
            }
        }
        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        parent.children = children
    }
}
