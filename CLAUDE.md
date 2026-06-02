# ImageGlass_Mac

PROJECT_DIR is dir `~/BGit/tools_various/ImageGlass_Mac/`

This is the only directory in scope for this project. All code, configuration, and documentation for ImageGlass_Mac live under PROJECT_DIR. Do not modify files outside this directory.

## Project Goal

ImageGlass_Mac is a **Mac-native image viewer application** — Bryan Starbuck's macOS-focused fork of the upstream ImageGlass project. The goal is to deliver a fast, modern, ad-free image viewer that feels like a first-class macOS app (native window chrome, gestures, dark/light system theme, Apple Silicon performance) while preserving the broad format support and viewing features that ImageGlass is known for.

The fork is **not** a cross-platform rebuild — it is a Mac-first product. Upstream Windows-specific code paths (WebView2, File Explorer integration, Microsoft Store packaging, Windows 11 backdrop, etc.) are not the target. The reference material from the upstream project is included below for context only.

## Bryan Starbuck's Fork Improvements

On top of the Mac-native viewer baseline, the fork adds the following improvements:

1. **MCP support** — Add Model Context Protocol (MCP) server support so that Claude Code (and other MCP clients) can drive and configure ImageGlass from outside the application. The MCP server is the integration point that lets external AI tooling read and modify the local-storage configuration described below.

2. **Modular UI panels** — Add a new column to the ImageGlass UI that hosts modular UI panels. The initial panel is a **directory / filename panel** that lists the images and files that are currently in scope. The panel can be toggled into a **file-tree view** that shows the same files arranged in their directory hierarchy. The architecture is panel-based so additional panels can be added over time without disturbing the core viewer.

3. **Scope controls** — Give the user explicit controls to define what is included in the active file list and what is excluded. Scopes can be expressed as directories, directory hierarchies, glob/extension criteria, or named rule sets.

4. **Local Storage feature** — A local-filesystem-backed configuration store, kept as plain text files on disk in a known directory. Each entry records:
   * The last time the scope was evaluated / loaded.
   * The list of images (and other files) that were resolved into the file list on that run.
   * The list of source directories or criteria that drove the scope.

   The runtime behavior: Local Storage holds a list of directories or criteria, walks the matching directory hierarchies, finds the files that satisfy the scope, and that resolved list is what gets shown in the directory/filename panel.

5. **MCP-driven editing of Local Storage** — Because the Local Storage state is plain text files and is fronted by the MCP server, Claude Code can read and modify the scope definitions, swap in new directory lists, change inclusion/exclusion criteria, and trigger re-evaluation — all without the user having to edit settings inside the GUI.

---

# Programming Language and Frameworks

This section is the technology decision for building ImageGlass_Mac. It is based on what Apple ships as first-class on macOS in 2026, what other modern Mac-native image viewers (Preview.app, Pixea, Phiewer, Lyn, NeoFinder) are built on, and what the fork improvements above actually require (custom panels, file-system scanning, MCP integration, GPU-accelerated image rendering).

## Language: Swift 6

**Use Swift 6 as the primary language.** It is Apple's first-class language for macOS, compiles natively for Apple Silicon (arm64) and Intel (x86_64) with no runtime VM, and has the full surface area of Apple's SDKs available without bridging.

Key reasons:
* **Native performance on Apple Silicon** — direct LLVM-compiled binary, no JIT, no managed runtime. Critical for a "fast" image viewer goal.
* **Full SDK access** — every Cocoa / AppKit / SwiftUI / ImageIO / Metal API is callable directly from Swift; no marshaling layer.
* **Modern concurrency** — Swift Concurrency (`async/await`, actors, `Task`, `TaskGroup`) and strict concurrency checking in Swift 6 make off-main-thread image decoding and directory walking safe and ergonomic.
* **Memory safety** — ARC plus value types reduces whole classes of bugs versus C/C++/Objective-C.
* **Active language** — Swift 6 (2024) added typed throws, strict concurrency, ownership refinements; Apple is investing heavily.

Do **not** use:
* **Objective-C** — fine for interop but not the right primary language for a new app in 2026.
* **C# / .NET MAUI / Avalonia** — the upstream ImageGlass is C#/.NET on Windows; this fork is not. Cross-platform UI frameworks lose the "feels native" goal and add a runtime dependency.
* **Electron / Tauri / web stack** — explicitly disqualified by the "first-class macOS app" goal. Bundle size, memory, and visual fidelity all suffer.
* **Flutter / Qt** — same reasons. They draw their own widgets instead of using AppKit, which violates the native-feel goal.
* **Mac Catalyst** — Catalyst is for porting iPad apps to Mac. This fork is Mac-first, so start with AppKit/SwiftUI directly and skip the Catalyst translation layer.

