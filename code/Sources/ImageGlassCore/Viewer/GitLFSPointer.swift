import Foundation

/// Detects Git LFS pointer files and produces actionable error text.
///
/// An LFS pointer is a tiny text file that stands in for the real binary on
/// disk until `git lfs pull` (or `git lfs fetch && git lfs checkout`) is run
/// in the repo. ImageIO, AVFoundation, and WebKit all happily read these
/// files as text and then fail downstream with generic messages like
/// "CGImageSourceGetCount returned 0" or "the file is not playable" —
/// leaving the user with no idea what's actually wrong.
///
/// We peek at the first 64 bytes and look for the canonical pointer
/// preamble (`version https://git-lfs.github.com/spec/v1`). When detected,
/// we also walk up the directory tree to locate the repo root that owns
/// the file, so the error message can name *which* repo to run the pull in.
public enum GitLFSPointer {
    /// Number of bytes we sniff to decide whether a file is a pointer.
    /// Pointers are always under 200 bytes; 64 is enough for the first line.
    private static let sniffByteCount = 64

    /// Canonical preamble that begins every LFS pointer file. Per the LFS
    /// spec, the first line is exactly:
    ///   `version https://git-lfs.github.com/spec/v1`
    /// We match the prefix only so future minor-version bumps still match.
    private static let pointerPrefix = "version https://git-lfs.github.com/spec/"

    /// True when `url` points at a Git LFS pointer file instead of the real
    /// asset bytes. Cheap to call: reads only the first 64 bytes.
    public static func isPointer(at url: URL) -> Bool {
        let _trace = PerformanceLog.shared.start(
            "Image.LFSDetect",
            extra: [("path", url.path)]
        )
        defer { _trace.finish() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: sniffByteCount)) ?? Data()
        guard !prefix.isEmpty,
              let head = String(data: prefix, encoding: .utf8) else { return false }
        // Strip a leading UTF-8 BOM if present — `git lfs` doesn't write one,
        // but tooling sometimes does, and the rest of the pointer is still
        // valid LFS content.
        let body = head.hasPrefix("\u{FEFF}") ? String(head.dropFirst()) : head
        return body.hasPrefix(pointerPrefix)
    }

    /// Walk up from `url` until a `.git` directory (or file, for worktrees /
    /// submodules) is found, and return that repo's root. nil when the file
    /// is not inside a git working tree, or when the walk runs out of
    /// parents before finding `.git`.
    ///
    /// Worktrees and submodules use a `.git` *file* (a small text file that
    /// points at the real gitdir), so we accept either type.
    public static func repoRoot(for url: URL) -> URL? {
        let fm = FileManager.default
        var dir = url.deletingLastPathComponent().standardizedFileURL
        // Bound the walk so a path on a stuck network mount can't spin.
        for _ in 0..<64 {
            let dot = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dot.path) { return dir }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { return nil } // hit filesystem root
            dir = parent
        }
        return nil
    }

    /// User-facing message describing how to materialize the real file.
    /// Names the repo root when we can find it so the user knows exactly
    /// where to run the command.
    public static func userMessage(for url: URL) -> String {
        if let repo = repoRoot(for: url) {
            let display = AppPaths.contractTilde(repo.path)
            return "This is a Git LFS placeholder, not the image itself. " +
                   "Run `git lfs pull` in \(display) to download the real file."
        }
        return "This is a Git LFS placeholder, not the image itself. " +
               "Run `git lfs pull` in the source repo to download the real file."
    }

    /// Same as `userMessage(for:)` but takes a POSIX path.
    public static func userMessage(forPath path: String) -> String {
        userMessage(for: URL(fileURLWithPath: AppPaths.expandTilde(path)))
    }
}
