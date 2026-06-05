import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreServices

/// Parses an argv-style array and dispatches to the requested igcmd handler.
///
/// Stays inside the CLI domain — every subsystem call routes through an
/// existing public API in ``ImageGlassCore`` (ThemeInstaller, FormatLoader,
/// ReleasesCatalog, AppPaths, ...). This struct never reimplements those.
///
/// The dispatcher is purely a value type; it does no I/O until ``run`` is
/// called. That keeps unit tests fast.
public struct IgCmdDispatcher {

    public init() {}

    /// Single entry point. Pass `Array(CommandLine.arguments.dropFirst())`
    /// or any synthetic argv. Returns the exit code the binary should
    /// hand to the OS.
    @discardableResult
    public func run(arguments: [String]) -> Int32 {
        // No args, or `--help`/`-h` at top level: print the usage table.
        guard let first = arguments.first else {
            printTopLevelHelp(to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        if first == "--help" || first == "-h" || first == "help" {
            printTopLevelHelp(to: .stdout)
            return IgCmdExit.success.rawValue
        }
        if first == "--version" || first == "-V" {
            printLine("igcmd (ImageGlass for Mac) \(IgCmdDispatcher.toolVersion)", to: .stdout)
            return IgCmdExit.success.rawValue
        }

        guard let cmd = IgCmdSubcommand.resolve(first) else {
            printLine("igcmd: unknown subcommand '\(first)'", to: .stderr)
            printTopLevelHelp(to: .stderr)
            return IgCmdExit.usage.rawValue
        }

        let rest = Array(arguments.dropFirst())

        // docs/performance.mdx §5.6 / §10.12 — `Igcmd.RunSubcommand`
        // wraps the inner dispatch step (post-arg-parsing, pre-handler).
        // Distinct from the outer `Igcmd.Dispatch` in `igcmd/main.swift`,
        // which also covers help / version / unknown-verb paths.
        let _runTrace = PerformanceLog.shared.start(
            "Igcmd.RunSubcommand",
            extra: [("subcommand", cmd.rawValue)]
        )
        defer { _runTrace.finish() }

        // Per-subcommand `--help` is delegated to each handler so the help
        // text can document positional args specific to that subcommand.
        switch cmd {
        case .setWallpaper:        return handleSetWallpaper(args: rest)
        case .setLockScreen:       return handleSetLockScreen(args: rest)
        case .setDefaultViewer:    return handleSetDefaultViewer(args: rest, register: true)
        case .removeDefaultViewer: return handleSetDefaultViewer(args: rest, register: false)
        case .exportFrames:        return handleExportFrames(args: rest)
        case .quickSetup:          return handleQuickSetup(args: rest)
        case .checkForUpdate:      return handleCheckForUpdate(args: rest)
        case .installLanguages:    return handleInstallLanguages(args: rest)
        case .installThemes:       return handleInstallThemes(args: rest)
        case .uninstallTheme:      return handleUninstallTheme(args: rest)
        case .setStartupBoost:     return handleStartupBoost(args: rest, enable: true)
        case .removeStartupBoost:  return handleStartupBoost(args: rest, enable: false)
        }
    }

    // MARK: - Top-level help

    private func printTopLevelHelp(to stream: OutputStream) {
        printLine("igcmd — ImageGlass command-line utility", to: stream)
        printLine("", to: stream)
        printLine("Usage:", to: stream)
        printLine("  igcmd <subcommand> [arguments]", to: stream)
        printLine("  igcmd --help | --version", to: stream)
        printLine("", to: stream)
        printLine("Subcommands:", to: stream)
        for cmd in IgCmdSubcommand.allCases {
            printLine(cmd.helpTableRow, to: stream)
        }
        printLine("", to: stream)
        printLine("Run `igcmd <subcommand> --help` for per-subcommand details.", to: stream)
    }

    // MARK: - Subcommand handlers

    private func handleSetWallpaper(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.SetWallpaper")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.setWallpaper.usage)", to: .stdout)
            printLine("  style: fit | fill | stretch | tile | center  (default: fill)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let pathArg = positional.first else {
            printLine("igcmd set-wallpaper: missing <imgPath>", to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        let style = positional.count >= 2 ? positional[1] : "fill"

        guard let url = resolveExistingFile(pathArg) else {
            printLine("igcmd set-wallpaper: file not found: \(pathArg)", to: .stderr)
            return IgCmdExit.ioError.rawValue
        }

        guard let screen = NSScreen.main else {
            printLine("igcmd set-wallpaper: no screen available", to: .stderr)
            return IgCmdExit.unavailable.rawValue
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        var merged = options
        applyWallpaperStyle(style: style.lowercased(), into: &merged)

        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: merged)
            printLine("Wallpaper set: \(url.path)", to: .stdout)
            return IgCmdExit.success.rawValue
        } catch {
            ErrorLog.log("setDesktopImageURL failed for \(url.path)",
                         error: error,
                         class: "IgCmdDispatcher")
            printLine("igcmd set-wallpaper: \(error.localizedDescription)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
    }

    private func applyWallpaperStyle(style: String, into options: inout [NSWorkspace.DesktopImageOptionKey: Any]) {
        switch style {
        case "fit":
            options[.imageScaling] = NSImageScaling.scaleProportionallyDown.rawValue
            options[.allowClipping] = false
        case "fill":
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        case "stretch":
            options[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
            options[.allowClipping] = true
        case "tile":
            // AppKit's wallpaper API has no first-class tile mode — the
            // closest is no scaling with clipping disabled so the image
            // shows at native resolution. Document the limitation rather
            // than silently lying about it.
            options[.imageScaling] = NSImageScaling.scaleNone.rawValue
            options[.allowClipping] = false
        case "center":
            options[.imageScaling] = NSImageScaling.scaleNone.rawValue
            options[.allowClipping] = false
        default:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        }
    }

    private func handleSetLockScreen(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.SetLockScreen")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.setLockScreen.usage)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        // macOS does not expose a public API for setting the lock-screen
        // background. Surface a clear "unavailable" exit code instead of
        // pretending to do something.
        printLine("igcmd set-lock-screen: not supported on macOS (no public API for the lock-screen background)", to: .stderr)
        return IgCmdExit.unavailable.rawValue
    }

    private func handleSetDefaultViewer(args: [String], register: Bool) -> Int32 {
        let _trace = PerformanceLog.shared.start(
            register
                ? "Igcmd.Subcommand.SetDefaultViewer"
                : "Igcmd.Subcommand.RemoveDefaultViewer"
        )
        defer { _trace.finish() }
        let verb = register ? IgCmdSubcommand.setDefaultViewer : IgCmdSubcommand.removeDefaultViewer
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(verb.usage)", to: .stdout)
            printLine("  exts: ';'-separated list, e.g. \".jpg;.png;.webp\"", to: .stdout)
            printLine("        omit to read a newline-separated list from stdin", to: .stdout)
            printLine("  --per-machine: ignored on macOS (LaunchServices is per-user)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        var positional: [String] = []
        var perMachine = false
        for a in args {
            if a == "--per-machine" { perMachine = true; continue }
            if a.hasPrefix("--") {
                printLine("igcmd \(verb.rawValue): unknown flag '\(a)'", to: .stderr)
                return IgCmdExit.usage.rawValue
            }
            positional.append(a)
        }

        let extsString = positional.first ?? readStdinIfAvailable()
        let exts = parseExtensions(extsString ?? "")
        if exts.isEmpty {
            printLine("igcmd \(verb.rawValue): no extensions provided", to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        if perMachine {
            printLine("igcmd \(verb.rawValue): --per-machine has no effect on macOS (per-user only)", to: .stderr)
        }

        guard let bundleID = bundleIdentifierForRegistration() else {
            printLine("igcmd \(verb.rawValue): could not determine ImageGlass bundle identifier", to: .stderr)
            return IgCmdExit.unavailable.rawValue
        }

        var failed: [String] = []
        for ext in exts {
            guard let utType = UTType(filenameExtension: ext) else {
                ErrorLog.log("UTType(filenameExtension:) returned nil for '\(ext)'",
                             class: "IgCmdDispatcher")
                failed.append(ext)
                continue
            }
            let targetID: CFString = register ? (bundleID as CFString) : ("" as CFString)
            let status = LSSetDefaultRoleHandlerForContentType(
                utType.identifier as CFString,
                .viewer,
                targetID
            )
            if status != noErr {
                ErrorLog.log("LSSetDefaultRoleHandlerForContentType returned \(status) for ext=\(ext)",
                             class: "IgCmdDispatcher")
                failed.append(ext)
            }
        }

        let extList = exts.joined(separator: ", ")
        if failed.isEmpty {
            let verbWord = register ? "Registered" : "Unregistered"
            printLine("\(verbWord) ImageGlass as default viewer for: \(extList)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let failedList = failed.joined(separator: ", ")
        printLine("igcmd \(verb.rawValue): some extensions failed: \(failedList)", to: .stderr)
        return IgCmdExit.softwareError.rawValue
    }

    private func handleExportFrames(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.ExportFrames")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.exportFrames.usage)", to: .stdout)
            printLine("  Frames are written next to <filePath> as <basename>-frame-<NNN>.png", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let pathArg = positional.first else {
            printLine("igcmd export-frames: missing <filePath>", to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        guard let url = resolveExistingFile(pathArg) else {
            printLine("igcmd export-frames: file not found: \(pathArg)", to: .stderr)
            return IgCmdExit.ioError.rawValue
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            printLine("igcmd export-frames: could not open image source", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            printLine("igcmd export-frames: image contains no frames", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }

        let parent = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let pngType = UTType.png.identifier as CFString
        let digits = max(3, String(count).count)

        var written = 0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                ErrorLog.log("CGImageSourceCreateImageAtIndex(\(i)) returned nil for \(url.path)",
                             class: "IgCmdDispatcher")
                continue
            }
            let idx = String(format: "%0\(digits)d", i + 1)
            let dest = parent.appendingPathComponent("\(stem)-frame-\(idx).png")
            guard let writer = CGImageDestinationCreateWithURL(dest as CFURL, pngType, 1, nil) else {
                ErrorLog.log("CGImageDestinationCreateWithURL returned nil for \(dest.path)",
                             class: "IgCmdDispatcher")
                continue
            }
            CGImageDestinationAddImage(writer, frame, nil)
            if CGImageDestinationFinalize(writer) {
                written += 1
            } else {
                ErrorLog.log("CGImageDestinationFinalize returned false for \(dest.path)",
                             class: "IgCmdDispatcher")
            }
        }

        if written == 0 {
            printLine("igcmd export-frames: failed to write any frames", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
        printLine("Exported \(written) of \(count) frame(s) next to \(url.path)", to: .stdout)
        return IgCmdExit.success.rawValue
    }

    private func handleQuickSetup(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.QuickSetup")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.quickSetup.usage)", to: .stdout)
            printLine("  Creates the on-disk configuration files used by ImageGlass.", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        // Bootstrap the on-disk layout — this is the headless equivalent
        // of the first-run wizard. The GUI wizard lives in the main app;
        // here we make sure the dirs exist and a default config is written.
        do {
            try AppPaths.ensureDirectories()
            try AppPaths.ensureThemesDirectory()
            let paths = ConfigPaths.resolve()
            let loader = ConfigLoader(paths: paths)
            _ = try loader.resolveAndPersist()
            printLine("Quick setup complete. Config: \(paths.userFileURL.path)", to: .stdout)
            return IgCmdExit.success.rawValue
        } catch {
            ErrorLog.log("quick-setup failed",
                         error: error,
                         class: "IgCmdDispatcher")
            printLine("igcmd quick-setup: \(error.localizedDescription)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
    }

    private func handleCheckForUpdate(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.CheckForUpdate")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.checkForUpdate.usage)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        // No live update server in this fork. Surface the catalog's latest
        // entry so scripts can compare against their installed version.
        let latest = ReleasesCatalog.sortedReverseChronological.first
        if let r = latest {
            printLine("Latest known release: \(r.version) (\(r.title))", to: .stdout)
        } else {
            printLine("No release information available", to: .stdout)
        }
        return IgCmdExit.success.rawValue
    }

    private func handleInstallLanguages(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.InstallLanguages")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.installLanguages.usage)", to: .stdout)
            printLine("  Pass one or more .iglang files, or pipe a newline-separated list on stdin.", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let paths = collectPaths(from: args)
        if paths.isEmpty {
            printLine("igcmd install-languages: no file paths provided", to: .stderr)
            return IgCmdExit.usage.rawValue
        }

        let langDir = AppPaths.appSupportDir.appendingPathComponent("languages", isDirectory: true)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: langDir.path) {
                try fm.createDirectory(at: langDir, withIntermediateDirectories: true)
            }
        } catch {
            ErrorLog.log("failed to create languages dir at \(langDir.path)",
                         error: error,
                         class: "IgCmdDispatcher")
            printLine("igcmd install-languages: could not create \(langDir.path): \(error.localizedDescription)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }

        var installed = 0
        var failed: [String] = []
        for path in paths {
            guard let src = resolveExistingFile(path) else { failed.append(path); continue }
            let dest = langDir.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                installed += 1
            } catch {
                ErrorLog.log("install-languages copy failed for \(path) -> \(dest.path)",
                             error: error,
                             class: "IgCmdDispatcher")
                failed.append(path)
            }
        }
        printLine("Installed \(installed) language pack(s) to \(langDir.path)", to: .stdout)
        if !failed.isEmpty {
            let list = failed.joined(separator: ", ")
            printLine("Failed: \(list)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
        return IgCmdExit.success.rawValue
    }

    private func handleInstallThemes(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.InstallThemes")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.installThemes.usage)", to: .stdout)
            printLine("  Pass one or more .igtheme files, or pipe a newline-separated list on stdin.", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let paths = collectPaths(from: args)
        if paths.isEmpty {
            printLine("igcmd install-themes: no file paths provided", to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        let installer = ThemeInstaller()
        var installed: [String] = []
        var failed: [(String, String)] = []
        for path in paths {
            guard let src = resolveExistingFile(path) else {
                failed.append((path, "file not found"))
                continue
            }
            do {
                let pack = try installer.install(archive: src)
                installed.append(pack.folderName)
            } catch {
                ErrorLog.log("ThemeInstaller.install failed for \(src.path)",
                             error: error,
                             class: "IgCmdDispatcher")
                failed.append((path, error.localizedDescription))
            }
        }
        for name in installed {
            printLine("Installed theme: \(name)", to: .stdout)
        }
        if !failed.isEmpty {
            for (p, why) in failed {
                printLine("igcmd install-themes: \(p): \(why)", to: .stderr)
            }
            return IgCmdExit.softwareError.rawValue
        }
        return IgCmdExit.success.rawValue
    }

    private func handleUninstallTheme(args: [String]) -> Int32 {
        let _trace = PerformanceLog.shared.start("Igcmd.Subcommand.UninstallTheme")
        defer { _trace.finish() }
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(IgCmdSubcommand.uninstallTheme.usage)", to: .stdout)
            printLine("  Accepts a folder name (e.g. \"Kobe.Duong-Dieu-Phap\") or a .igtheme path.", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let target = positional.first else {
            printLine("igcmd uninstall-theme: missing <filePath>", to: .stderr)
            return IgCmdExit.usage.rawValue
        }
        // Accept either a path to a .igtheme archive (from which we derive
        // the folder name by stripping the extension) or a literal folder
        // name as it lives under AppPaths.themesDir.
        let folderName: String
        if target.hasSuffix(".igtheme") {
            folderName = (target as NSString).lastPathComponent
                .replacingOccurrences(of: ".igtheme", with: "")
        } else if target.contains("/") {
            folderName = (target as NSString).lastPathComponent
                .replacingOccurrences(of: ".igtheme", with: "")
        } else {
            folderName = target
        }

        let installer = ThemeInstaller()
        do {
            try installer.uninstall(folderName: folderName)
            printLine("Uninstalled theme: \(folderName)", to: .stdout)
            return IgCmdExit.success.rawValue
        } catch {
            ErrorLog.log("ThemeInstaller.uninstall failed for folder=\(folderName)",
                         error: error,
                         class: "IgCmdDispatcher")
            printLine("igcmd uninstall-theme: \(error.localizedDescription)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
    }

    private func handleStartupBoost(args: [String], enable: Bool) -> Int32 {
        let _trace = PerformanceLog.shared.start(
            enable
                ? "Igcmd.Subcommand.SetStartupBoost"
                : "Igcmd.Subcommand.RemoveStartupBoost"
        )
        defer { _trace.finish() }
        let verb = enable ? IgCmdSubcommand.setStartupBoost : IgCmdSubcommand.removeStartupBoost
        if args.contains("--help") || args.contains("-h") {
            printLine("Usage: igcmd \(verb.usage)", to: .stdout)
            return IgCmdExit.success.rawValue
        }
        do {
            try AppPaths.ensureDirectories()
            var partial = Config.Partial()
            partial.startupBoost = enable
            let paths = ConfigPaths.resolve()
            let loader = ConfigLoader(paths: paths)
            _ = try loader.resolveAndPersist(cli: CLIOverrides(partial: partial))
            printLine("Startup Boost \(enable ? "enabled" : "disabled")", to: .stdout)
            return IgCmdExit.success.rawValue
        } catch {
            ErrorLog.log("startup-boost (\(enable ? "enable" : "disable")) failed",
                         error: error,
                         class: "IgCmdDispatcher")
            printLine("igcmd \(verb.rawValue): \(error.localizedDescription)", to: .stderr)
            return IgCmdExit.softwareError.rawValue
        }
    }

    // MARK: - Helpers

    private static let toolVersion = "0.1"

    private func resolveExistingFile(_ pathArg: String) -> URL? {
        let expanded = AppPaths.expandTilde(pathArg)
        let absolute: String
        if (expanded as NSString).isAbsolutePath {
            absolute = expanded
        } else {
            absolute = (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(expanded)
        }
        let url = URL(fileURLWithPath: absolute)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func parseExtensions(_ raw: String) -> [String] {
        // Spec form: ".jpg;.png;.webp" — semicolon-separated, leading-dot
        // optional. Also accept whitespace or newline separators so piped
        // input "just works".
        let separators = CharacterSet(charactersIn: ";,\n\r\t ")
        return raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .map { $0.lowercased() }
    }

    private func collectPaths(from args: [String]) -> [String] {
        var paths = args.filter { !$0.hasPrefix("--") }
        if paths.isEmpty, let piped = readStdinIfAvailable() {
            paths = piped
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return paths
    }

    /// Returns piped stdin contents if and only if stdin is *not* a TTY —
    /// so an interactive `igcmd install-themes` without args doesn't hang
    /// waiting for the user to type a path.
    private func readStdinIfAvailable() -> String? {
        guard isatty(fileno(stdin)) == 0 else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func bundleIdentifierForRegistration() -> String? {
        if let main = Bundle.main.bundleIdentifier, main != "org.swift.PackageManager" {
            return main
        }
        // Fallback — when running unbundled (e.g. `swift run igcmd ...`)
        // we still want a stable identifier so the call doesn't crash. The
        // user can override via env var for advanced setups.
        if let env = ProcessInfo.processInfo.environment["IMAGEGLASS_BUNDLE_ID"] {
            return env
        }
        return "org.imageglass.mac"
    }

    // MARK: - Output

    public enum OutputStream { case stdout, stderr }

    private func printLine(_ s: String, to stream: OutputStream) {
        let line = s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        switch stream {
        case .stdout: FileHandle.standardOutput.write(data)
        case .stderr: FileHandle.standardError.write(data)
        }
    }
}
