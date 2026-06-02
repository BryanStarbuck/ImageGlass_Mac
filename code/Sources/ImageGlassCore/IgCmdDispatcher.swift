import Foundation

/// Routes the first positional argument to one of the registered
/// subcommands. Designed to be testable: the run loop is pure
/// (no `exit()`, no global state) so tests can drive routing by
/// asserting return codes.
public struct IgCmdDispatcher {

    public typealias Handler = ([String]) -> Int32

    /// Map of subcommand name -> implementation. Each handler receives the
    /// argv slice *after* the subcommand token. Callers may inject custom
    /// handlers (tests do this to verify routing without doing real I/O).
    public let handlers: [String: Handler]

    public init(handlers: [String: Handler]? = nil) {
        self.handlers = handlers ?? Self.defaultHandlers
    }

    public static let defaultHandlers: [String: Handler] = [
        "set-wallpaper":         IgCmd.setWallpaper,
        "set-lock-screen":       IgCmd.setLockScreen,
        "set-default-viewer":    IgCmd.setDefaultViewer,
        "remove-default-viewer": IgCmd.removeDefaultViewer,
        "export-frames":         IgCmd.exportFrames,
        "quick-setup":           IgCmd.quickSetup,
        "check-for-update":      IgCmd.checkForUpdate,
        "install-languages":     IgCmd.installLanguages,
        "install-themes":        IgCmd.installThemes,
        "uninstall-theme":       IgCmd.uninstallTheme,
        "set-startup-boost":     IgCmd.setStartupBoost,
        "remove-startup-boost":  IgCmd.removeStartupBoost,
    ]

    /// Drive the dispatcher from a full argv (`CommandLine.arguments`).
    /// Returns the integer exit code that the caller should pass to `exit()`.
    public func run(arguments argv: [String]) -> Int32 {
        // Skip program name (`argv[0]`).
        let args = Array(argv.dropFirst())
        guard let sub = args.first else {
            printUsage()
            return 64 // EX_USAGE
        }
        if sub == "--help" || sub == "-h" || sub == "help" {
            printUsage()
            return 0
        }
        guard let handler = handlers[sub] else {
            FileHandle.standardError.write(Data("igcmd: unknown subcommand '\(sub)'\n".utf8))
            printUsage()
            return 64
        }
        return handler(Array(args.dropFirst()))
    }

    /// Public list of supported subcommand names. Stable for tests / docs.
    public static let knownSubcommands: [String] = [
        "set-wallpaper", "set-lock-screen", "set-default-viewer",
        "remove-default-viewer", "export-frames", "quick-setup",
        "check-for-update", "install-languages", "install-themes",
        "uninstall-theme", "set-startup-boost", "remove-startup-boost",
    ]

    public func printUsage() {
        let usage = """
        Usage: igcmd <subcommand> [options]

        Subcommands:
          set-wallpaper <imgPath> [style]
          set-lock-screen <imgPath>                  (not supported on macOS)
          set-default-viewer [exts] [--per-machine]
          remove-default-viewer [exts] [--per-machine]
          export-frames <filePath>
          quick-setup
          check-for-update
          install-languages [filePaths...]
          install-themes [filePaths...]
          uninstall-theme <filePath>
          set-startup-boost
          remove-startup-boost

        See docs/command-line.mdx for the full reference.
        """
        print(usage)
    }
}
