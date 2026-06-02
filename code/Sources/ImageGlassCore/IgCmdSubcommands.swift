import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Namespace for `igcmd` subcommand handlers. Each handler takes the argv
/// *after* the subcommand token and returns an integer exit code.
///
/// Handlers must be pure w.r.t. process state — they return an exit code
/// rather than calling `exit()` so tests can drive them and assert.
public enum IgCmd {

    // MARK: set-wallpaper

    /// `set-wallpaper <imgPath> [style]`
    /// Style strings: fit, fill, stretch, tile, center. We map them onto the
    /// `NSImageScaling` values accepted by `NSWorkspace.setDesktopImageURL`.
    public static func setWallpaper(_ args: [String]) -> Int32 {
        guard let path = args.first else {
            FileHandle.standardError.write(Data("igcmd set-wallpaper: missing <imgPath>\n".utf8))
            return 64
        }
        let style = args.dropFirst().first ?? "fill"
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("igcmd set-wallpaper: file not found: \(url.path)\n".utf8))
            return 66
        }
        #if canImport(AppKit)
        let options = wallpaperOptions(for: style)
        guard let screen = NSScreen.main else {
            FileHandle.standardError.write(Data("igcmd set-wallpaper: no main screen\n".utf8))
            return 70
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            print("Wallpaper set to \(url.path) (style=\(style))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("igcmd set-wallpaper: failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
        #else
        FileHandle.standardError.write(Data("igcmd set-wallpaper: AppKit unavailable on this platform\n".utf8))
        return 75
        #endif
    }

    #if canImport(AppKit)
    static func wallpaperOptions(for style: String) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        let key = NSWorkspace.DesktopImageOptionKey.imageScaling
        switch style.lowercased() {
        case "fit":     return [key: NSImageScaling.scaleProportionallyDown.rawValue]
        case "fill":    return [key: NSImageScaling.scaleProportionallyUpOrDown.rawValue]
        case "stretch": return [key: NSImageScaling.scaleAxesIndependently.rawValue]
        case "center":  return [key: NSImageScaling.scaleNone.rawValue]
        case "tile":
            // macOS no longer offers true tiling via this API; closest
            // analogue is "none" plus the allow-clipping flag.
            return [
                key: NSImageScaling.scaleNone.rawValue,
                NSWorkspace.DesktopImageOptionKey.allowClipping: true,
            ]
        default:        return [key: NSImageScaling.scaleProportionallyUpOrDown.rawValue]
        }
    }
    #endif

    // MARK: set-lock-screen (Mac stub)

    /// `set-lock-screen <imgPath>` — macOS has no public API for setting the
    /// lock screen background, so we print a clear message and exit non-zero.
    /// This is the *correct* terminal behaviour, not a placeholder.
    public static func setLockScreen(_ args: [String]) -> Int32 {
        _ = args
        FileHandle.standardError.write(Data(
            "igcmd set-lock-screen: not supported on macOS — no public API exists for this. Use System Settings > Lock Screen instead.\n".utf8
        ))
        return 75 // EX_TEMPFAIL — request well-formed but not actionable.
    }

    // MARK: set-default-viewer

    /// `set-default-viewer [exts] [--per-machine]`
    /// `exts` is a `;`-separated list like `.jpg;.png;.gif`. We use
    /// `LSSetDefaultRoleHandlerForContentType` to register the current bundle
    /// (`Bundle.main.bundleIdentifier`) as the viewer (role: .viewer).
    public static func setDefaultViewer(_ args: [String]) -> Int32 {
        let (extsArg, perMachine) = parseExtsAndScope(args)
        if perMachine {
            print("igcmd: --per-machine has no macOS analogue (system-wide LaunchServices registration is not user-installable). Treating as no-op.")
        }
        return changeDefaultViewer(extsArg: extsArg, register: true)
    }

    /// `remove-default-viewer [exts] [--per-machine]`
    public static func removeDefaultViewer(_ args: [String]) -> Int32 {
        let (extsArg, perMachine) = parseExtsAndScope(args)
        if perMachine {
            print("igcmd: --per-machine has no macOS analogue. Treating as no-op.")
        }
        return changeDefaultViewer(extsArg: extsArg, register: false)
    }

    static func parseExtsAndScope(_ args: [String]) -> (exts: String?, perMachine: Bool) {
        var exts: String? = nil
        var perMachine = false
        for a in args {
            if a == "--per-machine" { perMachine = true; continue }
            if exts == nil { exts = a }
        }
        return (exts, perMachine)
    }

    static let defaultViewerExtensions: [String] =
        [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tiff", ".bmp"]

    static func changeDefaultViewer(extsArg: String?, register: Bool) -> Int32 {
        let extString = extsArg ?? defaultViewerExtensions.joined(separator: ";")
        let exts = extString
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        guard !exts.isEmpty else {
            FileHandle.standardError.write(Data("igcmd: no extensions specified\n".utf8))
            return 64
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "org.imageglass.app"
        var failures = 0
        for ext in exts {
            let utiName = utiIdentifier(forExtension: ext)
            #if canImport(CoreServices)
            let result: OSStatus
            if register {
                result = LSSetDefaultRoleHandlerForContentType(
                    utiName as CFString,
                    LSRolesMask.viewer,
                    bundleID as CFString
                )
            } else {
                // "Unregister" by handing the role back to a generic system
                // handler. We can't truly remove a registration via the
                // public API, so we point it at a benign system bundle.
                result = LSSetDefaultRoleHandlerForContentType(
                    utiName as CFString,
                    LSRolesMask.viewer,
                    "com.apple.Preview" as CFString
                )
            }
            if result != noErr {
                FileHandle.standardError.write(Data(
                    "igcmd: LaunchServices call for .\(ext) failed (OSStatus=\(result))\n".utf8
                ))
                failures += 1
            } else {
                print("\(register ? "Registered" : "Reset") .\(ext) -> \(utiName)")
            }
            #else
            FileHandle.standardError.write(Data("igcmd: CoreServices unavailable\n".utf8))
            failures += 1
            #endif
        }
        return failures == 0 ? 0 : 1
    }

    /// Map a file extension to its UTI string. Uses the modern UTType API
    /// where available; falls back to a small built-in table otherwise.
    static func utiIdentifier(forExtension ext: String) -> String {
        let lower = ext.lowercased()
        #if canImport(UniformTypeIdentifiers)
        if let t = UTType(filenameExtension: lower) {
            return t.identifier
        }
        #endif
        let fallback: [String: String] = [
            "jpg":  "public.jpeg",
            "jpeg": "public.jpeg",
            "png":  "public.png",
            "gif":  "com.compuserve.gif",
            "webp": "org.webmproject.webp",
            "heic": "public.heic",
            "tiff": "public.tiff",
            "bmp":  "com.microsoft.bmp",
        ]
        return fallback[lower] ?? "public.image"
    }

    // MARK: export-frames

    /// `export-frames <filePath>` — write every frame of a multi-image source
    /// (GIF/HEIC sequence/animated WebP/multi-page TIFF) to sibling files.
    public static func exportFrames(_ args: [String]) -> Int32 {
        guard let path = args.first else {
            FileHandle.standardError.write(Data("igcmd export-frames: missing <filePath>\n".utf8))
            return 64
        }
        let expanded = AppPaths.expandTilde(path)
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("igcmd export-frames: file not found: \(url.path)\n".utf8))
            return 66
        }
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            FileHandle.standardError.write(Data("igcmd export-frames: cannot open as image\n".utf8))
            return 1
        }
        let count = CGImageSourceGetCount(src)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let outType: String = (CGImageSourceGetType(src) as String?) ?? "public.png"
        var written = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let frameURL = dir.appendingPathComponent("\(stem)_frame_\(String(format: "%04d", i)).png")
            #if canImport(UniformTypeIdentifiers)
            let pngType = UTType.png.identifier as CFString
            #else
            let pngType = "public.png" as CFString
            #endif
            _ = outType // kept for future format-preserving export
            guard let dest = CGImageDestinationCreateWithURL(frameURL as CFURL, pngType, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
            if CGImageDestinationFinalize(dest) {
                written += 1
            }
        }
        print("Wrote \(written) frame(s) from \(url.lastPathComponent)")
        return written > 0 ? 0 : 1
        #else
        FileHandle.standardError.write(Data("igcmd export-frames: ImageIO unavailable\n".utf8))
        return 75
        #endif
    }

    // MARK: quick-setup

    /// `quick-setup` — minimal first-run bootstrap. Ensures app-support
    /// directories exist and prints a friendly intro. A real wizard would
    /// live in the SwiftUI app; this is the headless equivalent.
    public static func quickSetup(_ args: [String]) -> Int32 {
        _ = args
        do {
            try AppPaths.ensureDirectories()
        } catch {
            FileHandle.standardError.write(Data("igcmd quick-setup: \(error.localizedDescription)\n".utf8))
            return 1
        }
        let lines = [
            "ImageGlass — first-run setup",
            "----------------------------",
            "Created application support layout at:",
            "  \(AppPaths.appSupportDir.path)",
            "",
            "  scopes/     — saved scopes (one JSON file each)",
            "  languages/  — installed .iglang packs",
            "  themes/     — installed theme packs",
            "",
            "Launch the ImageGlass app to begin, or run `igcmd --help` for",
            "the full CLI reference.",
        ]
        for line in lines { print(line) }
        return 0
    }

    // MARK: check-for-update

    /// `check-for-update` — would HEAD a release manifest URL. There is no
    /// update server wired up yet, so we say so plainly.
    public static func checkForUpdate(_ args: [String]) -> Int32 {
        _ = args
        print("igcmd check-for-update: no update server configured.")
        return 0
    }

    // MARK: install-languages

    /// `install-languages [filePaths...]` — copy each `.iglang` JSON file
    /// into `~/Library/Application Support/ImageGlass/languages/`.
    public static func installLanguages(_ args: [String]) -> Int32 {
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("igcmd install-languages: no file paths supplied\n".utf8))
            return 64
        }
        do { try AppPaths.ensureDirectories() } catch {
            FileHandle.standardError.write(Data("igcmd install-languages: \(error.localizedDescription)\n".utf8))
            return 1
        }
        var failures = 0
        let fm = FileManager.default
        for raw in args {
            let src = URL(fileURLWithPath: AppPaths.expandTilde(raw))
            guard fm.fileExists(atPath: src.path) else {
                FileHandle.standardError.write(Data("igcmd install-languages: file not found: \(src.path)\n".utf8))
                failures += 1
                continue
            }
            // Validate that the file is JSON before adopting it.
            do {
                let data = try Data(contentsOf: src)
                _ = try JSONSerialization.jsonObject(with: data)
            } catch {
                FileHandle.standardError.write(Data(
                    "igcmd install-languages: \(src.lastPathComponent) is not valid JSON (\(error.localizedDescription))\n".utf8
                ))
                failures += 1
                continue
            }
            let dst = AppPaths.languagesDir.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                print("Installed language pack: \(dst.lastPathComponent)")
            } catch {
                FileHandle.standardError.write(Data(
                    "igcmd install-languages: copy failed for \(src.lastPathComponent): \(error.localizedDescription)\n".utf8
                ))
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: install-themes

    /// `install-themes [filePaths...]` — the real theme pack loader lives in
    /// `ImageGlassCore`'s themes subsystem (owned by another agent). Until
    /// it lands we fall back to a verbatim copy into `themes/`.
    public static func installThemes(_ args: [String]) -> Int32 {
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("igcmd install-themes: no file paths supplied\n".utf8))
            return 64
        }
        do { try AppPaths.ensureDirectories() } catch {
            FileHandle.standardError.write(Data("igcmd install-themes: \(error.localizedDescription)\n".utf8))
            return 1
        }
        var failures = 0
        let fm = FileManager.default
        for raw in args {
            let src = URL(fileURLWithPath: AppPaths.expandTilde(raw))
            guard fm.fileExists(atPath: src.path) else {
                FileHandle.standardError.write(Data("igcmd install-themes: file not found: \(src.path)\n".utf8))
                failures += 1
                continue
            }
            let dst = AppPaths.themesDir.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                print("Installed theme pack: \(dst.lastPathComponent)")
            } catch {
                FileHandle.standardError.write(Data(
                    "igcmd install-themes: copy failed for \(src.lastPathComponent): \(error.localizedDescription)\n".utf8
                ))
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: uninstall-theme

    /// `uninstall-theme <filePath>` — remove a previously-installed theme.
    /// Accepts either a bare filename ("Dark.igtheme") looked up in the
    /// themes dir, or an absolute path inside the themes dir.
    public static func uninstallTheme(_ args: [String]) -> Int32 {
        guard let raw = args.first else {
            FileHandle.standardError.write(Data("igcmd uninstall-theme: missing <filePath>\n".utf8))
            return 64
        }
        let expanded = AppPaths.expandTilde(raw)
        let fm = FileManager.default
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = AppPaths.themesDir.appendingPathComponent(expanded)
        }
        guard fm.fileExists(atPath: candidate.path) else {
            FileHandle.standardError.write(Data("igcmd uninstall-theme: not found: \(candidate.path)\n".utf8))
            return 66
        }
        do {
            try fm.removeItem(at: candidate)
            print("Removed theme: \(candidate.lastPathComponent)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("igcmd uninstall-theme: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: startup boost

    /// `set-startup-boost` — Windows ImageGlass installs a scheduled task to
    /// preload the binary. macOS has no exact analogue: a `LaunchAgent`
    /// `.plist` in `~/Library/LaunchAgents/` is the closest equivalent, but
    /// that requires the *installed* app bundle path which we don't know
    /// when running from `swift run`. We therefore record intent as a flag
    /// file under app support, leaving the actual `LaunchAgent` install for
    /// a future packaging step. This keeps the CLI behaviour observable
    /// (and testable) without baking in an installer assumption.
    public static func setStartupBoost(_ args: [String]) -> Int32 {
        _ = args
        do {
            try AppPaths.ensureDirectories()
            try Data().write(to: AppPaths.startupBoostFlag)
            print("Startup boost enabled (flag written to \(AppPaths.startupBoostFlag.path)).")
            print("Note: a LaunchAgent plist will be installed by the app packaging step.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("igcmd set-startup-boost: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    public static func removeStartupBoost(_ args: [String]) -> Int32 {
        _ = args
        let fm = FileManager.default
        let url = AppPaths.startupBoostFlag
        if !fm.fileExists(atPath: url.path) {
            print("Startup boost was not enabled — nothing to remove.")
            return 0
        }
        do {
            try fm.removeItem(at: url)
            print("Startup boost disabled.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("igcmd remove-startup-boost: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
