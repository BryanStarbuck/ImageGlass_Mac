import XCTest
@testable import ImageGlassCore

final class IgCmdDispatcherTests: XCTestCase {

    // MARK: routing

    func testRoutesToRegisteredHandler() {
        var seen: [String] = []
        let handlers: [String: IgCmdDispatcher.Handler] = [
            "set-wallpaper": { args in
                seen = args
                return 0
            },
        ]
        let dispatcher = IgCmdDispatcher(handlers: handlers)
        let code = dispatcher.run(arguments: ["igcmd", "set-wallpaper", "/tmp/x.jpg", "fill"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(seen, ["/tmp/x.jpg", "fill"])
    }

    func testUnknownSubcommandReturns64() {
        let dispatcher = IgCmdDispatcher(handlers: [:])
        let code = dispatcher.run(arguments: ["igcmd", "no-such-thing"])
        XCTAssertEqual(code, 64)
    }

    func testNoSubcommandReturns64() {
        let dispatcher = IgCmdDispatcher(handlers: [:])
        let code = dispatcher.run(arguments: ["igcmd"])
        XCTAssertEqual(code, 64)
    }

    func testHelpFlagReturnsZero() {
        let dispatcher = IgCmdDispatcher(handlers: [:])
        XCTAssertEqual(dispatcher.run(arguments: ["igcmd", "--help"]), 0)
        XCTAssertEqual(dispatcher.run(arguments: ["igcmd", "-h"]), 0)
        XCTAssertEqual(dispatcher.run(arguments: ["igcmd", "help"]), 0)
    }

    func testHandlerExitCodeIsPropagated() {
        let handlers: [String: IgCmdDispatcher.Handler] = [
            "set-wallpaper": { _ in 42 },
        ]
        let dispatcher = IgCmdDispatcher(handlers: handlers)
        XCTAssertEqual(dispatcher.run(arguments: ["igcmd", "set-wallpaper"]), 42)
    }

    // MARK: known-subcommands

    func testAllDocumentedSubcommandsAreRegistered() {
        // These names come directly from docs/command-line.mdx.
        let documented: Set<String> = [
            "set-wallpaper", "set-lock-screen",
            "set-default-viewer", "remove-default-viewer",
            "export-frames", "quick-setup", "check-for-update",
            "install-languages", "install-themes",
            "uninstall-theme",
            "set-startup-boost", "remove-startup-boost",
        ]
        let registered = Set(IgCmdDispatcher.defaultHandlers.keys)
        XCTAssertEqual(documented, registered,
            "Mismatch between documented subcommands and registered handlers.")
        XCTAssertEqual(Set(IgCmdDispatcher.knownSubcommands), documented)
    }

    // MARK: subcommand behaviour — only the ones safe to exercise.

    func testSetLockScreenIsNonZeroExitWithMacUnsupportedMessage() {
        // macOS has no public API for this — handler must refuse.
        let code = IgCmd.setLockScreen(["/tmp/anything.png"])
        XCTAssertNotEqual(code, 0)
    }

    func testCheckForUpdateReturnsZero() {
        XCTAssertEqual(IgCmd.checkForUpdate([]), 0)
    }

    func testQuickSetupCreatesAppSupportLayoutInTempHome() throws {
        try withTemporaryHome { home in
            let code = IgCmd.quickSetup([])
            XCTAssertEqual(code, 0)
            let fm = FileManager.default
            let support = (home as NSString)
                .appendingPathComponent("Library/Application Support/ImageGlass")
            XCTAssertTrue(fm.fileExists(atPath: support))
            XCTAssertTrue(fm.fileExists(atPath: (support as NSString).appendingPathComponent("scopes")))
            XCTAssertTrue(fm.fileExists(atPath: (support as NSString).appendingPathComponent("languages")))
            XCTAssertTrue(fm.fileExists(atPath: (support as NSString).appendingPathComponent("themes")))
        }
    }

    func testInstallLanguagesCopiesJsonAndRejectsInvalid() throws {
        try withTemporaryHome { home in
            // Build one valid and one invalid .iglang in a scratch dir.
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let good = scratch.appendingPathComponent("en.iglang")
            let bad  = scratch.appendingPathComponent("broken.iglang")
            try Data(#"{"locale":"en","strings":{}}"#.utf8).write(to: good)
            try Data("not json".utf8).write(to: bad)

            let code = IgCmd.installLanguages([good.path, bad.path])
            // Bad file present => failure exit code, but good file should still land.
            XCTAssertNotEqual(code, 0)
            let installed = (home as NSString)
                .appendingPathComponent("Library/Application Support/ImageGlass/languages/en.iglang")
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed))
            let brokenPath = (home as NSString)
                .appendingPathComponent("Library/Application Support/ImageGlass/languages/broken.iglang")
            XCTAssertFalse(FileManager.default.fileExists(atPath: brokenPath))
        }
    }

    func testInstallThemesCopiesFileVerbatim() throws {
        try withTemporaryHome { home in
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let pack = scratch.appendingPathComponent("Kobe.igtheme")
            try Data("theme-payload".utf8).write(to: pack)

            let code = IgCmd.installThemes([pack.path])
            XCTAssertEqual(code, 0)
            let installed = (home as NSString)
                .appendingPathComponent("Library/Application Support/ImageGlass/themes/Kobe.igtheme")
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed))
        }
    }

    func testUninstallThemeRemovesByBareFilename() throws {
        try withTemporaryHome { home in
            try AppPaths.ensureDirectories()
            let target = AppPaths.themesDir.appendingPathComponent("Old.igtheme")
            try Data("x".utf8).write(to: target)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

            let code = IgCmd.uninstallTheme(["Old.igtheme"])
            XCTAssertEqual(code, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            _ = home
        }
    }

    func testUninstallThemeOnMissingFileReturnsNonZero() throws {
        try withTemporaryHome { _ in
            try AppPaths.ensureDirectories()
            let code = IgCmd.uninstallTheme(["does-not-exist.igtheme"])
            XCTAssertNotEqual(code, 0)
        }
    }

    func testStartupBoostRoundTrip() throws {
        try withTemporaryHome { _ in
            XCTAssertEqual(IgCmd.setStartupBoost([]), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.startupBoostFlag.path))
            XCTAssertEqual(IgCmd.removeStartupBoost([]), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.startupBoostFlag.path))
            // Idempotent second call.
            XCTAssertEqual(IgCmd.removeStartupBoost([]), 0)
        }
    }

    func testInstallLanguagesWithNoArgsReturns64() {
        XCTAssertEqual(IgCmd.installLanguages([]), 64)
    }

    func testInstallThemesWithNoArgsReturns64() {
        XCTAssertEqual(IgCmd.installThemes([]), 64)
    }

    func testUninstallThemeWithNoArgsReturns64() {
        XCTAssertEqual(IgCmd.uninstallTheme([]), 64)
    }

    func testExportFramesWithMissingFileReturnsNonZero() {
        XCTAssertNotEqual(IgCmd.exportFrames(["/tmp/does-not-exist-12345.gif"]), 0)
    }

    func testExportFramesWithNoArgsReturns64() {
        XCTAssertEqual(IgCmd.exportFrames([]), 64)
    }

    func testSetWallpaperWithMissingFileReturnsNonZero() {
        XCTAssertNotEqual(IgCmd.setWallpaper(["/tmp/no-such-image-987654.png"]), 0)
    }

    // MARK: shared scratch home helper

    /// Run `body` with `HOME` rebound to a fresh temp dir, then restore it.
    /// This lets the tests exercise the real AppPaths-based file operations
    /// without polluting the developer's `~/Library/Application Support`.
    func withTemporaryHome(_ body: (String) throws -> Void) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("igcmd-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let oldHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmp.path, 1)
        defer {
            if let old = oldHome { setenv("HOME", old, 1) } else { unsetenv("HOME") }
            try? FileManager.default.removeItem(at: tmp)
        }
        try body(tmp.path)
    }
}
