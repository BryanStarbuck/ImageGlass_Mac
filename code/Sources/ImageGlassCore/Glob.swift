import Foundation

/// Glob matching — `*`, `?`, `[abc]`, `[!abc]`. No `**` (use `recursive: true`
/// on the include rules to recurse into subdirectories).
public enum Glob {
    public static func match(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        return matchSlice(p, 0, n, 0)
    }

    private static func matchSlice(_ p: [Character], _ pi: Int, _ n: [Character], _ ni: Int) -> Bool {
        var pi = pi, ni = ni
        while pi < p.count {
            let pc = p[pi]
            if pc == "*" {
                // Skip consecutive stars.
                while pi < p.count && p[pi] == "*" { pi += 1 }
                if pi == p.count { return true }
                while ni < n.count {
                    if matchSlice(p, pi, n, ni) { return true }
                    ni += 1
                }
                return false
            } else if pc == "?" {
                if ni >= n.count { return false }
                pi += 1; ni += 1
            } else if pc == "[" {
                guard ni < n.count else { return false }
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