## Primary UI Framework: SwiftUI + AppKit interop

**Use SwiftUI as the primary UI layer, with AppKit interop where SwiftUI is too limited.** This is the standard pattern for serious Mac-native apps shipping in 2025–2026.

* **SwiftUI** (macOS 14 Sonoma minimum; macOS 15 Sequoia preferred) handles the main layout, panels, toolbar, menus, settings, and theming. Built-in features that directly serve this project: `NavigationSplitView` for the multi-column layout (sidebar / file panel / viewer), `Table` for file lists, `OutlineGroup` for the file-tree view, automatic light/dark theme tracking via `@Environment(\.colorScheme)`, native gesture modifiers (`MagnifyGesture`, `RotateGesture`, `DragGesture`).
* **AppKit** (`NSWindow`, `NSWindowDelegate`, `NSView`, `NSResponder`, `NSDocumentController`, `NSOpenPanel`, `NSPasteboard`, `NSServicesMenu`) is reached via `NSViewRepresentable` / `NSWindowDelegateAdaptor` / `NSApplicationDelegateAdaptor` for the things SwiftUI still doesn't do well in 2026:
  * Custom window chrome / unified title bar / borderless window behavior.
  * Precise control over `NSScrollView` for high-performance zoom + pan of huge images.
  * Drag-and-drop from Finder with full UTI / file-promise support.
  * `NSDocument` model for proper "Recent Files," file-coordination, and Versions integration.
  * Services menu and `NSSharingService` for system-wide share sheet.

The conventional split: SwiftUI owns layout and state, AppKit owns the image canvas and window-level behavior. This is how Pixea, Lyn, and other modern Mac viewers are structured.

## Image Decoding and Rendering

* **ImageIO** (`CGImageSource`, `CGImageDestination`) — Apple's native, hardware-accelerated decoder. As of macOS 15 it natively decodes JPEG, PNG, TIFF, BMP, GIF, HEIC / HEIF (incl. HDR), AVIF, JXL (JPEG XL), WebP, RAW (CR2/CR3/NEF/ARW/DNG and others via the system RAW pipeline), PSD (flattened), ICO, ICNS. This covers the large majority of what upstream ImageGlass supports through ImageMagick.
* **Core Graphics / Quartz** (`CGContext`, `CGImage`) — pixel-level access, color-space conversion, and rendering.
* **Core Image** (`CIImage`, `CIFilter`) — GPU-backed filters for rotate / flip / crop / resize / color adjustment. Backed by Metal on Apple Silicon.
* **Metal + MetalKit** (`MTKView`, `CAMetalLayer`) — for the actual image canvas. Critical for buttery 60/120 Hz pan/zoom of large images (40 MP+ RAW, panoramas) without dropping frames. Use Metal directly for the viewer canvas; SwiftUI's `Image` is fine for thumbnails but not for the main view.
* **AVFoundation** — needed for embedded motion video inside JPEGs (Apple Live Photos, motion-photo JPEGs).
* **UniformTypeIdentifiers** (`UTType`) — modern way to identify formats, route files to the right decoder, and declare document types in `Info.plist`.

For formats ImageIO does **not** cover (SVG with full editing semantics, PSD with layers, EXR HDR, FITS, EPS/AI without Ghostscript, BPG, QOI, exotic RAW), bundle a third-party decoder behind a `ImageDecoder` protocol:
* **libvips** (`libvips.dylib`, MIT) — fast streaming decoder, good for huge images.
* **ImageMagick** (`Magick++` / `MagickWand`, ImageMagick license — note that GPL v3 compatibility is fine since the fork inherits GPL v3 from upstream).
* **librsvg** for SVG, **OpenEXR** for `.exr`.

Distribute these as signed dylibs inside the `.app` bundle or as XCFrameworks via Swift Package Manager. Never assume a Homebrew install on the user's machine.

## MCP Server

The MCP (Model Context Protocol) integration runs inside the app process and exposes the Local Storage state. Two viable approaches:

