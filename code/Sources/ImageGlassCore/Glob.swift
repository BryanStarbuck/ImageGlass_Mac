import Foundation

/// Glob matching — `*`, `?`, `[abc]`, `[!abc]`, and `**` (cross-segment any).
///
/// Two entry points:
/// * `match(_:_:)` — pattern matched against a bare filename. `*` matches any
///   run of characters within the filename. Used for include-/exclude-name globs.
/// * `matchPath(_:_:)` — pattern matched against a full path with `/` as the
///   segment separator. `*` does NOT cross `/`, but `**` does. Mirrors POSIX
///   `fnmatch` with `FNM_PATHNAME` plus zsh-style `**`. Used by the spec's
///   `exclude_globs: ["**/_archive/**", "**/.imageglass/**"]` patterns.
public enum Glob {
    public static func match(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        return matchSlice(p, 0, n, 0, pathMode: false)
    }

    /// Path-aware match. `*` does not cross `/`; `**` does. The pattern is
    /// expected to be either absolute (leading `/`) or relative; if relative,
    /// it matches when any suffix of `path` matches. This lets users write
    /// `**/.imageglass/**` and have it apply across all directories.
    public static func matchPath(_ pattern: String, _ path: String) -> Bool {
        let p = Array(pattern)
        let n = Array(path)
        // Absolute or "**"-anchored patterns match from the start of path.
        if p.first == "/" || (p.count >= 2 && p[0] == "*" && p[1] == "*") {
            return matchSlice(p, 0, n, 0, pathMode: true)
        }
        // Relative pattern: try at every "/" boundary (including index 0) so
        // a bare "foo/*.bak" matches at any depth.
        if matchSlice(p, 0, n, 0, pathMode: true) { return true }
        for i in 0..<n.count where n[i] == "/" {
            if matchSlice(p, 0, n, i + 1, pathMode: true) { return true }
        }
        return false
    }

    private static func matchSlice(
        _ p: [Character], _ pi: Int,
        _ n: [Character], _ ni: Int,
        pathMode: Bool
    ) -> Bool {
        var pi = pi, ni = ni
        while pi < p.count {
            let pc = p[pi]
            if pc == "*" {
                // Look ahead: `**` is "match across path separators".
                let isDoubleStar = pi + 1 < p.count && p[pi + 1] == "*"
                // Consume the run of stars.
                while pi < p.count && p[pi] == "*" { pi += 1 }
                // Optional `/` directly after `**/` — collapse so `**/a` matches
                // both `a` and `x/a`.
                if isDoubleStar && pi < p.count && p[pi] == "/" {
                    // Try without consuming the slash (matches "a" at the
                    // current position) AND with consuming it.
                    if matchSlice(p, pi + 1, n, ni, pathMode: pathMode) { return true }
                }
                if pi == p.count {
                    // Trailing `*` with no `**`: in path mode must not cross `/`.
                    if pathMode && !isDoubleStar {
                        for i in ni..<n.count where n[i] == "/" { return false }
                    }
                    return true
                }
                while ni <= n.count {
                    if matchSlice(p, pi, n, ni, pathMode: pathMode) { return true }
                    if ni == n.count { return false }
                    if pathMode && !isDoubleStar && n[ni] == "/" { return false }
                    ni += 1
                }
                return false
            } else if pc == "?" {
                if ni >= n.count { return false }
                if pathMode && n[ni] == "/" { return false }
                pi += 1; ni += 1
            } else if pc == "[" {
                guard ni < n.count else { return false }
                if pathMode && n[ni] == "/" { return false }
                var negate = false
                var i = pi + 1
                if i < p.count && p[i] == "!" { negate = true; i += 1 }
                var matched = false
                while i < p.count && p[i] != "]" {
                    if i + 2 < p.count && p[i + 1] == "-" && p[i + 2] != "]" {
                        if n[ni] >= p[i] && n[ni] <= p[i + 2] { matched = true }
                        i += 3
                    } else {
                        if n[ni] == p[i] { matched = true }
                        i += 1
                    }
                }
                if i >= p.count { return false } // unterminated class
                if matched == negate { return false }
                pi = i + 1; ni += 1
            } else {
                if ni >= n.count || n[ni] != pc { return false }
                pi += 1; ni += 1
            }
        }
        return ni == n.count
    }
}
