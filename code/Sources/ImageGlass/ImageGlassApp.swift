import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state = AppState()

    // Owns the AppDelegate that overrides `orderFrontStandardAboutPanel`
    // so the default Apple About panel is replaced by `AboutView`.
    @NSApplicationDelegateAdaptor(AboutAppDelegate.self) private var aboutDelegate

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
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
                Button("Re-evaluate Active Scope") {
                    Task { await state.reevaluateActive() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFileDialog() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Paste Image from Clipboard") { pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command])
            }
            CommandGroup(after: .help) {
                Button("Releases & News…") {
                    ReleasesWindowController.shared.show()
                }
            }
            viewerMenuCommands
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
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            state.openExternalFile(url: url)
        }
    }

    /// Spec: "Paste clipboard data (image files, raw bitmaps, or file paths)
    /// with `Ctrl+V`." On macOS Cmd+V — covered above in the menu.
    private func pasteFromClipboard() {
        let result = ClipboardLoader.loadFromClipboard()
        // File URLs win — register the first recognized one so the user
        // gets the usual scope-resolution behavior.
        if let url = result.fileURLs.first(where: {
            FormatRegistry.shared.format(forURL: $0) != nil
        }) {
            state.openExternalFile(url: url)
            return
        }
        // Raw bytes / bitmaps — stash into a scratch file so the canvas can
        // load it through its normal URL path.
        if let loaded = result.image {
            do {
                let scratch = try writeScratchImage(loaded)
                state.openExternalFile(url: scratch)
            } catch {
                NSLog("paste write failed: \(error)")
            }
        }
    }

    private func writeScratchImage(_ image: LoadedImage) throws -> URL {
        let dir = AppPaths.appSupportDir.appendingPathComponent("ClipboardPaste",
                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("paste-\(stamp).png")
        try FrameExporter.saveFrame(image.cgImage, to: url)
        return url
    }

    private func saveCurrentFrame() {
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let fs = FrameSource.load(url: url), !fs.frames.isEmpty else { return }
        let idx = max(0, min(state.viewer.currentFrameIndex, fs.frameCount - 1))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent)-frame-\(idx + 1).png"
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try FrameExporter.saveFrame(fs.frames[idx].cgImage, to: dest)
            } catch {
                NSLog("save frame failed: \(error)")
            }
        }
    }

    private func exportAllFrames() {
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let fs = FrameSource.load(url: url), fs.frames.count > 1 else { return }
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
                NSLog("export frames failed: \(error)")
            }
        }
    }
}