1. **In-process Swift MCP server (recommended)** — implement the MCP server in Swift using `URLSession`'s server-side capabilities or `swift-nio` (Apple's official async networking library). Stdio transport works for `claude` CLI clients; HTTP/SSE transport works for desktop clients. Keeping it in-process avoids a separate sidecar binary and shares the running scope state directly.
2. **Sidecar process** — bundle a small Node or Python MCP server inside `Contents/Resources/` and launch via `Process` / `NSTask` on app start. Simpler to write (mature MCP SDKs in TypeScript and Python) but adds a runtime dependency and IPC layer.

Start with approach #1. Anthropic publishes an [official Swift MCP SDK](https://github.com/modelcontextprotocol) (the broader MCP org maintains SDKs in multiple languages); use it if available, otherwise the protocol is small enough to implement directly over JSON-RPC.

## File System and Scope Engine

* **`FileManager`** for directory enumeration; `FileManager.default.enumerator(at:includingPropertiesForKeys:options:)` gives a lazy `DirectoryEnumerator` that's the right primitive for the scope-walker.
* **`URL` + resource keys** (`.isDirectoryKey`, `.contentModificationDateKey`, `.fileSizeKey`, `.typeIdentifierKey`) for fast metadata reads without re-stat'ing files.
* **`DispatchSourceFileSystemObject` / `FSEvents` via `kqueue`** for the real-time file-change monitoring that upstream ImageGlass has. `FSEventStream` is the higher-level wrapper.
* **Security-scoped bookmarks** — required for sandboxed builds to remember user-granted folder access across launches. Store the bookmarks alongside the Local Storage scope definitions.
* **Glob matching** — `fnmatch(3)` via a small Swift wrapper, or write a simple matcher. The scope criteria don't need full PCRE.

## App Lifecycle, Persistence, and Settings

