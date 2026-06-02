import XCTest
@testable import ImageGlassCore

/// Locks down the `igcmd` subcommand catalog so a future refactor doesn't
/// silently drop a documented command. The spec table in
/// `docs/command-line.mdx` is the source of truth — every row there has
/// to map to exactly one `IgCmdSubcommand` case.
final class IgCmdSubcommandsTests: XCTestCase {

    /// The full set of subcommand verbs the spec promises. If this list
    /// disagrees with `IgCmdSubcommand`, the spec and code are out of
    /// sync.
    private static let specVerbs: Set<String> = [
        "set-wallpaper",
        "set-lock-screen",
        "set-default-viewer",
        "remove-default-viewer",
        "export-frames",
        "quick-setup",
        "check-for-update",
        "install-languages",
        "install-themes",
        "uninstall-theme",
        "set-startup-boost",
        "remove-startup-boost",
    ]

    func testEverySpecVerbHasASubcommand() {
        for verb in Self.specVerbs {
            XCTAssertNotNil(
                IgCmdSubcommand.resolve(verb),
                "spec verb '\(verb)' has no IgCmdSubcommand case"
            )
        }
    }

    func testNoSubcommandIsMissingFromTheSpecVerbList() {
        for cmd in IgCmdSubcommand.allCases {
            XCTAssertTrue(
                Self.specVerbs.contains(cmd.rawValue),
                "subcommand '\(cmd.rawValue)' is not in the spec's promised verb list"
            )
        }
    }

    func testResolveIsCaseInsensitiveAndUnderscoreFriendly() {
        XCTAssertEqual(IgCmdSubcommand.resolve("Set-Wallpaper"), .setWallpaper)
        XCTAssertEqual(IgCmdSubcommand.resolve("SET-WALLPAPER"), .setWallpaper)
        XCTAssertEqual(IgCmdSubcommand.resolve("set_wallpaper"), .setWallpaper)
        XCTAssertNil(IgCmdSubcommand.resolve("nonsense"))
    }

    func testUsageStringsMentionTheVerb() {
        for cmd in IgCmdSubcommand.allCases {
            XCTAssertTrue(
                cmd.usage.hasPrefix(cmd.rawValue),
                "usage for \(cmd.rawValue) should start with the verb"
            )
            XCTAssertFalse(cmd.summary.isEmpty, "summary missing for \(cmd.rawValue)")
        }
    }

    func testExitCodesAreNonOverlappingAndSmall() {
        let codes: [Int32] = [
            IgCmdExit.success.rawValue,
            IgCmdExit.usage.rawValue,
            IgCmdExit.ioError.rawValue,
            IgCmdExit.unavailable.rawValue,
            IgCmdExit.softwareError.rawValue,
            IgCmdExit.permissionDenied.rawValue,
        ]
        XCTAssertEqual(Set(codes).count, codes.count, "exit codes must be unique")
        for c in codes {
            XCTAssertGreaterThanOrEqual(c, 0)
            XCTAssertLessThanOrEqual(c, 125, "shell-reserved codes 126/127+ are off-limits")
        }
    }

    // MARK: - Dispatcher behavior

    func testDispatcherEmptyArgs_PrintsHelpAndExitsUsage() {
        let code = IgCmdDispatcher().run(arguments: [])
        XCTAssertEqual(code, IgCmdExit.usage.rawValue)
    }

    func testDispatcherHelpFlag_ExitsSuccess() {
        XCTAssertEqual(IgCmdDispatcher().run(arguments: ["--help"]), IgCmdExit.success.rawValue)
        XCTAssertEqual(IgCmdDispatcher().run(arguments: ["-h"]),     IgCmdExit.success.rawValue)
    }

    func testDispatcherVersion_ExitsSuccess() {
        XCTAssertEqual(IgCmdDispatcher().run(arguments: ["--version"]), IgCmdExit.success.rawValue)
    }

    func testDispatcherUnknownSubcommand_ExitsUsage() {
        let code = IgCmdDispatcher().run(arguments: ["frobnicate"])
        XCTAssertEqual(code, IgCmdExit.usage.rawValue)
    }

    func testDispatcherCheckForUpdate_ExitsSuccess() {
        XCTAssertEqual(IgCmdDispatcher().run(arguments: ["check-for-update"]),
                       IgCmdExit.success.rawValue)
    }

    func testDispatcherExportFramesMissingPath_ExitsUsage() {
        let code = IgCmdDispatcher().run(arguments: ["export-frames"])
        XCTAssertEqual(code, IgCmdExit.usage.rawValue)
    }

    func testDispatcherExportFramesUnknownFile_ExitsIoError() {
        let code = IgCmdDispatcher().run(arguments: ["export-frames", "/nope/does-not-exist.png"])
        XCTAssertEqual(code, IgCmdExit.ioError.rawValue)
    }

    func testDispatcherSetLockScreen_ReportsUnavailable() {
        // macOS has no public API for the lock-screen background — the
        // spec entry is honored by exiting with EX_UNAVAILABLE instead of
        // silently lying.
        let code = IgCmdDispatcher().run(arguments: ["set-lock-screen", "/tmp/whatever.jpg"])
        XCTAssertEqual(code, IgCmdExit.unavailable.rawValue)
    }
}

final class CLIArgumentsCatalogTests: XCTestCase {

    func testEverySwitchMatchesAConfigField() {
        // The /Name=Value switches the spec promises must each map to a
        // real key the parser handles. Use parser observability via
        // rawPairs to confirm.
        for s in CLIArguments.switches {
            let pair = "/\(s.name)=fake"
            let parsed = CLIOverrides.parse([pair])
            XCTAssertEqual(parsed.rawPairs.first?.name, s.name,
                           "parser dropped the documented switch /\(s.name)")
        }
    }

    func testWantsHelpDetectsAllForms() {
        XCTAssertTrue(CLIArguments.wantsHelp(["--help"]))
        XCTAssertTrue(CLIArguments.wantsHelp(["-h"]))
        XCTAssertTrue(CLIArguments.wantsHelp(["/?"]))
        XCTAssertTrue(CLIArguments.wantsHelp(["/ShowToolbar=false", "--help"]))
        XCTAssertFalse(CLIArguments.wantsHelp([]))
        XCTAssertFalse(CLIArguments.wantsHelp(["/ShowToolbar=false"]))
    }

    func testHelpTextLooksLikeAUsageScreen() {
        let text = CLIArguments.helpText()
        XCTAssertTrue(text.contains("ImageGlass"))
        XCTAssertTrue(text.contains("Usage:"))
        XCTAssertTrue(text.contains("/ShowToolbar"))
        XCTAssertTrue(text.contains("--startup-boost"))
    }

    func testStartupBoostLongFormSwitchIsParsed() {
        let parsed = CLIOverrides.parse(["--startup-boost"])
        XCTAssertEqual(parsed.partial.startupBoost, true)
        XCTAssertEqual(parsed.positionalArguments, [])
    }
}
