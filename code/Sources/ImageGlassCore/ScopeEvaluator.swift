import Foundation

/// Walks the scope's source criteria and returns the resolved file list.
/// Spec §3 (Scope), §6.5 (paged scope walking), §6.6 (debounce).
public enum ScopeEvaluator {

    /// Returns a new copy of the scope with `resolved` and `lastEvaluated` populated.
    public static func evaluate(_ scope: Scope) -> Scope {
        var out = scope
        out.resolved = resolveEntries(for: scope)
        out.lastEvaluated = Date()
        return out
    }

    /// Just the file path list, without mutating a scope. Kept for back-compat
    /// with old callers that only consumed `[String]`.
    public static func resolveFiles(for scope: Scope) -> [String] {
        resolveEntries(for: scope).map(\.path)
    }

    /// Full per-file evaluation. Spec §3.1 `resolved[]` shape.
    public static func resolveEntries(for scope: Scope) -> [Scope.ResolvedFile] {
        let fm = FileManager.default
        var entries: [Scope.ResolvedFile] = []
        var seen = Set<String>()

        for criterion in scope.criteria {
            let expanded = AppPaths.expandTilde(criterion.root)
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let walked = walk(directory: url, criterion: criterion)
            for fileURL in walked {
                let path = fileURL.path
                let name = fileURL.lastPathComponent

                // Hidden files: per-criterion override (spec §3.1).
                if !criterion.includeHidden && name.hasPrefix(".") { continue }

                if !passesIncludeFilters(name: name, criterion: criterion) { continue }
                if !passesExcludeFilters(name: name, fullPath: path, criterion: criterion) { continue }

                let contracted = AppPaths.contractTilde(path)
                if seen.insert(contracted).inserted {
                    var resolved = Scope.ResolvedFile(path: contracted)
                    fillCheapMetadata(into: &resolved, url: fileURL)
                    entries.append(resolved)
                }
            }
        }

        // Apply scope-level filter (date, size, dimensions, text). Spec §3.1 / §5.2.
        entries = applyFilter(entries, filter: scope.filter)

        // Sort according to scope.sort. Spec §3.1 / §5.1.
        entries = applySort(entries, sort: scope.sort, scopeName: scope.name)

        return entries
    }

    // MARK: - Walk

    private static func walk(directory: URL, criterion: Scope.SourceCriterion) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []

