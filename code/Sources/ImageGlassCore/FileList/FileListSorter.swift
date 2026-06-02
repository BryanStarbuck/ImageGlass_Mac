import Foundation

/// Pure sort helpers. No I/O, no state — unit-testable.
/// Spec §5.1, §5.3.
public enum FileListSorter {

    /// Sort an array of FileEntry by the descriptor. Pure / deterministic.
    public static func sort(
        _ entries: [FileEntry],
        by descriptor: FileListSortDescriptor
    ) -> [FileEntry] {
        var work = entries
        switch descriptor.field {
        case .name:
            work.sort { naturalAscending($0.name, $1.name) }
        case .dateModified:
            work.sort { lhs, rhs in
                cmpOptional(lhs.mtime, rhs.mtime) { $0 < $1 }
            }
        case .dateTaken:
            work.sort { lhs, rhs in
                cmpOptional(lhs.dateTaken, rhs.dateTaken) { $0 < $1 }
            }
        case .size:
            work.sort { lhs, rhs in
                cmpOptional(lhs.size, rhs.size) { $0 < $1 }
            }
        case .dimensions:
            work.sort { lhs, rhs in
                let lp = (lhs.dimensions?.width ?? 0) * (lhs.dimensions?.height ?? 0)
                let rp = (rhs.dimensions?.width ?? 0) * (rhs.dimensions?.height ?? 0)
                return lp < rp
            }
        case .type:
            work.sort { lhs, rhs in
                if lhs.ext == rhs.ext {
                    return naturalAscending(lhs.name, rhs.name)
                }
                return lhs.ext < rhs.ext
            }
        case .rating:
            work.sort { lhs, rhs in
                cmpOptional(lhs.rating, rhs.rating) { $0 < $1 }
            }
        case .random:
            var gen = SplitMix64(seed: descriptor.randomSeed)
            // Schwartzian shuffle so the order is deterministic per seed.
            let tagged = work.map { ($0, gen.next()) }
            work = tagged.sorted { $0.1 < $1.1 }.map { $0.0 }
        }
        if descriptor.direction == .descending && descriptor.field != .random {
            work.reverse()
        }
        return work
    }

    /// Filter case-insensitive substring against filename. Spec §5.2.
    public static func filter(_ entries: [FileEntry], text: String) -> [FileEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return entries }
        // Diacritic + case insensitive — `compare(options: ...)` handles both.
        return entries.filter { entry in
            entry.name.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    // MARK: - Comparators

    /// Sort `nil`s to the end. `cmp` decides among non-nils.
    @inline(__always)
    private static func cmpOptional<T>(
        _ lhs: T?,
        _ rhs: T?,
        _ cmp: (T, T) -> Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?): return cmp(l, r)
        case (nil, nil):   return false
        case (nil, _):     return false  // nil sorts last
        case (_, nil):     return true
        }
    }

    /// Natural string compare ("img_2" < "img_10"). Spec §5.1 — analog of upstream
    /// `StringNaturalComparer.cs`.
    @inline(__always)
    public static func naturalAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// Tiny deterministic 64-bit PRNG. Splitmix64 — small, fast, good enough for
/// shuffling resolved file lists. Used by `FileListSorter` for `.random` sort
/// so the order is stable per scope load (spec §5.1).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
