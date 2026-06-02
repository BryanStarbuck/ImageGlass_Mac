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
            Button("Start Slideshow") {
                SlideshowController.shared.start(
                    appState: state,
                    seconds: state.viewer.slideshowSeconds
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
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