        var opts: FileManager.DirectoryEnumerationOptions = []
        if !criterion.recursive {
            opts.insert(.skipsSubdirectoryDescendants)
        }
        // Hidden-file skipping is decided per-entry below so we can honor a
        // per-criterion `includeHidden = true` even when the directory itself
        // starts with a dot.
        // Symlinks: by default FileManager follows directory symlinks; honor
        // `followSymlinks=false` by skipping symlink-rooted entries.

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: opts
        ) else { return out }

        let rootDepth = depthComponents(of: directory.path)
        let maxDepth = criterion.maxDepth

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: Set(keys))

            // max_depth — spec §3.1. Counted in directory hops from the
            // criterion root. A file directly in the root is depth 0; a file
            // one directory down is depth 1; etc.
            if let maxDepth {
                let here = depthComponents(of: url.standardizedFileURL.path)
                let rel = here - rootDepth - 1
                if rel > maxDepth {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            if vals?.isSymbolicLink == true && !criterion.followSymlinks {
                continue
            }
            if vals?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    private static func depthComponents(of path: String) -> Int {
        // "/" → 0 components beyond root.
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/").count
    }

    // MARK: - Filters

    private static func passesIncludeFilters(name: String, criterion: Scope.SourceCriterion) -> Bool {
        let lower = name.lowercased()
        let hasExts = !criterion.includeExts.isEmpty
        let hasGlobs = !criterion.includeGlobs.isEmpty

        if hasExts {
            var matched = false
            for ext in criterion.includeExts {
                let needle = ext.hasPrefix(".") ? ext.lowercased() : "." + ext.lowercased()
                if lower.hasSuffix(needle) { matched = true; break }
            }
            if !matched && !hasGlobs { return false }
            if !matched && hasGlobs {
                // Fall through to glob check; either match qualifies.
            } else if matched {
                return true
            }
        }
        if hasGlobs {
            for pat in criterion.includeGlobs {
                if Glob.match(pat, name) { return true }
            }
            return false
        }
        // No include rules at all → include everything.
        return !hasExts && !hasGlobs
    }

    private static func passesExcludeFilters(
        name: String,
        fullPath: String,
        criterion: Scope.SourceCriterion
    ) -> Bool {
        let lower = name.lowercased()
        for ext in criterion.excludeExts {
            let needle = ext.hasPrefix(".") ? ext.lowercased() : "." + ext.lowercased()
            if lower.hasSuffix(needle) { return false }
        }
        for pat in criterion.excludeGlobs {
            // Spec §3.2 uses patterns like "**/_archive/**" that must match
            // against the full path, not just the filename.
            if pat.contains("/") {
                if Glob.matchPath(pat, fullPath) { return false }
            } else if Glob.match(pat, name) {
                return false
            }
        }
        return true
    }

    private static func fillCheapMetadata(into rf: inout Scope.ResolvedFile, url: URL) {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let s = vals?.fileSize { rf.size = Int64(s) }
        if let m = vals?.contentModificationDate { rf.modified = m }
    }

    // MARK: - Sort

    private static func applySort(
        _ entries: [Scope.ResolvedFile],
        sort: Scope.ScopeSort,
        scopeName: String
    ) -> [Scope.ResolvedFile] {
        var work = entries
        switch sort.by {
        case .name:
            work.sort { lhs, rhs in
                ((lhs.path as NSString).lastPathComponent)
                    .localizedStandardCompare((rhs.path as NSString).lastPathComponent) == .orderedAscending
            }
        case .size:
            work.sort { ord(lhs: $0.size, rhs: $1.size) }
        case .modified:
            work.sort { ord(lhs: $0.modified, rhs: $1.modified) }
        case .created:
            // We do not store created date in resolved[]; fall back to modified.
            work.sort { ord(lhs: $0.modified, rhs: $1.modified) }
        case .exifDateTaken:
            // No EXIF in resolved schema yet — fall back to modified.
            work.sort { ord(lhs: $0.modified, rhs: $1.modified) }
        case .extension_:
            work.sort { lhs, rhs in
                let l = (lhs.path as NSString).pathExtension.lowercased()
                let r = (rhs.path as NSString).pathExtension.lowercased()
                if l == r {
                    return ((lhs.path as NSString).lastPathComponent)
                        .localizedStandardCompare((rhs.path as NSString).lastPathComponent) == .orderedAscending
                }
                return l < r
            }
        case .random:
            // Stable per scope name (spec §5.1).
            var seed: UInt64 = 0
            for byte in scopeName.utf8 { seed = seed &* 1099511628211 ^ UInt64(byte) }
            var gen = SplitMix64(seed: seed == 0 ? 1 : seed)
            let tagged = work.map { ($0, gen.next()) }
            work = tagged.sorted { $0.1 < $1.1 }.map { $0.0 }
        case .dimensions:
            work.sort { lhs, rhs in
                let lp = (lhs.dim?[safe: 0] ?? 0) * (lhs.dim?[safe: 1] ?? 0)
                let rp = (rhs.dim?[safe: 0] ?? 0) * (rhs.dim?[safe: 1] ?? 0)
                return lp < rp
            }
        }
        if sort.direction == .desc && sort.by != .random {
            work.reverse()
        }
        return work
    }

    private static func ord<T: Comparable>(lhs: T?, rhs: T?) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?): return l < r
        case (nil, nil):   return false
        case (nil, _):     return false
        case (_, nil):     return true
        }
    }

    // MARK: - Filter

    private static func applyFilter(
        _ entries: [Scope.ResolvedFile],
        filter: Scope.ScopeFilter
    ) -> [Scope.ResolvedFile] {
        if filter.isEmpty { return entries }
        return entries.filter { rf in
            if let t = filter.text, !t.isEmpty {
                let name = (rf.path as NSString).lastPathComponent
                if name.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    return false
                }
            }
            if let from = filter.dateFrom, let mt = rf.modified, mt < from { return false }
            if let to = filter.dateTo, let mt = rf.modified, mt > to { return false }
            if let max = filter.maxSize, let s = rf.size, s > max { return false }
            if let mw = filter.minWidth, let w = rf.dim?[safe: 0], w < mw { return false }
            if let mh = filter.minHeight, let h = rf.dim?[safe: 1], h < mh { return false }
            return true
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
