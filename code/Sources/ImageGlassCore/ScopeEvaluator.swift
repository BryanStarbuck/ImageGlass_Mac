import Foundation

/// Walks the scope's include directories and returns the resolved file list.
public enum ScopeEvaluator {

    /// Returns a new copy of the scope with `resolvedFiles` and `lastEvaluated` populated.
    public static func evaluate(_ scope: Scope) -> Scope {
        var out = scope
        out.resolvedFiles = resolveFiles(for: scope)
        out.lastEvaluated = Date()
        return out
    }

    /// Just the file list, without mutating a scope.
    public static func resolveFiles(for scope: Scope) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        var seen = Set<String>()

        for raw in scope.include.directories {
            let expanded = AppPaths.expandTilde(raw)
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let walk = walk(directory: url, recursive: scope.include.recursive)
            for fileURL in walk {
                let path = fileURL.path
                let name = fileURL.lastPathComponent

                if scope.exclude.hiddenFiles && name.hasPrefix(".") { continue }

                if !passesIncludeFilters(name: name, include: scope.include) { continue }
                if !passesExcludeFilters(name: name, exclude: scope.exclude) { continue }

                let contracted = AppPaths.contractTilde(path)
                if seen.insert(contracted).inserted {
                    results.append(contracted)
                }
            }
        }

        results.sort()
        return results
    }

    // MARK: - Helpers

    private static func walk(directory: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: opts
        ) else { return out }

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if vals?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    private static func passesIncludeFilters(name: String, include: Scope.IncludeRules) -> Bool {
        let hasGlobs = !include.globs.isEmpty
        let hasExts = !include.extensions.isEmpty
        if !hasGlobs && !hasExts { return true }

        if hasExts {
            let lower = name.lowercased()
            for ext in include.extensions {
                let needle = ext.hasPrefix(".") ? ext.lowercased() : "." + ext.lowercased()
                if lower.hasSuffix(needle) { return true }
            }
        }
        if hasGlobs {
            for pat in include.globs where Glob.match(pat, name) { return true }
        }
        return false
    }

    private static func passesExcludeFilters(name: String, exclude: Scope.ExcludeRules) -> Bool {
        for pat in exclude.globs where Glob.match(pat, name) { return false }
        return true
    }
}
