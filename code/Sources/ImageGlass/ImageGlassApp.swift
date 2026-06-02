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

    // Intercept `--help` / `-h` / `/?` at process start so the user gets
    // a real CLI help message instead of a window opening; then parse the
    // remaining `/Name=Value` overrides and positional file args into the
    // initial AppState.
    init() {
        let raw = Array(CommandLine.arguments.dropFirst())
        if CLIArguments.wantsHelp(raw) {
            print(CLIArguments.helpText())
            exit(0)
        }
        let s = AppState()
        let parsed = ImageGlassLaunchArguments.parse(CommandLine.arguments)
        s.applyLaunchArguments(parsed)
        _state = State(wrappedValue: s)
    }

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    registerBuiltinViewFactories(state: state)
                }
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
                Button("Re-evaluate Active Scope") {
                    Task { await state.reevaluateActive() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFileDialog() }
                    .keyboardShortcut("o", modifiers: [.command])
                Menu("Open Recent") {
                    OpenRecentMenu(state: state)
                }
            }
            CommandGroup(after: .pasteboard) {
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
            // `videoMenuCommands` / `svgMenuCommands` placeholders are
            // wired in by a parallel WIP; once they land they slot back here.
        }

        Settings {
            SettingsScene(state: state)
        }
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
            Button("Refresh All") {
                refreshAllDirectories()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Reveal in Finder") {
                revealActiveSelectionInFinder()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(state.selectedFile == nil)
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
                let (_, already) = try DirectoriesStore.shared.addRoot(path: url.path)
                if !already {
                    let corr = MCPAuditLogger.newCorrelationId()
                    MCPAuditLogger.shared.logDirectoryToolCall(
                        toolName: "add_directory",
                        path: url.path,
                        client: "gui",
                        corr: corr,
                        ok: true
                    )
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: url,
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
            Button("Zoom In")     { state.viewer.zoomIn() }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Zoom Out")    { state.viewer.zoomOut() }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Actual Size") { state.viewer.zoomToActual() }
                .keyboardShortcut("0", modifiers: [.command])
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
            // Slideshow start/stop. videos.mdx §11.2 moves the
            // unconditional shortcut to ⌥⌘S so `Space` / `S` are free
            // for the Video / SVG menus' focus-context bindings.
            Button("Start Slideshow") {
                SlideshowController.shared.start(
                    appState: state,
                    seconds: state.viewer.slideshowSeconds
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Stop Slideshow") { SlideshowController.shared.stop() }
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
