import Foundation

/// Installs and uninstalls `.igtheme` packs.
///
/// ## Archive strategy
///
/// The Foundation-level archive APIs on macOS 14 (`AppleArchive`,
/// `Compression`) work well for proprietary formats but not for the
/// standard PKZIP / ZIP format that the spec assumes (`.igtheme` files
/// are just ZIP archives — see the spec's "unzip one and study the
/// manifest" tip). Pulling in a third-party Swift package (ZIPFoundation
/// et al.) is forbidden by the brief, so we shell out to the system
/// `/usr/bin/unzip` via `Process`. This tool is part of the base macOS
/// install (it ships with every release we support, macOS 14+).
///
/// ## Install layout
///
/// Each installed theme lives at:
///
/// ```
/// ~/Library/Application Support/ImageGlass/themes/<theme-folder>/
///     igtheme.json
///     preview.webp
///     *.svg
/// ```
///
/// The folder name comes straight from the archive — the spec mandates
/// the `<theme-name>.<author-name>` convention so the directory is
/// already collision-resistant.
public struct ThemeInstaller: Sendable {

    public let installRoot: URL
    public let unzipBinary: URL

    public init(
        installRoot: URL = AppPaths.themesDir,
        unzipBinary: URL = URL(fileURLWithPath: "/usr/bin/unzip")
    ) {
        self.installRoot = installRoot
        self.unzipBinary = unzipBinary
    }

    // MARK: - Public API

    /// Install a `.igtheme` archive. The archive must contain exactly one
    /// top-level folder with an `igtheme.json` manifest.
    ///
    /// If a theme with the same folder name is already installed, it is
    /// replaced atomically (extract to a temp dir, then swap).
    @discardableResult
    public func install(archive archiveURL: URL) throws -> ThemePack {
        guard FileManager.default.fileExists(atPath: unzipBinary.path) else {
            throw ThemePackError.unzipUnavailable
        }
        try ensureInstallRoot()

        let stagingDir = try makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        try unzip(archive: archiveURL, into: stagingDir)

        let themeFolderInStaging = try findThemeFolder(in: stagingDir, archive: archiveURL)
        // Validate the manifest before we touch the install dir.
        let stagedPack = try ThemePack.load(fromFolder: themeFolderInStaging)

        let destination = installRoot.appendingPathComponent(stagedPack.folderName, isDirectory: true)
        try atomicReplace(at: destination, with: themeFolderInStaging)

        return try ThemePack.load(fromFolder: destination)
    }

    /// Install from a folder that already contains `igtheme.json` (useful
    /// for theme authors testing locally without re-zipping each iteration).
    @discardableResult
    public func install(folder folderURL: URL) throws -> ThemePack {
        try ensureInstallRoot()

        let stagedPack = try ThemePack.load(fromFolder: folderURL)
        let destination = installRoot.appendingPathComponent(stagedPack.folderName, isDirectory: true)

        let stagingDir = try makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let copyDest = stagingDir.appendingPathComponent(stagedPack.folderName, isDirectory: true)
        try FileManager.default.copyItem(at: folderURL, to: copyDest)
        try atomicReplace(at: destination, with: copyDest)

        return try ThemePack.load(fromFolder: destination)
    }

    /// Uninstall by folder name (the `<theme-name>.<author-name>` value).
    /// Atomic: moves to a temp staging dir first, then removes.
    public func uninstall(folderName: String) throws {
        let target = installRoot.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ThemePackError.themeNotInstalled(folderName: folderName)
        }
        let trash = installRoot.appendingPathComponent(
            ".\(folderName).removing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: target, to: trash)
        try FileManager.default.removeItem(at: trash)
    }

    /// List installed theme folders. Each entry can be loaded with
    /// ``ThemePack/load(fromFolder:)``.
    public func installedThemeFolders() throws -> [URL] {
        try ensureInstallRoot()
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return entries
            .filter { url in
                // Skip our own staging / removing markers (they start with ".").
                if url.lastPathComponent.hasPrefix(".") { return false }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Load every installed theme that has a valid manifest. Skips entries
    /// with missing or invalid manifests so a single broken pack doesn't
    /// take down the catalog.
    public func loadInstalledThemes() throws -> [ThemePack] {
        try installedThemeFolders().compactMap { folder in
            try? ThemePack.load(fromFolder: folder)
        }
    }

    // MARK: - Internals

    private func ensureInstallRoot() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: installRoot.path) {
            try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        }
    }

    private func makeStagingDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("imageglass-theme-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func unzip(archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = unzipBinary
        // -q quiet, -o overwrite without prompting (we're writing to a fresh
        // staging dir so collision risk is just retries on partial extracts).
        process.arguments = ["-q", "-o", archive.path, "-d", destination.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // discard

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: data, encoding: .utf8) ?? ""
            throw ThemePackError.archiveExtractionFailed(
                archive: archive,
                exitCode: process.terminationStatus,
                stderr: stderrString
            )
        }
    }

    /// Find the single top-level folder that contains `igtheme.json`.
    /// Handles two layouts:
    ///   - archive root contains the theme folder (standard)
    ///   - archive root IS the theme folder (igtheme.json at top level)
    private func findThemeFolder(in stagingDir: URL, archive: URL) throws -> URL {
        let fm = FileManager.default
        let rootManifest = stagingDir.appendingPathComponent("igtheme.json")
        if fm.fileExists(atPath: rootManifest.path) {
            return stagingDir
        }

        let entries = try fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        var candidates: [URL] = []
        for entry in entries {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            // macOS-created zips sometimes include a __MACOSX sidecar dir.
            if entry.lastPathComponent == "__MACOSX" { continue }

            let manifest = entry.appendingPathComponent("igtheme.json")
            if fm.fileExists(atPath: manifest.path) {
                candidates.append(entry)
            }
        }

        switch candidates.count {
        case 0:
            throw ThemePackError.archiveContainsNoThemeFolder(archive: archive)
        case 1:
            return candidates[0]
        default:
            throw ThemePackError.archiveContainsMultipleThemeFolders(
                archive: archive,
                found: candidates.map { $0.lastPathComponent }
            )
        }
    }

    /// Replace `destination` with `source` atomically: move source on top,
    /// trashing the old destination first if needed. `source` is removed
    /// from its original location by this call (it gets moved, not copied).
    private func atomicReplace(at destination: URL, with source: URL) throws {
        let fm = FileManager.default

        // Make sure parent exists.
        let parent = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: destination.path) {
            let trash = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).old-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.moveItem(at: destination, to: trash)
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                // Roll back: put the old one back in place.
                try? fm.moveItem(at: trash, to: destination)
                throw error
            }
            try? fm.removeItem(at: trash)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }
}