* **`@main` `App` struct (SwiftUI)** as the entry point, with `NSApplicationDelegateAdaptor` for the lifecycle hooks SwiftUI doesn't expose.
* **`Scene` / `WindowGroup` / `Settings` scenes** for windows and Preferences.
* **`UserDefaults`** for small UI prefs (last window size, last sort order, theme override).
* **Local Storage (project-specific, see fork improvement #4)** — plain text files (JSON or TOML — JSON is simpler with `Codable`) in `~/Library/Application Support/ImageGlass_Mac/scopes/`. **Not** `UserDefaults` for these, because the MCP server needs to edit them as files.
* **`Codable`** for all on-disk schemas.

## Build, Packaging, Signing

* **Xcode 16+** as the IDE / build system. Build settings live in an `.xcodeproj` or `.xcworkspace`.
* **Swift Package Manager** for dependencies (declared in `Package.swift` or as Xcode SPM references). Avoid CocoaPods and Carthage for a new project.
* **Minimum deployment target: macOS 14 (Sonoma)**, ideally macOS 15 (Sequoia), to get the SwiftUI improvements (`NavigationSplitView` maturity, `Table` features, observation framework, native AVIF/JXL decoding in ImageIO).
* **Architectures: arm64 + x86_64 universal binary.** Apple Silicon primary; Intel as a courtesy for users still on 2019-era hardware.
* **Code signing + notarization**: Developer ID Application certificate, hardened runtime, notarize via `notarytool`, staple the ticket. Required for distribution outside the Mac App Store; required by Gatekeeper.
* **App Sandbox** — enable for App Store distribution; can be disabled for Developer ID distribution. The Local Storage + arbitrary directory scopes work better with sandbox **off** or with broad file-access entitlements (`com.apple.security.files.user-selected.read-write` + security-scoped bookmarks).
* **Distribution channels**: direct download as a notarized `.dmg` from a project site, and/or Mac App Store. The upstream GPL v3 license is **incompatible with the Mac App Store** (App Store terms conflict with GPL v3), so direct-download is the realistic path for a GPL v3 fork.

## Testing

* **XCTest** for unit tests (Apple-standard, integrated with Xcode and SwiftPM).
* **Swift Testing** (the new macro-based framework introduced in 2024) for newer test code — works alongside XCTest.
* **XCUITest** for UI automation.
* **Snapshot testing** via `swift-snapshot-testing` (Point-Free) for image-rendering correctness.

## Summary Stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6 |
| App shell | SwiftUI `App` + `NSApplicationDelegateAdaptor` |
| Layout | SwiftUI (`NavigationSplitView`, `Table`, `OutlineGroup`) |
| Window-level UI | AppKit (`NSWindow`, `NSViewRepresentable`) |
| Image decoding | ImageIO + Core Graphics; libvips / ImageMagick for the rest |
| Image canvas | Metal / `MTKView` |
| Image effects | Core Image |
| Concurrency | Swift Concurrency (`async/await`, actors) |
| File walking | `FileManager` enumerator + `FSEventStream` |
| Persistence | `Codable` JSON files in `~/Library/Application Support/ImageGlass_Mac/` |
| Small prefs | `UserDefaults` |
| MCP server | In-process Swift, `swift-nio` transport |
| Dependencies | Swift Package Manager |
| IDE / build | Xcode 16+ |
| Min OS | macOS 14 (Sonoma); target macOS 15 (Sequoia) |
| Architectures | arm64 + x86_64 universal |
| Distribution | Developer ID + notarized `.dmg` (GPL v3 blocks App Store) |
| Tests | XCTest + Swift Testing + XCUITest |

---

# Upstream ImageGlass Reference

**ImageGlass** is a free and open-source, lightweight, versatile image viewer developed by Vietnamese software engineer Duong Dieu Phap (also known by the GitHub handle *d2phap*). It features a clean, minimal, and modern user interface optimized for fast and seamless browsing of over 90 common and specialized image formats, including WEBP, GIF, SVG, AVIF, JXL, HEIC, RAW, and many others. The application emphasizes performance, customization, and an ad-free experience, making it suitable for both casual users and professionals such as designers and photographers who require efficient image viewing and basic manipulation tools without the overhead of heavier photo-editing software.

ImageGlass is cross-platform, officially supporting Windows (10/11 64-bit, version 1809 or later), macOS, and Linux. It is distributed in two primary editions: **ImageGlass Classic** (the free, fully open-source version available from the official website) and **ImageGlass Store** (a paid version exclusive to the Microsoft Store with a 7-day trial, automatic updates, and seamless hotfixes). The project has been under active development for over 16 years as of 2026, with more than 7 million downloads, approximately 13,100 GitHub stars, 700 forks, and 48 contributors. The source code is hosted on GitHub at [d2phap/ImageGlass](https://github.com/d2phap/ImageGlass) and is licensed under the GNU General Public License version 3 (GPL v3).

## History

ImageGlass traces its origins to 2010, when Duong Dieu Phap began development as a personal project to create a simple yet powerful image viewer for Windows. The copyright is held by Phap from 2010 to 2025 (with ongoing updates). The public GitHub repository shows the first commit in February 2014, though the software had already been in use and iterated upon privately for several years prior. Over time, it evolved from a basic Windows-only viewer into a feature-rich, cross-platform application.

Key milestones include the integration of the ImageMagick library (via Magick.NET) for broad format support, the addition of advanced customization options, real-time image monitoring, and multi-frame/animation handling. Major version 9.x releases introduced lossless compression (version 9.1), image resizing (9.2), embedded motion video viewing in JPEGs (9.3), and full File Explorer sort-order synchronization (9.3). As of June 2026, the latest stable release is ImageGlass 9.5.0.515 (released May 2026), with ongoing development on the *develop* branch. The project has maintained consistent activity, including community-driven contributions and third-party tool integrations.

## Features

ImageGlass is designed for speed and simplicity while offering advanced capabilities that appeal to both regular users and power users. It supports drag-and-drop, clipboard pasting (image data, files, or paths), and command-line utilities. Key categories of features include:

### Viewing Features
- **Broad format support** via ImageMagick integration, with real-time file change monitoring.
- **Animation and multi-frame support** for GIF, WEBP, APNG, SVG (via WebView2 by default), TIF, ICO, and more. Users can pause/resume animations, save individual frames, or export all frames.
- **Zoom and display options**: Six zoom modes (Auto, Lock, Scale to Width/Height/Fit/Fill) with customizable interpolation; window modes including full-screen, frameless, and window-fit; slideshow mode with countdown timer.
- **Thumbnail previews** and fast folder navigation.
- **Color tools**: Built-in color picker (multiple formats) and simultaneous viewing of one or more color channels.
- **Metadata and extras**: EXIF/metadata viewing (via companion ExifGlass tool); embedded motion video in JPEGs; color management.
- **Gestures**: Touch-device support for zooming and panning.
- **Sorting**: Full File Explorer sort-order integration (name, date, type, rating, etc.), including search results.

### Editing and Manipulation Features
- Rotate, flip, crop, resize (since v9.2), and lossless compression (since v9.1).
- Format conversion (up to 10 output formats).
- Seamless integration with third-party editing apps via ImageGlass.Tools APIs and custom hotkeys.

### Customization and Usability
- Fully customizable UI layout, toolbar, keyboard/mouse shortcuts, themes, icon packs, and language packs.
- Automatic synchronization with system theme (light/dark mode).
- Advanced configuration files for power users (pre-defined or locked settings).
- Multiple instances support; clipboard operations for multiple files.
- Plugin support (e.g., ImageMixture).

### Limitations and Notes
- SVG viewing defaults to WebView2 (some editing features disabled; can be switched to native engine).
- Certain features (e.g., window backdrop) require Windows 11.
- File Explorer sort-order syncing requires the Explorer window to remain open (minimizable).
- Some formats (AI/EPS) require Ghostscript; others (BPG) require additional tools.

ImageGlass is intentionally lightweight and focused on viewing efficiency rather than full-featured editing (unlike Adobe Photoshop or GIMP). It positions itself as a faster, more modern alternative to tools like IrfanView or Windows Photos, with superior customization and no advertisements.

## Supported Image Formats

ImageGlass supports over 90 formats through ImageMagick. Users can extend support by customizing the extension list for any ImageMagick-compatible format. Major categories include:

- **Raster**: BMP, CUR, DIB, EXIF, EXR, GIF, HEIC/HEIF (non-animated), ICO, JPEG/JPG/JFIF/JP2/JXL (non-animated), PNG, PSD, TGA, TIFF, WEBP, and many others (PBM, PCX, PGM, PPM, QOI, etc.).
- **Vector**: SVG, AI (requires Ghostscript), EMF, EPS (requires Ghostscript), WMF, WPG.
- **Animation**: APNG, GIF, WEBP, MJPEG (plus multi-frame support for TIF/ICO).
- **RAW/Scientific/Special**: FITS, HDR, various RAW files; base64 text files (.b64) and clipboard base64 content.
- **Save-As Support**: Available for BMP, GIF, JPG, PNG, TIFF, WEBP, EMF, ICO, and others.

Animated support is available for most relevant formats, but AVIF, HEIC, HEIF, and JXL are currently non-animated only. Metadata handling (EXIF, etc.) and color channel viewing are built-in for applicable files.

## Versions and Distribution

- **ImageGlass Classic** (free): Full feature set, distributed via imageglass.org and mirrors. Recommended registration for commercial use.
- **ImageGlass Store** (paid, 7-day trial): Microsoft Store exclusive; includes auto-updates and faster installation.

Both versions share the same core functionality. The Store edition funds ongoing development.

## Licensing

The source code is released under the GNU GPL v3. ImageGlass Classic is free for personal and commercial use (registration encouraged for businesses). The Store version requires purchase. The EULA disclaims all warranties and limits liability; trademarks (name and logo) require written permission for use in derivative works. Copyright is held solely by Duong Dieu Phap.

## Development and Community

The project is primarily developed by Duong Dieu Phap, with 48 contributors as of 2026. Development occurs on GitHub (4,431+ commits on the *develop* branch). Community support is available via Discord, GitHub issues, and documentation at imageglass.org/docs. Sponsors and donations (GitHub Sponsors, Patreon, PayPal, Stripe) sustain development. Third-party tools (e.g., ExifGlass) and the ImageGlass.Tools API enable ecosystem extensions.

## Usage, Audience, and Scope

ImageGlass is intended for anyone seeking a fast, customizable, ad-free image viewer as a replacement for default OS tools or heavier alternatives. Its primary audience includes:
- **Casual users**: For quick photo browsing on Windows, macOS, or Linux.
- **Designers and photographers**: Who value format support, metadata tools, color management, and workflow integrations.
- **Power users**: Who appreciate advanced configs, shortcuts, themes, and command-line/scripting capabilities.
- **Open-source enthusiasts and developers**: Due to GPL licensing, plugin support, and community contributions.

With 7 million+ downloads and strong GitHub metrics, it serves a global user base. Its scope is deliberately focused on high-performance **viewing** with lightweight editing and extensive customization, rather than comprehensive photo management or professional retouching. It integrates well into broader workflows via third-party tools and is suitable for both personal and commercial environments.

The official website is [imageglass.org](https://imageglass.org), with full documentation, downloads, news, and support options.
