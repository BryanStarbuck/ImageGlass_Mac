import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state: AppState

    // Owns the AppDelegate that overrides `orderFrontStandardAboutPanel`
    // so the default Apple About panel is replaced by `AboutView`, and
    // routes Finder file-open / dock-reopen / Open Recent through to the
    // running `AppState`. See `AboutWindow.swift`.
    @NSApplicationDelegateAdaptor(AboutAppDelegate.self) private var aboutDelegate

    /// Outer `AppLaunch.Total` trace. Started in `init()` (the earliest
    /// measurable point of the process), finished from the main window's
    /// first `.onAppear` after `AppLaunch.FirstFrame` is emitted. See
    /// docs/performance.mdx §5.4.
    private static let launchTrace: PerformanceTrace = PerformanceLog.shared.start("AppLaunch.Total")
    private static var firstFrameFired: Bool = false

    // Intercept `--help` / `-h` / `/?` at process start so the user gets
    // a real CLI help message instead of a window opening; then parse the
    // remaining `/Name=Value` overrides and positional file args into the
    // initial AppState.
    init() {
        // Touch `launchTrace` so the static-let starts the trace on the
        // very first `App.init` (Swift lazy-initializes statics on first
        // access). See docs/performance.mdx §5.4 / §7.8.
        _ = Self.launchTrace

        let raw = Array(CommandLine.arguments.dropFirst())
        if CLIArguments.wantsHelp(raw) {
            print(CLIArguments.helpText())
            exit(0)
        }
        // First-launch seed: drop settings.yaml / panels.yaml into
        // ~/Library/Application Support/ImageGlass_Mac/ before AppState
        // wakes up, so a fresh machine has a complete starting state on
        // disk instead of relying on in-memory defaults.
        InitialConfigSeeder.seedIfMissing()
        let s = AppState()
        let parsed = ImageGlassLaunchArguments.parse(CommandLine.arguments)
        s.applyLaunchArguments(parsed)
        _state = State(wrappedValue: s)
    }

    /// Called once from the main `WindowGroup`'s root view `.onAppear`.
    /// Emits the `AppLaunch.FirstFrame` event and finishes the outer
    /// `AppLaunch.Total` trace. Idempotent — second-window opens (e.g.
    /// File ▸ New Window) do not re-fire the marker.
    static func reportFirstFrame() {
        guard !firstFrameFired else { return }
        firstFrameFired = true
        PerformanceLog.shared.event("AppLaunch.FirstFrame")
        launchTrace.finish()
    }

    var body: some Scene {
        // `id` lets `@Environment(\.openWindow)` request a second
        // instance from the File ▸ New Window menu item below. See
        // `docs/use_cases/actions.mdx` §7. SwiftUI's `WindowGroup`
        // natively supports multiple windows over the same scene; the
        // `id:` is the addressable handle for `openWindow(id:)`.
        WindowGroup("ImageGlass", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    // docs/performance.mdx §5.4 — first frame marker.
                    // Fires once, at the moment SwiftUI paints the
                    // primary viewer surface for the first time.
                    ImageGlassApp.reportFirstFrame()
                }
                .task {
                    registerBuiltinViewFactories(state: state)
                }
                // docs/right_click.mdx §7.1 item 2 — bridge the context
                // menu's *Open in New Window* notification into the
                // canonical `ImageGlassWindowActions.openNewImageWindow`
                // path that needs `@Environment(\.openWindow)`. The
                // pre-selected file path is staged separately in
                // `PendingNewWindowSelection.shared`.
                .modifier(NewWindowBridgeModifier(state: state))
        }
        .commands {
            // Replace the standard "About ImageGlass" item with our own
            // that opens the custom About window from `AboutWindowController`.
            CommandGroup(replacing: .appInfo) {
                Button("About \(AboutInfo.projectName)") {
                    AboutWindowController.show()
                }
            }
            CommandGroup(after: .sidebar) {
                Button(state.showPanelColumn ? "Hide Panel Column" : "Show Panel Column") {
                    state.showPanelColumn.toggle()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                // docs/list_of_files.mdx §3C — detached floating
                // window holding the file list + file tree on a
                // bright-yellow background. Default-on; the cold
                // launch opens it automatically via the AppDelegate.
                Button(FloatingFileTreeWindowController.shared.isVisible
                       ? "Hide Floating File Tree"
                       : "Show Floating File Tree") {
                    FloatingFileTreeWindowController.shared.toggle(state: state)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .control])
                // Second viewer: a passive floating image-only window
                // that mirrors `state.selectedFile`. Title flips to
                // "Second: <filename>" every time the main viewer
                // loads a new image.
                Button(SecondViewerWindowController.shared.isVisible
                       ? "Hide Second Viewer"
                       : "Show Second Viewer") {
                    SecondViewerWindowController.shared.toggle(state: state)
                }
                .keyboardShortcut("2", modifiers: [.command, .option, .control])
                // docs/list_of_files.mdx §3D — submenu lets the user
                // pick which of the three tree rendering technologies
                // draws the file tree (in both the inline panel and the
                // floating window). Checkmark marks the active one.
                Menu("Tree View") {
                    treeRenderTechItem(.appKit, key: "1")
                    treeRenderTechItem(.swiftUI, key: "2")
                    treeRenderTechItem(.catalyst, key: "3")
                }
                Button("Re-evaluate Active Scope") {
                    Task { await state.reevaluateActive() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                // docs/use_cases/actions.mdx §7 — New Window. Spawns a
                // second main `WindowGroup` instance via the SwiftUI
                // `openWindow` environment action. Multi-window support
                // is forward-compatible with the per-window state
                // record described in §7.5.
                NewWindowMenuItem(state: state)
                Divider()
                Button("Open…") { openFileDialog() }
                    .keyboardShortcut("o", modifiers: [.command])
                Menu("Open Recent") {
                    OpenRecentMenu(state: state)
                }
                Divider()
                // docs/use_cases/actions.mdx §2 — Rename Image. F2 is
                // the Windows-style rename key; NSF2FunctionKey = 0xF705
                // = 63237 in `NSEvent.SpecialKey` terms. Bound here so
                // upstream-ImageGlass muscle memory carries over.
                Button("Rename Image…") {
                    _ = FileActions.renameViaSheet(state: state, source: .menuFile)
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF705)!)),
                                  modifiers: [])
                .disabled(state.selectedFile == nil)
                // docs/use_cases/actions.mdx §3 — Move to Trash.
                Button("Move Image to Trash") {
                    _ = FileActions.moveToTrash(state: state, source: .keyCmdDelete)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(state.selectedFile == nil)
                Divider()
                // docs/use_cases/actions.mdx §5 — Copy File Path.
                // ⌃⌘C is the cross-context twin of the bare `P`
                // viewer key (handled in HotkeyHandlers).
                Button("Copy File Path") {
                    _ = FileActions.copyFilePath(state: state, source: .keyCtrlCmdC)
                }
                .keyboardShortcut("c", modifiers: [.control, .command])
                .disabled(state.selectedFile == nil)
                Divider()
                // docs/use_cases/actions.mdx §6 — Print.
                Button("Print…") {
                    _ = FileActions.printImage(state: state, source: .keyCmdP)
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(state.selectedFile == nil)
            }
            CommandGroup(after: .pasteboard) {
                // docs/use_cases/actions.mdx §4 — Copy Image. The crop
                // tool already binds ⌘C to "Copy crop"; here we route
                // ⌥⌘C as the dedicated viewer-image copy so the two
                // verbs do not collide while the crop sheet is open.
                Button("Copy Image") {
                    _ = FileActions.copyImageToClipboard(state: state, source: .keyCmdC)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(state.selectedFile == nil)
                Button("Paste Image / Path") { pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Releases & News…") {
                    ReleasesWindowController.shared.show()
                }
            }
            viewerMenuCommands
            layoutMenuCommands
            cropMenuCommands
            directoriesMenuCommands
            windowMenuCommands
            // `videoMenuCommands` / `svgMenuCommands` placeholders are
            // wired in by a parallel WIP; once they land they slot back here.
        }

        Settings {
            SettingsScene(state: state)
        }
    }

    // MARK: - Tree View submenu helper

    /// docs/list_of_files.mdx §3D.2 — one item per renderer. A leading
    /// checkmark glyph (`✓ ` / `  `) marks the active choice; the
    /// hotkey is `⌃⌥⌘<key>`. Selecting an unchecked item swaps the
    /// renderer; selecting the active one is a no-op.
    @ViewBuilder
    private func treeRenderTechItem(_ tech: TreeRenderTechnology,
                                    key: Character) -> some View {
        let active = state.treeRenderTechnology == tech
        Button("\(active ? "✓ " : "   ")\(tech.menuTitle)") {
            if state.treeRenderTechnology != tech {
                state.treeRenderTechnology = tech
            }
        }
        .keyboardShortcut(KeyEquivalent(key),
                          modifiers: [.command, .option, .control])
    }

    // MARK: - Crop menu

    @CommandsBuilder
    private var cropMenuCommands: some Commands {
        CommandMenu("Crop") {
            Button(state.crop.isActive ? "Close Crop Tool" : "Open Crop Tool") {
                if state.crop.isActive {
                    state.crop.cancel()
                } else {
                    state.crop.bind(activeImage: nil, path: state.selectedFile)
                    state.crop.open()
                }
            }
            .keyboardShortcut("k", modifiers: [.command])
            Divider()
            Button("Apply Crop (Replace)") {
                _ = try? state.crop.applyAndReplace()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!state.crop.isActive || state.crop.rect == nil)
            Button("Save") {
                _ = try? state.crop.applySaveInPlace()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!state.crop.isActive || state.crop.rect == nil)
            Button("Save As…") {
                _ = try? state.crop.applySaveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!state.crop.isActive || state.crop.rect == nil)
            Button("Copy") {
                try? state.crop.copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(!state.crop.isActive || state.crop.rect == nil)
            Divider()
            Button("Reset Selection") { state.crop.resetSelection() }
                .disabled(!state.crop.isActive)
            Button("Cycle Grid Overlay") { state.crop.cycleGrid() }
                .disabled(!state.crop.isActive)
        }
    }

    // MARK: - Directories menu (mcp_file.mdx §3A.8)

    /// The Directories menu lives between Crop and Window in the menu
    /// bar. All hotkeys use ⌥⌘ so they don't collide with system or
    /// viewer-canvas shortcuts (which use ⌘ alone). See
    /// `docs/list_of_files.mdx` §3A.8.
    @CommandsBuilder
    private var directoriesMenuCommands: some Commands {
        CommandMenu("Directories") {
            Button("Add Directory…") {
                addDirectoryFromPicker()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Add Directory from Path…") {
                addDirectoryFromPathPrompt()
            }
            .keyboardShortcut("d", modifiers: [.command, .option, .control])

            Divider()

            // Live list of every registered root in directories.yaml. Each
            // root is a submenu with its full path, Reveal, and Remove.
            Menu("Registered Directories (\(state.walkerRoots.count))") {
                if state.walkerRoots.isEmpty {
                    Button("None — use Add Directory…") {}.disabled(true)
                } else {
                    ForEach(state.walkerRoots, id: \.path) { root in
                        Menu(root.path.lastPathComponent) {
                            Button(root.path.path) {}.disabled(true)
                            Divider()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([root.path])
                            }
                            Button("Remove") {
                                removeDirectory(root.path)
                            }
                        }
                    }
                    Divider()
                    Button("Remove All Directories") {
                        clearAllDirectories()
                    }
                }
            }

            Divider()
            Button("Refresh All") {
                refreshAllDirectories()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Reveal in Finder") {
                revealActiveSelectionInFinder()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(state.selectedFile == nil)

            Divider()
            // include_checks.mdx §7 — three explicit include states
            // bound to ⌃1 / ⌃2 / ⌃3. Each item sets the state on the
            // currently focused row (panel cursor or viewer
            // selection). Disabled when no row is focused.
            Button("Include") {
                applyIncludeState(.include)
            }
            .keyboardShortcut("1", modifiers: [.control])
            .disabled(focusedIncludeRow == nil)
            Button("Inherit") {
                applyIncludeState(.inherit)
            }
            .keyboardShortcut("2", modifiers: [.control])
            // include_checks.mdx §1.0 / §7 — `Inherit` is disabled
            // when the focused row is a root (roots are two-state).
            .disabled(focusedIncludeRow == nil || focusedRowIsRoot)
            Button("Don't Include") {
                applyIncludeState(.exclude)
            }
            .keyboardShortcut("3", modifiers: [.control])
            .disabled(focusedIncludeRow == nil)
        }
    }

    /// include_checks.mdx §4.1 — the row a state change should apply
    /// to. Prefers the panel's tree-nav cursor (so the user can park
    /// on a folder and toggle without picking a file), falls back to
    /// the viewer's selected file.
    private var focusedIncludeRow: String? {
        state.treeNav.activeRow ?? state.selectedFile
    }

    /// include_checks.mdx §1.0 — true when the focused row is one of
    /// the registered roots. Disables ⌃2 Inherit, which is the one
    /// state the root cycle excludes.
    private var focusedRowIsRoot: Bool {
        guard let path = focusedIncludeRow else { return false }
        return IncludeStateController.isRoot(absolutePath: path, in: state.walkerRoots)
    }

    /// Apply one of the three menu items' explicit states to the
    /// focused row. Same code path as the swatch click and the `I`
    /// hotkey — all three surfaces route through
    /// `IncludeStateController.setState(...)`.
    private func applyIncludeState(_ s: IncludeState) {
        guard let path = focusedIncludeRow else { return }
        _ = IncludeStateController.setState(
            absolutePath: path,
            state: s,
            appState: state
        )
    }

    /// Remove one registered root from `directories.yaml` and the live
    /// walker. The walker's change notification refreshes `walkerRoots`.
    private func removeDirectory(_ url: URL) {
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            if try DirectoriesStore.shared.removeRoot(path: url.path) {
                DirectoryTreeWalker.shared.removeRoot(path: url)
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "remove_directory", path: url.path,
                    client: "gui", corr: corr, ok: true
                )
            }
        } catch {
            ErrorLog.log("Directories.removeDirectory failed",
                         error: error, class: "ImageGlassApp")
        }
    }

    /// Remove every registered root (equivalent to MCP `clear_directories`).
    private func clearAllDirectories() {
        let roots = state.walkerRoots.map(\.path)
        do {
            try DirectoriesStore.shared.clearAll()
            for url in roots { DirectoryTreeWalker.shared.removeRoot(path: url) }
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "clear_directories", path: nil,
                client: "gui", corr: MCPAuditLogger.newCorrelationId(), ok: true
            )
        } catch {
            ErrorLog.log("Directories.clearAllDirectories failed",
                         error: error, class: "ImageGlassApp")
        }
    }

    /// Opens `NSOpenPanel`, restricted to folders, lets the user pick
    /// one or more directories. Each selection becomes a new root in
    /// `directories.yaml` and triggers a walk. Matches the GUI path
    /// described in mcp_file.mdx §2.1 and §3A.8.
    private func addDirectoryFromPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let (canonical, already) = try DirectoriesStore.shared.addRoot(path: url.path)
                if !already {
                    let corr = MCPAuditLogger.newCorrelationId()
                    MCPAuditLogger.shared.logDirectoryToolCall(
                        toolName: "add_directory",
                        path: canonical.path,
                        client: "gui",
                        corr: corr,
                        ok: true
                    )
                    // Pass the canonical URL — the same key the YAML stores
                    // — so `reloadDirectoriesFromDisk` does not later see the
                    // walker's raw-URL entry as "missing from the YAML" and
                    // remove it. See docs/use_cases/add_dir_of_images.md §6.6.
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: canonical,
                        filter: .empty,
                        corr: corr
                    )
                }
            } catch {
                ErrorLog.log("Directories.addDirectoryFromPicker failed",
                             error: error, class: "ImageGlassApp")
            }
        }
    }

    /// Prompts the user for an absolute path (sheet via `NSAlert`) and
    /// adds it as a root — equivalent to `add_directory` via MCP. The
    /// alert is modeless-equivalent (modal here is fine; this is a rare
    /// power-user action).
    private func addDirectoryFromPathPrompt() {
        let alert = NSAlert()
        alert.messageText = "Add directory from path"
        alert.informativeText = "Enter an absolute path. Tilde is expanded."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "~/Pictures/tour"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let (canonical, already) = try DirectoriesStore.shared.addRoot(path: raw)
            if !already {
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "add_directory",
                    path: canonical.path,
                    client: "gui",
                    corr: corr,
                    ok: true
                )
                DirectoryTreeWalker.shared.scheduleWalk(
                    root: canonical,
                    filter: .empty,
                    corr: corr
                )
            }
        } catch {
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "add_directory",
                path: raw,
                client: "gui",
                corr: corr,
                ok: false,
                err: "path_not_found"
            )
        }
    }

    /// Force-walk every registered root. Equivalent to
    /// `refresh_directory()` via MCP with `path` omitted.
    private func refreshAllDirectories() {
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        let corr = MCPAuditLogger.newCorrelationId()
        MCPAuditLogger.shared.logDirectoryToolCall(
            toolName: "refresh_directory",
            path: nil,
            client: "gui",
            corr: corr,
            ok: true,
            extra: [("roots", String(file.roots.count))]
        )
        for r in file.roots {
            DirectoryTreeWalker.shared.scheduleWalk(
                root: r.path,
                filter: r.filter,
                corr: corr
            )
        }
    }

    /// Reveals the currently selected file (or its parent root, if
    /// nothing is selected) in Finder via `NSWorkspace`.
    private func revealActiveSelectionInFinder() {
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Viewer (View) menu

    @CommandsBuilder
    private var viewerMenuCommands: some Commands {
        CommandMenu("Viewer") {
            Menu("Zoom Mode") {
                ForEach(ZoomMode.allCases, id: \.self) { mode in
                    Button(mode.label) { state.viewer.zoomMode = mode }
                }
            }
            Divider()
            Button("Zoom In") {
                state.viewer.zoomIn(stepPercent: state.settings.viewer.zoom_step_percent)
            }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Zoom Out") {
                state.viewer.zoomOut(stepPercent: state.settings.viewer.zoom_step_percent)
            }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Actual Size") { state.viewer.zoomToActual() }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Zoom to Fit") { state.viewer.zoomToFit() }
                .keyboardShortcut("9", modifiers: [.command])
            // hotkeys.mdx §6.4 — fit width to viewport, scroll to top.
            // Bare `W` is the in-viewer twin; this chord is the menu
            // surface so the action also works when a text field has
            // focus.
            Button("Zoom to Width") { state.viewer.zoomToWidth() }
                .keyboardShortcut("9", modifiers: [.command, .option])
            // hotkeys.mdx §7 — menu twins for the bare `C` and `N`.
            // No menu chord; the bare-letter binding lives on the viewer.
            Button("Center") { state.viewer.centerImage() }
            Button("Normalize Zoom") {
                let lastRaw = UserDefaults.standard.string(forKey: ViewerState.lastZoomModeKey)
                state.viewer.normalizeZoom(
                    mode: state.settings.viewer.default_zoom_on_open,
                    lastMode: lastRaw.flatMap(ZoomMode.init(rawValue:))
                )
            }
            Divider()
            Button("Rotate 90° CW")  { state.viewer.rotateClockwise() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Rotate 90° CCW") { state.viewer.rotateCounterClockwise() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Flip Horizontal") { state.viewer.toggleFlipHorizontal() }
            Button("Flip Vertical")   { state.viewer.toggleFlipVertical() }
            Divider()
            Toggle("Smooth Interpolation", isOn: $state.viewer.smoothInterpolation)
            Menu("Color Channel") {
                ForEach(ColorChannel.allCases, id: \.self) { ch in
                    Button(ch.label) { state.viewer.colorChannel = ch }
                }
            }
            Toggle("Image Info Overlay", isOn: $state.viewer.showInfoOverlay)
                .keyboardShortcut("i", modifiers: [.command])
            Toggle("Color Picker", isOn: $state.viewer.showColorPicker)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Menu("Color Picker Format") {
                ForEach(ColorFormat.allCases, id: \.self) { f in
                    Button(f.label) { state.viewer.colorFormat = f }
                }
            }
            Divider()
            Menu("Frame") {
                Button("Previous Frame") { state.viewer.previousFrame() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Frame") { state.viewer.nextFrame() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Toggle("Pause Animation", isOn: $state.viewer.isAnimationPaused)
                    .keyboardShortcut("p", modifiers: [.command])
                Divider()
                Button("Save Current Frame…") { saveCurrentFrame() }
                Button("Export All Frames…") { exportAllFrames() }
            }
            Divider()
            Button("Toggle Full Screen") {
                WindowModes.toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Toggle("Frameless Window", isOn: Binding(
                get: { state.viewer.isFrameless },
                set: { v in
                    state.viewer.isFrameless = v
                    WindowModes.toggleFrameless(v)
                }
            ))
            Button("Fit Window to Image") {
                WindowModes.fitWindowToImage(path: state.selectedFile)
            }
            Divider()
            // Slideshow toggle. slideshow.mdx §1 / §3 / §10.1 — `⌥⌘S` is
            // the unconditional, focus-context-free menu shortcut. The
            // bare `S` key (handled in ImageViewer) is the focus-aware
            // viewer hotkey. Both call `SlideshowController.toggle`,
            // which reads the interval live from
            // `settings.slideshow.interval_seconds`.
            Button(SlideshowController.shared.isRunning
                   ? "Stop Slideshow"
                   : "Start Slideshow") {
                SlideshowController.shared.toggle(appState: state, source: "menu:View")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandMenu("Navigate") {
            Button("Previous Image") { state.selectPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Image") { state.selectNext() }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            for url in panel.urls {
                state.openExternalFile(url: url)
            }
        }
    }

    /// Cmd-Shift-V — accept image content pasted from the clipboard.
    /// First tries file URLs (common case), then falls back to raw image
    /// data which is materialised under the app's cache directory so the
    /// rest of the viewer can treat it like any other on-disk file.
    @MainActor
    private func pasteFromClipboard() {
        let result = ClipboardLoader.loadFromClipboard()
        if !result.fileURLs.isEmpty {
            for url in result.fileURLs { state.openExternalFile(url: url) }
            return
        }
        guard let loaded = result.image else { return }
        let rep = NSBitmapImageRep(cgImage: loaded.cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            ErrorLog.log("NSBitmapImageRep.representation(using:.png) returned nil for clipboard image",
                         class: "ImageGlassApp")
            return
        }
        let dir = AppPaths.appSupportDir.appendingPathComponent("clipboard", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            ErrorLog.log("createDirectory failed for \(dir.path)",
                         error: error,
                         class: "ImageGlassApp")
        }
        let url = dir.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url)
            state.openExternalFile(url: url)
        } catch {
            ErrorLog.log("paste image write failed for \(url.path)",
                         error: error,
                         class: "ImageGlassApp")
            NSLog("Paste image write failed: \(error)")
        }
    }

    // MARK: - Window menu (multi_window.mdx §5)

    /// Items added to the standard macOS Window menu via
    /// `CommandGroup(after: .windowList)`. The native `Minimize`,
    /// `Zoom`, `Bring All to Front`, and the auto-appended list of
    /// open windows stay in place; we layer the multi-window
    /// lifecycle controls on top.
    @CommandsBuilder
    private var windowMenuCommands: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            WindowMenuCloseItem()
            WindowMenuCycleNextItem()
            WindowMenuCyclePreviousItem()
            Divider()
            WindowMenuReopenSubmenu()
            WindowMenuForgetSubmenu()
            Divider()
            WindowMenuRenameItem()
        }
    }

    @CommandsBuilder
    private var layoutMenuCommands: some Commands {
        CommandMenu("Layout") {
            ForEach(Array(BuiltInPreset.allCases.enumerated()), id: \.element.rawValue) { idx, preset in
                Button(preset.rawValue) {
                    state.panelLayout.applyPreset(preset.rawValue)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command, .option])
            }
        }
    }

    private func saveCurrentFrame() {
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let fs = FrameSource.load(url: url), !fs.frames.isEmpty else {
            ErrorLog.log("FrameSource.load returned nil/empty for \(url.path)",
                         class: "ImageGlassApp")
            return
        }
        let idx = max(0, min(state.viewer.currentFrameIndex, fs.frameCount - 1))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent)-frame-\(idx + 1).png"
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try FrameExporter.saveFrame(fs.frames[idx].cgImage, to: dest)
            } catch {
                ErrorLog.log("FrameExporter.saveFrame failed for \(dest.path)",
                             error: error,
                             class: "ImageGlassApp")
                NSLog("save frame failed: \(error)")
            }
        }
    }

    private func exportAllFrames() {
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let fs = FrameSource.load(url: url), fs.frames.count > 1 else {
            ErrorLog.log("FrameSource.load returned nil or <=1 frame for \(url.path)",
                         class: "ImageGlassApp")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let dir = panel.url {
            do {
                try FrameExporter.exportAll(
                    fs,
                    to: dir,
                    baseName: url.deletingPathExtension().lastPathComponent
                )
            } catch {
                ErrorLog.log("FrameExporter.exportAll failed for \(dir.path)",
                             error: error,
                             class: "ImageGlassApp")
                NSLog("export frames failed: \(error)")
            }
        }
    }

    // MARK: - Video menu (docs/videos.mdx §5)

    @CommandsBuilder
    private var videoMenuCommands: some Commands {
        CommandMenu("Video") {
            Button(state.video.isPlaying ? "Pause" : "Play") {
                state.video.playPauseToggle()
            }
            // ␣ — spacebar binding is owned by the focus-context handler
            // in `ImageViewer.handleSpace()`, so we don't double-bind it
            // here.
            .disabled(!isVideoSelected)

            Button("Stop and Rewind") { state.video.stopAndRewind() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!isVideoSelected)

            Divider()

            Button(state.video.isMuted ? "Sound On" : "Sound Off (Mute)") {
                state.video.toggleMuted()
            }
            // M-with-no-modifier is handled by VideoCanvasView's
            // onKeyPress.
            .disabled(!isVideoSelected)

            Divider()

            Button(state.video.loopOn ? "Loop ✓" : "Loop") {
                state.video.toggleLoop()
            }
            .disabled(!isVideoSelected)

            Menu("Playback Speed") {
                speedItem(label: "0.25×", rate: 0.25, key: "1")
                speedItem(label: "0.5×",  rate: 0.5,  key: "2")
                speedItem(label: "1.0×",  rate: 1.0,  key: "3")
                speedItem(label: "1.5×",  rate: 1.5,  key: "4")
                speedItem(label: "2.0×",  rate: 2.0,  key: "5")
            }

            Divider()

            Button("Step Forward One Frame") { state.video.step(byFrames: 1) }
                .disabled(!isVideoSelected)
            Button("Step Backward One Frame") { state.video.step(byFrames: -1) }
                .disabled(!isVideoSelected)
            Button("Skip Forward 5 s")  { state.video.skip(by: 5)  }
                .disabled(!isVideoSelected)
            Button("Skip Backward 5 s") { state.video.skip(by: -5) }
                .disabled(!isVideoSelected)
            Button("Skip Forward 30 s") { state.video.skip(by: 30)  }
                .disabled(!isVideoSelected)
            Button("Skip Backward 30 s"){ state.video.skip(by: -30) }
                .disabled(!isVideoSelected)
            Button("Go to Time…") { goToTime() }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(!isVideoSelected)

            Divider()

            Button("Snapshot Current Frame…") { saveVideoSnapshot() }
                .disabled(!isVideoSelected)

            Divider()

            Button("Enter Full-Screen Video") {
                WindowModes.toggleFullScreen()
            }
            .disabled(!isVideoSelected)

            Button(state.video.isPiPActive
                   ? "Exit Picture in Picture"
                   : "Picture in Picture") {
                // PiP is owned by AVPlayerView's chrome — we surface the
                // menu entry as a hint; the toggle button on the floating
                // transport bar performs the actual swap.
            }
            .disabled(!isVideoSelected)
        }
    }

    private var isVideoSelected: Bool {
        guard let p = state.selectedFile else { return false }
        return MediaKind.detect(path: p) == .video
    }

    @ViewBuilder
    private func speedItem(label: String, rate: Float, key: KeyEquivalent) -> some View {
        Button(speedItemLabel(label: label, rate: rate)) {
            state.video.setRate(rate)
        }
        .keyboardShortcut(key, modifiers: [.option])
    }

    private func speedItemLabel(label: String, rate: Float) -> String {
        let active = abs(Double(state.video.rate) - Double(rate)) < 0.01
        return active ? "\(label) ✓" : label
    }

    private func goToTime() {
        let alert = NSAlert()
        alert.messageText = "Go to Time"
        alert.informativeText = "Enter a time in seconds (or HH:MM:SS):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "0:00:00"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            state.video.seek(to: parseTime(field.stringValue))
        }
    }

    private func parseTime(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    private func saveVideoSnapshot() {
        Task { @MainActor in
            do {
                let img = try await state.video.snapshotCurrentFrame()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png, .jpeg, .tiff]
                let base = (state.selectedFile ?? "frame") as NSString
                let stamp = Int(state.video.currentTime * 1000)
                panel.nameFieldStringValue =
                    "\(base.lastPathComponent)-frame-\(stamp).png"
                if panel.runModal() == .OK, let dest = panel.url {
                    let rep = NSBitmapImageRep(cgImage: img)
                    let data = rep.representation(using: .png, properties: [:])
                    try? data?.write(to: dest)
                }
            } catch {
                ErrorLog.log("video snapshot via menu failed",
                             error: error, class: "ImageGlassApp")
            }
        }
    }

    // MARK: - SVG menu (docs/svg.mdx §5)

    @CommandsBuilder
    private var svgMenuCommands: some Commands {
        CommandMenu("SVG") {
            Button(state.svg.isPlaying ? "Pause Animation" : "Play Animation") {
                state.svg.playPauseToggle()
            }
            .disabled(!isSVGAnimated)

            Button("Stop and Rewind") { state.svg.stopAndRewind() }
                .disabled(!isSVGAnimated)

            Divider()

            Button(state.svg.loopOn ? "Loop ✓" : "Loop") {
                state.svg.toggleLoop()
            }
            .disabled(!isSVGSelected)

            Menu("Playback Speed") {
                svgSpeedItem(label: "0.25×", rate: 0.25, key: "1")
                svgSpeedItem(label: "0.5×",  rate: 0.5,  key: "2")
                svgSpeedItem(label: "1.0×",  rate: 1.0,  key: "3")
                svgSpeedItem(label: "1.5×",  rate: 1.5,  key: "4")
                svgSpeedItem(label: "2.0×",  rate: 2.0,  key: "5")
            }

            Divider()

            Button("Zoom to ViewBox") { state.svg.zoomToViewBox() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!isSVGSelected)
            Button("Reset Pan and Zoom") { state.svg.resetZoom() }
                .disabled(!isSVGSelected)

            Divider()

            Button("Snapshot Current Frame…") { saveSVGSnapshot() }
                .disabled(!isSVGSelected)
            Button("Export Raster…") { exportSVGRaster() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isSVGSelected)

            Divider()

            Button(state.svg.showViewBoxOutline
                   ? "Hide ViewBox Outline"
                   : "Show ViewBox Outline") {
                state.svg.toggleViewBoxOutline()
            }
            .keyboardShortcut("v", modifiers: [.option])
            .disabled(!isSVGSelected)

            Menu("Show Background") {
                Button("Transparent") { state.svg.setBackground(.transparent) }
                Button("White")       { state.svg.setBackground(.white) }
                Button("Black")       { state.svg.setBackground(.black) }
                Button("Checkerboard"){ state.svg.setBackground(.checker) }
            }

            Divider()

            Button(state.svg.allowScripts
                   ? "Disallow Scripts in SVG (This File)"
                   : "Allow Scripts in SVG (This File)") {
                toggleAllowScripts()
            }
            .disabled(!isSVGSelected)
        }
    }

    private var isSVGSelected: Bool {
        guard let p = state.selectedFile else { return false }
        return MediaKind.detect(path: p) == .svg
    }

    private var isSVGAnimated: Bool {
        isSVGSelected && state.svg.kind == .animated
    }

    @ViewBuilder
    private func svgSpeedItem(label: String, rate: Double, key: KeyEquivalent) -> some View {
        Button(abs(state.svg.rate - rate) < 0.01 ? "\(label) ✓" : label) {
            state.svg.setRate(rate)
        }
        .keyboardShortcut(key, modifiers: [.option])
    }

    private func saveSVGSnapshot() {
        state.svg.snapshotCurrentFrame { cg in
            guard let cg else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            let base = (state.selectedFile ?? "svg") as NSString
            panel.nameFieldStringValue = "\(base.lastPathComponent).png"
            if panel.runModal() == .OK, let dest = panel.url {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dest)
                }
            }
        }
    }

    private func exportSVGRaster() {
        let alert = NSAlert()
        alert.messageText = "Export Raster"
        alert.informativeText = "Width in pixels:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "1024"
        alert.accessoryView = field
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let width = Int(field.stringValue) ?? 1024
        state.svg.snapshotCurrentFrame(width: width) { cg in
            guard let cg else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff]
            let base = (state.selectedFile ?? "svg") as NSString
            panel.nameFieldStringValue = "\(base.lastPathComponent)-\(width)w.png"
            if panel.runModal() == .OK, let dest = panel.url {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dest)
                }
            }
        }
    }

    /// Toggles per-file script execution for the active SVG. First-time
    /// enable surfaces a confirmation alert explaining the security
    /// trade-off (docs/svg.mdx §3.8).
    private func toggleAllowScripts() {
        if state.svg.allowScripts {
            state.svg.setAllowScripts(false, confirmed: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow scripts in this SVG?"
        alert.informativeText = """
            Scripts in SVG files can execute arbitrary JavaScript. \
            ImageGlass_Mac blocks them by default. Only allow scripts for \
            SVGs you trust.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        state.svg.setAllowScripts(true, confirmed: confirmed)
    }
}

/// docs/right_click.mdx §7.1 item 2 — observer that listens for the
/// `imageGlassOpenNewWindow` notification posted by the right-click
/// *Open in New Window* verb and dispatches through the canonical
/// `ImageGlassWindowActions.openNewImageWindow` path. This is a
/// `ViewModifier` so it can capture the `@Environment(\.openWindow)`
/// value the underlying action requires. Mounted once on the
/// `WindowGroup` root view.
private struct NewWindowBridgeModifier: ViewModifier {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default
            .publisher(for: .imageGlassOpenNewWindow)) { _ in
                ImageGlassWindowActions.openNewImageWindow(
                    openWindow: openWindow,
                    source: "menu:context"
                )
            }
    }
}

/// `docs/use_cases/actions.mdx` §7 — File ▸ New Window. Lives in its own
/// `View` so it can hold the `@Environment(\.openWindow)` value, which
/// is not directly accessible inside an `App`'s `.commands` body. The
/// shortcut is `⌘N`. The audit line is emitted by the action closure
/// so a debugger can correlate the keystroke with the opened window.
///
/// multi_window.mdx §5.1 — also allocates a fresh `window_id` from the
/// registry and writes the matching `settings_window_<N>.yaml` and
/// `directories_window_<N>.yaml` immediately so a crash before the
/// first user mutation does not lose the window.
private struct NewWindowMenuItem: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Image Window") {
            ImageGlassWindowActions.openNewImageWindow(
                openWindow: openWindow,
                source: FileActions.Source.keyCmdN.rawValue
            )
        }
        .keyboardShortcut("n", modifiers: [.command])
    }
}

/// multi_window.mdx §5 — actions that need both the SwiftUI
/// `openWindow` environment value AND the cross-cutting
/// `WindowRegistry` mutation. Kept as a single namespace so the Window
/// menu commands and the MCP `open_window` tool can share one
/// implementation.
enum ImageGlassWindowActions {
    /// multi_window.mdx §5.1 — New Image Window (⌘N). Allocates the
    /// next `window_id`, writes empty per-window YAML, posts the
    /// audit line, then asks SwiftUI to materialize a new `main`
    /// `WindowGroup` instance. The frontmost observer binds the new
    /// NSWindow to the freshly-registered `WindowState` on its first
    /// `becomeKey`.
    @MainActor
    static func openNewImageWindow(
        openWindow: OpenWindowAction,
        source: String
    ) {
        let corr = MCPAuditLogger.newCorrelationId()
        let id = WindowRegistry.shared.allocateNextWindowID()
        do {
            try registerNewWindowState(id: id)
        } catch {
            ErrorLog.log(
                "ImageGlassWindowActions.openNewImageWindow: registerNewWindowState failed for window_id=\(id)",
                error: error,
                class: "ImageGlassWindowActions"
            )
        }
        openWindow(id: "main")
        MCPAuditLogger.shared.log([
            ("app", "window.open"),
            ("window_id", String(id)),
            ("source", source),
            ("corr", corr),
        ])
    }

    @MainActor
    static func reopenClosedWindow(
        windowID: Int,
        openWindow: OpenWindowAction,
        source: String
    ) {
        guard let state = WindowRegistry.shared.window(id: windowID) else { return }
        // Flip the persisted flag so the next launch also resurrects
        // the window (§5.2 step 4).
        do {
            try state.persistWasOpenOnQuit(true)
        } catch {
            ErrorLog.log(
                "ImageGlassWindowActions.reopenClosedWindow: persistWasOpenOnQuit failed for window_id=\(windowID)",
                error: error,
                class: "ImageGlassWindowActions"
            )
        }
        openWindow(id: "main")
        let corr = MCPAuditLogger.newCorrelationId()
        MCPAuditLogger.shared.log([
            ("app", "window.open"),
            ("window_id", String(windowID)),
            ("source", source),
            ("corr", corr),
        ])
    }

    @MainActor
    static func forgetClosedWindow(windowID: Int) {
        do {
            try WindowRegistry.shared.retire(windowID: windowID)
            MCPAuditLogger.shared.log([
                ("app", "window.retire"),
                ("window_id", String(windowID)),
            ])
        } catch {
            ErrorLog.log(
                "ImageGlassWindowActions.forgetClosedWindow: retire failed for window_id=\(windowID)",
                error: error,
                class: "ImageGlassWindowActions"
            )
        }
    }

    @MainActor
    static func closeFrontmostWindow() {
        guard let id = WindowRegistry.shared.frontmostWindowID,
              let state = WindowRegistry.shared.window(id: id) else { return }
        // Per §1.3 step 5 / §5.2 step 4: explicit close persists
        // `wasOpenOnQuit = false` so next launch does not resurrect
        // this window.
        try? state.persistWasOpenOnQuit(false)
        WindowRegistry.shared.close(windowID: id)
        MCPAuditLogger.shared.log([
            ("app", "window.close"),
            ("window_id", String(id)),
            ("reason", "user"),
        ])
    }

    /// multi_window.mdx §5.4 — cycle to the next/previous open
    /// window by `window_id`, wrap at ends.
    @MainActor
    static func cycleWindow(forward: Bool) {
        let open = WindowRegistry.shared.openWindows
        guard open.count >= 2 else { return }
        let currentID = WindowRegistry.shared.frontmostWindowID
        let ordered = open.map(\.windowID)
        let currentIdx = currentID.flatMap { ordered.firstIndex(of: $0) } ?? 0
        let nextIdx: Int
        if forward {
            nextIdx = (currentIdx + 1) % ordered.count
        } else {
            nextIdx = (currentIdx - 1 + ordered.count) % ordered.count
        }
        let target = ordered[nextIdx]
        if let win = WindowRegistry.shared.window(id: target)?.window {
            win.makeKeyAndOrderFront(nil)
            MCPAuditLogger.shared.log([
                ("app", "window.activate"),
                ("window_id", String(target)),
            ])
        }
    }

    @MainActor
    static func renameFrontmostWindow(to newName: String?) {
        guard let id = WindowRegistry.shared.frontmostWindowID,
              let state = WindowRegistry.shared.window(id: id) else { return }
        do {
            try state.rename(newName)
            MCPAuditLogger.shared.log([
                ("app", "window.rename"),
                ("window_id", String(id)),
                ("name", newName ?? ""),
            ])
        } catch {
            ErrorLog.log(
                "ImageGlassWindowActions.renameFrontmostWindow failed for window_id=\(id)",
                error: error,
                class: "ImageGlassWindowActions"
            )
        }
    }

    /// multi_window.mdx §5.1 — write empty per-window YAML for a
    /// freshly-allocated `window_id` and register the matching
    /// `WindowState` so the registry knows about it before the
    /// AppKit window's first `becomeKey` arrives.
    @MainActor
    private static func registerNewWindowState(id: Int) throws {
        let settingsStore = WindowScopedSettingsStore(windowID: id)
        let settings = WindowScopedSettings(windowID: id)
        try settingsStore.save(settings)

        let directoriesStore = DirectoriesStore(windowID: id)
        try directoriesStore.ensureExists()

        let state = WindowState(
            windowID: id,
            settings: settings,
            settingsStore: settingsStore,
            directoriesStore: directoriesStore
        )
        WindowRegistry.shared.register(state)
    }
}

/// multi_window.mdx §5.1 ⌘W — Close the frontmost image window.
/// Persists `was_open_on_quit = false` so the window does not
/// resurrect on next launch. The on-disk YAML stays in place so the
/// user can reopen via `Reopen Closed Window ▸`.
private struct WindowMenuCloseItem: View {
    var body: some View {
        Button("Close Window") {
            ImageGlassWindowActions.closeFrontmostWindow()
        }
        .keyboardShortcut("w", modifiers: [.command])
    }
}

/// multi_window.mdx §5.4 — ⌘\` cycle to the next open image window.
private struct WindowMenuCycleNextItem: View {
    var body: some View {
        Button("Cycle to Next Window") {
            ImageGlassWindowActions.cycleWindow(forward: true)
        }
        .keyboardShortcut("`", modifiers: [.command])
    }
}

private struct WindowMenuCyclePreviousItem: View {
    var body: some View {
        Button("Cycle to Previous Window") {
            ImageGlassWindowActions.cycleWindow(forward: false)
        }
        .keyboardShortcut("`", modifiers: [.command, .shift])
    }
}

/// multi_window.mdx §5.2 — Reopen Closed Window ▸ submenu. Lists every
/// non-retired window whose `NSWindow` is currently nil. Selecting an
/// item resurrects the window with its persisted geometry / cursor /
/// panel layout.
private struct WindowMenuReopenSubmenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Reopen Closed Window") {
            let closed = WindowRegistry.shared.closedWindows
            if closed.isEmpty {
                Button("No Closed Windows") {}.disabled(true)
            } else {
                ForEach(closed, id: \.windowID) { state in
                    Button(state.displayTitle) {
                        ImageGlassWindowActions.reopenClosedWindow(
                            windowID: state.windowID,
                            openWindow: openWindow,
                            source: "menu:window_reopen"
                        )
                    }
                }
            }
        }
    }
}

/// multi_window.mdx §5.3 — Forget Closed Window ▸ submenu. Moves the
/// chosen window's YAML files to `Trash/window_<N>/` and adds the
/// number to `retired_window_ids` so it is never reused.
private struct WindowMenuForgetSubmenu: View {
    var body: some View {
        Menu("Forget Closed Window") {
            let closed = WindowRegistry.shared.closedWindows
            if closed.isEmpty {
                Button("No Closed Windows") {}.disabled(true)
            } else {
                ForEach(closed, id: \.windowID) { state in
                    Button(state.displayTitle) {
                        let alert = NSAlert()
                        alert.messageText = "Forget \(state.displayTitle)?"
                        alert.informativeText =
                            "This moves the window's YAML files to ~/Library/Application Support/ImageGlass_Mac/Trash/window_\(state.windowID)/ and prevents the window number from being reused."
                        alert.addButton(withTitle: "Forget")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            ImageGlassWindowActions.forgetClosedWindow(
                                windowID: state.windowID
                            )
                        }
                    }
                }
            }
        }
    }
}

/// multi_window.mdx §5.6 — Rename Window… opens a sheet that lets the
/// user set `window_name`. Updates the WindowState, persists the YAML,
/// and refreshes the AppKit auto-list in the Window menu via the
/// `NSWindow.title` update.
private struct WindowMenuRenameItem: View {
    var body: some View {
        Button("Rename Window…") {
            let alert = NSAlert()
            alert.messageText = "Rename Window"
            alert.informativeText =
                "Set a display name for the frontmost window. Leave blank to clear."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
            if let id = WindowRegistry.shared.frontmostWindowID,
               let existing = WindowRegistry.shared.window(id: id)?.settings.windowName {
                field.stringValue = existing
            }
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ImageGlassWindowActions.renameFrontmostWindow(to: raw.isEmpty ? nil : raw)
        }
    }
}

/// SwiftUI helper that materialises the system's recent-document list into
/// menu items. Uses `NSDocumentController.shared.recentDocumentURLs` — the
/// same backing store the AppKit Open Recent menu would use if the app
/// shipped as an `NSDocument`-based app.
private struct OpenRecentMenu: View {
    @Bindable var state: AppState

    var body: some View {
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            Button("No Recent Files") {}.disabled(true)
        } else {
            ForEach(urls, id: \.self) { url in
                Button(url.lastPathComponent) {
                    state.openExternalFile(url: url)
                }
            }
            Divider()
            Button("Clear Menu") {
                NSDocumentController.shared.clearRecentDocuments(nil)
            }
        }
    }
}

/// Maps panel descriptor ids to their SwiftUI factories. Other agents add
/// entries here (or call `PanelViewRegistry.shared.register` from elsewhere)
/// as they bring their panels online.
@MainActor
private func registerBuiltinViewFactories(state: AppState) {
    let registry = PanelViewRegistry.shared

    let dirFn: () -> AnyView = { AnyView(DirectoryFilenamePanel(state: state)) }
    registry.register(id: BuiltInPanelCatalog.filePanel.id, dirFn)
}
