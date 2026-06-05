# ImageGlass_Mac — Developer & Install Guide

One-stop doc: what it is, how to install, how to build/run, how it's laid out,
how the Mac-specific features work, and how to troubleshoot. Written for a
developer picking this project up on a Mac.

> This file consolidates the install steps from `README.md`, the recipe set in
> `justfile`, and the deep-dive specs under `docs/`. When this file and a
> `docs/*.mdx` spec disagree, the spec is the source of truth for *behavior*;
> the `justfile` is the source of truth for *commands*.

---

## 1. What this is

A **macOS-native image viewer** — Bryan Starbuck's Mac-first fork of
[ImageGlass](https://github.com/d2phap/ImageGlass). Goal: fast, modern, ad-free
viewer that feels like a first-class macOS app, handling large local image sets
(hundreds of files) for rapid click-through review.

Mac-only. Not a cross-platform rebuild. Windows code paths (WebView2, File
Explorer integration, MS Store, Win11 backdrop) are out of scope.

### Fork additions on top of the viewer

1. **MCP server** — Claude Code (any MCP client) can drive/configure the app from outside.
2. **Modular UI panels** — left column hosting panels; first panel is a directory/filename list with a file-tree toggle.
3. **Scope controls** — explicit include/exclude rules: directories, hierarchies, glob/extension, named rule sets.
4. **Local Storage** — plain-text config on disk: scope definitions, last-evaluated time, resolved file list.
5. **MCP-driven Local Storage editing** — because it's plain text fronted by MCP, Claude Code can edit scopes and trigger re-evaluation without touching the GUI.

---

## 2. Tech stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6 (Swift 5 language mode for now — see `Package.swift`) |
| Build | Swift Package Manager (`code/Package.swift`), driven by `just` |
| App shell | SwiftUI `App` + `NSApplicationDelegateAdaptor` |
| Layout | SwiftUI (`NavigationSplitView`, `Table`, `OutlineGroup`) |
| Window-level UI | AppKit (`NSWindow`, `NSViewRepresentable`, `NSOutlineView`) |
| Image decode | ImageIO + Core Graphics (Apple-native, hardware-accelerated) |
| Concurrency | Swift Concurrency (`async/await`, actors) |
| File walking | `FileManager` enumerator |
| Persistence | `Codable` JSON/YAML in `~/Library/Application Support/ImageGlass_Mac/` |
| MCP server | In-process Swift, JSON-RPC over stdio |
| Min OS | macOS 14 (Sonoma); target macOS 15 |
| Arch | arm64 + x86_64 universal |

---

## 3. Prerequisites

* macOS 14 (Sonoma) or later
* Xcode 16+ command-line tools — `xcode-select --install`
* [`just`](https://github.com/casey/just) — `brew install just`

Everything else (SwiftPM deps, native libs in `vendor/`) is fetched by recipes.
No Homebrew dylibs assumed.

---

## 4. Install / build / run

Fresh clone:

```sh
brew install just      # one-time, if missing
just bootstrap         # check tools, resolve SwiftPM deps, debug build
just run               # build + launch the app (detached)
```

`just bootstrap` is the only command a fresh clone needs. It verifies tooling,
runs SwiftPM resolution, fetches native libs into `vendor/` (none today —
ImageIO covers the current format set), and does a debug build.

Plain SwiftPM works too:

```sh
cd code
swift build --product ImageGlass
swift run ImageGlass
```

### For the dev taking over — debug in Xcode

```sh
just debug             # opens code/Package.swift in Xcode, starts the debugger
```

First open on a fresh clone takes ~30s while Xcode indexes the package. Set
breakpoints in Xcode from there.

---

## 5. All `just` recipes

Run `just` with no args to print the list. Source of truth: `justfile`.

| Recipe | What it does |
|--------|--------------|
| `just` | List every recipe. |
| `just bootstrap` | Check tools, resolve deps, debug build. |
| `just check-tools` | Verify host tooling (swift, xcrun, curl, shasum). |
| `just deps` | Fetch SwiftPM + vendor deps. |
| `just build` | Incremental debug build. |
| `just build-release` | Optimized release build. |
| `just build-universal` | Universal binary (arm64 + x86_64). |
| `just run` | Kill prior instance, build, launch app detached. |
| `just debug` | Open package in Xcode and start a debug session. |
| `just mcp` | Launch the MCP server on stdio. |
| `just test` | Run the full test suite. |
| `just test-verbose` | Tests with verbose output. |
| `just bundle` | Stage a `.app` bundle into `dist/` from the universal binary. |
| `just sign "Developer ID Application: Name (TEAMID)"` | Codesign the staged bundle. |
| `just dmg` | Build a `.dmg` from the staged bundle. |
| `just notarize <profile>` | Notarize + staple the DMG (needs notary keychain profile). |
| `just fmt` | Format Swift sources (swift-format, ships with Xcode 16+). |
| `just lint` | Lint without modifying. |
| `just clean` | Remove build artifacts. |
| `just distclean` | Nuke everything fetched/built — back to fresh-clone state. |

---

## 6. Build products

`code/Package.swift` defines four products:

| Product | Type | Purpose |
|---------|------|---------|
| `ImageGlass` | executable | The SwiftUI viewer app. |
| `imageglass-mcp` | executable | Standalone MCP server (JSON-RPC over stdio). |
| `igcmd` | executable | CLI utility (scripting: wallpaper, default-viewer, themes). |
| `ImageGlassCore` | library | Shared SDK — all logic; both app and MCP link it. |

**Architecture rule:** logic lives in `ImageGlassCore`, UI lives in `ImageGlass`.
The MCP server and CLI reuse the same core, so behavior stays consistent across
GUI and automation.

---

## 7. Project layout

```
ImageGlass_Mac/
├── CLAUDE.md            # project charter + tech decisions
├── README.md           # short intro + build steps
├── justfile            # task runner (all commands)
├── docs/               # product specs (.mdx) — see §10
├── vendor/             # native libs (empty today)
└── code/               # the Swift package
    ├── Package.swift
    ├── Sources/
    │   ├── ImageGlassCore/     # all logic (links into everything)
    │   │   ├── FileList/       # scan, sort, tree build, thumbnail cache
    │   │   ├── Panels/         # modular panel model + MCP tools
    │   │   ├── Scope.swift     # scope engine
    │   │   ├── LocalStorage.swift
    │   │   ├── Paths.swift     # on-disk locations
    │   │   ├── MCPServer.swift / MCPTools.swift / MCPProtocol.swift
    │   │   ├── Viewer/  Formats/  SVG/  Video/  Crop/  Themes/  …
    │   │   └── …
    │   ├── ImageGlass/         # SwiftUI app (UI only)
    │   │   ├── FileList/       # 5 view modes + 3 tree renderers
    │   │   ├── Panels/         # panel host views
    │   │   ├── Window/  Viewer/  Settings/  …
    │   │   └── ImageGlassApp.swift / AppState.swift
    │   ├── ImageGlassMCPServer/   # thin main() over ImageGlassCore
    │   └── igcmd/                 # CLI main()
    └── Tests/ImageGlassCoreTests/ # ~40 test files
```

~190 Swift source files, ~40 test files. Good coverage on core logic.

---

## 8. The left-bar file panel (your meeting feature)

`FileListPanelView` (`code/Sources/ImageGlass/FileList/FileListPanelView.swift`)
is the left column. Five view modes, switched by number keys **1–5**:

1. Strip
2. Grid
3. Details
4. **Tree** — grouped by source directory
5. Column

Keyboard inside the panel: arrows move selection, Home/End jump, Return opens,
Esc clears, Cmd+A select-all. This is the "click through 400 images fast in a
meeting" surface.

### Three tree renderers

The tree (mode 4) is user-switchable across three rendering technologies
(`SelectableTreeRenderer.swift`, menu keys 1/2/3):

| Tech | Implementation | Notes |
|------|----------------|-------|
| **AppKit** | `NSOutlineView` in `NSScrollView` | Native, lazily renders children — **best for large trees**. |
| **SwiftUI** | `OutlineGroup` in `List` | Default today. Does not virtualize deep trees well. |
| Catalyst | SwiftUI styled to mimic UIKit | Stylistic alternative. |

Default is **SwiftUI** (`TreeRenderTechnology.loadOrDefault()`). For 400+ files,
switch to **AppKit** via the menu.

---

## 9. MCP + Local Storage

### On-disk locations (`Paths.swift`)

```
~/Library/Application Support/ImageGlass_Mac/
├── scopes/        # scope definitions (plain text — MCP edits these)
├── rule-sets/     # named inclusion/exclusion rule sets
├── themes/  languages/  runtime/  audit/  tools/
```

Each scope records: the source directories/criteria, the last evaluation time,
and the resolved file list. At runtime the app reads a scope, walks the matching
directories, resolves the file list, and shows it in the panel.

### Running the MCP server

```sh
just mcp                       # launches imageglass-mcp on stdio
```

MCP is the **only sanctioned automation contract**. Claude Code calls an MCP
tool → the call lands in the running app → Local Storage is read/modified → next
scope evaluation reflects the change in the panel. Full contract in
`docs/mcp.mdx`; data model in `docs/local_storage.mdx`.

---

## 10. Spec docs index (`docs/`)

| File | Covers |
|------|--------|
| `overview.mdx` | Umbrella charter for the fork. |
| `mcp.mdx` | MCP server product spec + tool contract. |
| `local_storage.mdx` | On-disk data model behind the panel. |
| `list_of_files.mdx` | File-list panel + the 3 tree renderers spec. |
| `panels.mdx` / `dir_ui.mdx` | Modular panel system + directory UI. |
| `features.mdx` | Viewer feature set. |
| `supported-formats.mdx` | Image formats supported. |
| `command-line.mdx` | `igcmd` CLI. |
| `settings.mdx` / `app-configs.mdx` | Settings + config files. |
| `themes.mdx` / `theme-pack.mdx` | Theming. |
| `crop.mdx` / `svg.mdx` / `videos.mdx` | Crop, SVG, embedded video. |
| `multi_monitor.mdx` | Multi-display behavior. |
| `error_handling.mdx` | Error/logging model. |
| `releases.mdx` | Release/update checking. |
| `automation.mdx` | Automation surface. |
| `build-tools.mdx` | Build + third-party tool SDK. |
| `menus.mdx` | Menu structure. |
| `use_cases/` | Scenario walkthroughs (e.g. `mcp_file.mdx`). |

---

## 11. Packaging & distribution

GPL v3 (inherited from upstream) — incompatible with Mac App Store terms. Direct
download as a notarized `.dmg` is the realistic path.

```sh
just build-universal      # arm64 + x86_64
just bundle               # stage .app into dist/
just sign "Developer ID Application: Your Name (TEAMID)"
just dmg                  # build dist/ImageGlass.dmg
just notarize <profile>   # notarytool submit + staple
```

Needs a Developer ID Application cert and a notary keychain profile.

---

## 12. Troubleshooting / known issues

**Tree not rendering / blanks on big sets** — the default **SwiftUI** tree
renderer doesn't virtualize deep trees. Switch the renderer to **AppKit**
(`NSOutlineView`) from the menu. For this project's scale, AppKit should arguably
be the default.

**Slow with hundreds of images** — two static perf hot spots:
1. `FileListTreeView.body` calls `model.buildTree()` on every render — rebuilds
   the whole tree each redraw. Cache it.
2. SwiftUI `List`/`LazyVStack` tree paths don't virtualize like
   `NSOutlineView`'s lazy `child(index:)`.

**Thumbnails / switching lag** — see `ThumbnailCache.swift` and
`FileListSelection.swift` in `ImageGlassCore/FileList/`.

**Path mismatch in CLAUDE.md** — `CLAUDE.md` references
`~/BGit/tools_various/ImageGlass_Mac/`, but this clone is at
`/Volumes/Erin/Whitehat/Projects/ImageGlass_Mac`. Update CLAUDE.md (or relocate)
so docs and paths agree.

---

## 13. Quick start for a new Mac dev

```sh
brew install just
just bootstrap        # build everything
just run              # launch app
just debug            # open in Xcode to set breakpoints
just test             # run the suite
```

Then: make **AppKit** the default tree renderer, cache `buildTree()`, and verify
a 400-image folder loads and keyboard-switches smoothly. That's the unblock.
