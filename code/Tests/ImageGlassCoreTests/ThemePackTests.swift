import XCTest
@testable import ImageGlassCore

final class ThemePackTests: XCTestCase {

    private var tmpDir: URL!
    private var fakeHome: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ig-themepack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Re-route HOME so AppPaths.themesDir points into our tmp tree.
        fakeHome = tmpDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        setenv("HOME", fakeHome.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Manifest round-trip

    func testManifestRoundTripPreservesAllSections() throws {
        let manifest = ThemeManifest(
            metadata: .init(version: "9.0", description: "round-trip test"),
            info: .init(
                name: "Kobe",
                version: "1.2.0",
                description: "Test theme",
                author: "Duong-Dieu-Phap",
                email: "phap@imageglass.org",
                website: "https://imageglass.org"
            ),
            settings: .init(
                isDarkMode: true,
                isShowTitlebar: false,
                isShowToolbar: true,
                isShowGallery: true,
                isShowNavButtons: true,
                appLogo: "logo.svg",
                previewImage: "preview.webp"
            ),
            colors: .init(
                backColor: .hex("#1e1e1e"),
                accentColor: .system,
                extra: ["CustomColor": .hex("#abcdef")]
            ),
            toolbarIcons: .init(
                zoomIn: "zoom_in.svg",
                zoomOut: "zoom_out.svg",
                rotateLeft: "rotate_left.svg",
                fullScreen: "fullscreen.svg",
                extra: ["FutureSlot": "future.svg"]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        let decoded = try JSONDecoder().decode(ThemeManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func testManifestDecodesSpecExampleKeys() throws {
        // Verify the on-disk PascalCase keys round-trip into our typed model.
        let json = """
        {
          "_Metadata": { "Version": "9.0", "Description": "demo" },
          "Info": {
            "Name": "Kobe",
            "Version": "1.0",
            "Author": "Phap"
          },
          "Settings": {
            "IsDarkMode": true,
            "PreviewImage": "preview.webp"
          },
          "Colors": {
            "BackColor": "#202020",
            "AccentColor": "system",
            "UnknownColor": "#ffeeaa"
          },
          "ToolbarIcons": {
            "ZoomIn": "zoom_in.svg",
            "ZoomOut": "zoom_out.svg",
            "FutureFeature": "future.svg"
          }
        }
        """
        let data = Data(json.utf8)
        let m = try JSONDecoder().decode(ThemeManifest.self, from: data)
        XCTAssertEqual(m.metadata.version, "9.0")
        XCTAssertEqual(m.info.name, "Kobe")
        XCTAssertEqual(m.settings.isDarkMode, true)
        XCTAssertEqual(m.settings.previewImage, "preview.webp")
        XCTAssertEqual(m.colors.backColor, .hex("#202020"))
        XCTAssertEqual(m.colors.accentColor, .system)
        XCTAssertEqual(m.colors.extra["UnknownColor"], .hex("#ffeeaa"))
        XCTAssertEqual(m.toolbarIcons.zoomIn, "zoom_in.svg")
        XCTAssertEqual(m.toolbarIcons.extra["FutureFeature"], "future.svg")
    }

    func testThemeColorAcceptsSystemAndHex() throws {
        let json = """
        ["#abcdef", "#ABCDEFAA", "system", "abcdef"]
        """
        let arr = try JSONDecoder().decode([ThemeColor].self, from: Data(json.utf8))
        XCTAssertEqual(arr[0], .hex("#abcdef"))
        XCTAssertEqual(arr[1], .hex("#abcdefaa"))
        XCTAssertEqual(arr[2], .system)
        // No leading `#` should be auto-prepended.
        XCTAssertEqual(arr[3], .hex("#abcdef"))
        XCTAssertTrue(arr[2].followsSystemAccent)
        XCTAssertFalse(arr[0].followsSystemAccent)
    }

    func testThemeColorRejectsInvalidHex() {
        // Wrong length.
        let bad = "[\"#zzz\"]"
        XCTAssertThrowsError(try JSONDecoder().decode([ThemeColor].self, from: Data(bad.utf8)))
    }

    // MARK: - Icon fallback resolution

    func testIconResolverPrefersActiveTheme() throws {
        let activeFolder = tmpDir.appendingPathComponent("active.author", isDirectory: true)
        try FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)
        try Data("svg".utf8).write(to: activeFolder.appendingPathComponent("active_zoom.svg"))

        let activeManifest = ThemeManifest(
            metadata: .init(),
            info: .init(name: "Active"),
            settings: .init(),
            colors: .init(),
            toolbarIcons: .init(zoomIn: "active_zoom.svg")
        )

        let resolver = ThemeIconResolver(
            activeThemeFolder: activeFolder,
            activeManifest: activeManifest
        )
        let url = resolver.iconURL(for: .zoomIn)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "active_zoom.svg")
        XCTAssertTrue(resolver.activeThemeHas(slot: .zoomIn))
        XCTAssertFalse(resolver.usedFallback(for: .zoomIn))
    }

    func testIconResolverFallsBackToDefault() throws {
        // Active theme references a file that does NOT exist on disk.
        let activeFolder = tmpDir.appendingPathComponent("active.author", isDirectory: true)
        try FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)

        let activeManifest = ThemeManifest(
            metadata: .init(),
            info: .init(name: "Active"),
            settings: .init(),
            colors: .init(),
            toolbarIcons: .init(zoomIn: "missing.svg")
        )

        let defaultFolder = tmpDir.appendingPathComponent("default.imageglass", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        try Data("svg".utf8).write(to: defaultFolder.appendingPathComponent("default_zoom.svg"))

        let defaultManifest = ThemeManifest(
            metadata: .init(),
            info: .init(name: "Default"),
            settings: .init(),
            colors: .init(),
            toolbarIcons: .init(zoomIn: "default_zoom.svg")
        )

        let resolver = ThemeIconResolver(
            activeThemeFolder: activeFolder,
            activeManifest: activeManifest,
            defaultThemeFolder: defaultFolder,
            defaultManifest: defaultManifest
        )

        let url = resolver.iconURL(for: .zoomIn)
        XCTAssertEqual(url?.lastPathComponent, "default_zoom.svg")
        XCTAssertFalse(resolver.activeThemeHas(slot: .zoomIn))
        XCTAssertTrue(resolver.usedFallback(for: .zoomIn))
    }

    func testIconResolverReturnsNilWhenNeitherProvides() throws {
        let activeFolder = tmpDir.appendingPathComponent("active.author", isDirectory: true)
        try FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)
        let resolver = ThemeIconResolver(
            activeThemeFolder: activeFolder,
            activeManifest: ThemeManifest(
                metadata: .init(),
                info: .init(name: "X"),
                settings: .init(),
                colors: .init(),
                toolbarIcons: .init()
            )
        )
        XCTAssertNil(resolver.iconURL(for: .crop))
        XCTAssertFalse(resolver.usedFallback(for: .crop))
    }

    func testThemePackReportsMissingIcons() throws {
        let folder = tmpDir.appendingPathComponent("t.a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("svg".utf8).write(to: folder.appendingPathComponent("z.svg"))

        let manifest = ThemeManifest(
            metadata: .init(),
            info: .init(name: "t"),
            settings: .init(),
            colors: .init(),
            toolbarIcons: .init(zoomIn: "z.svg", crop: "crop_missing.svg")
        )
        let pack = ThemePack(folder: folder, manifest: manifest)

        XCTAssertEqual(pack.iconURL(for: .zoomIn)?.lastPathComponent, "z.svg")
        XCTAssertNil(pack.iconURL(for: .crop))
        XCTAssertEqual(pack.missingIconFiles(), [.crop])
        XCTAssertTrue(pack.unmappedIconSlots().contains(.rotateLeft))
    }

    // MARK: - Install / uninstall round-trip

    func testInstallFromFolderRoundTrip() throws {
        let source = try makeSyntheticThemeFolder(named: "Kobe.Duong-Dieu-Phap")

        let installer = ThemeInstaller()
        let pack = try installer.install(folder: source)
        XCTAssertEqual(pack.folderName, "Kobe.Duong-Dieu-Phap")
        XCTAssertEqual(pack.displayName, "Kobe")

        // Files are now in the install root.
        let installed = AppPaths.themesDir.appendingPathComponent("Kobe.Duong-Dieu-Phap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("igtheme.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("zoom_in.svg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("preview.webp").path))

        // Listed by the installer.
        let listed = try installer.installedThemeFolders().map { $0.lastPathComponent }
        XCTAssertTrue(listed.contains("Kobe.Duong-Dieu-Phap"))

        // Uninstall removes it.
        try installer.uninstall(folderName: "Kobe.Duong-Dieu-Phap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertThrowsError(try installer.uninstall(folderName: "Kobe.Duong-Dieu-Phap"))
    }

    func testInstallFromZipArchiveRoundTrip() throws {
        // Skip if the system unzip is missing (highly unlikely on macOS 14+).
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("System zip/unzip not available")
        }

        let source = try makeSyntheticThemeFolder(named: "Test.Bryan")
        let archive = tmpDir.appendingPathComponent("Test.Bryan.igtheme")

        // Use `/usr/bin/zip` to produce a real PKZIP archive that mirrors the
        // spec's "archive contains the theme folder" layout.
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source.deletingLastPathComponent()
        zip.arguments = ["-rq", archive.path, source.lastPathComponent]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let installer = ThemeInstaller()
        let pack = try installer.install(archive: archive)
        XCTAssertEqual(pack.folderName, "Test.Bryan")

        let installed = AppPaths.themesDir.appendingPathComponent("Test.Bryan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("igtheme.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("zoom_in.svg").path))

        // Re-install should atomically replace.
        let pack2 = try installer.install(archive: archive)
        XCTAssertEqual(pack2.folderName, "Test.Bryan")

        try installer.uninstall(folderName: "Test.Bryan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    func testInstallRejectsArchiveWithoutManifest() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("System zip not available")
        }
        let junkDir = tmpDir.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: junkDir.appendingPathComponent("readme.txt"))

        let archive = tmpDir.appendingPathComponent("junk.igtheme")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = junkDir.deletingLastPathComponent()
        zip.arguments = ["-rq", archive.path, "junk"]
        try zip.run()
        zip.waitUntilExit()

        let installer = ThemeInstaller()
        XCTAssertThrowsError(try installer.install(archive: archive))
    }

    // MARK: - Helpers

    /// Build a synthetic theme folder with manifest, preview, and one SVG.
    private func makeSyntheticThemeFolder(named name: String) throws -> URL {
        let folder = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let manifest = ThemeManifest(
            metadata: .init(version: "9.0", description: "synthetic test theme"),
            info: .init(
                name: String(name.split(separator: ".").first ?? "Unknown"),
                version: "1.0",
                author: String(name.split(separator: ".").dropFirst().first ?? "Unknown")
            ),
            settings: .init(
                isDarkMode: true,
                appLogo: nil,
                previewImage: "preview.webp"
            ),
            colors: .init(
                backColor: .hex("#1e1e1e"),
                accentColor: .system
            ),
            toolbarIcons: .init(zoomIn: "zoom_in.svg")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: folder.appendingPathComponent("igtheme.json"))

        try Data("<svg/>".utf8).write(to: folder.appendingPathComponent("zoom_in.svg"))
        try Data("webp-bytes".utf8).write(to: folder.appendingPathComponent("preview.webp"))

        return folder
    }
}
