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
            }
            CommandGroup(after: .help) {
                Button("Releases & News…") {
                    ReleasesWindowController.shared.show()
                }
            }
            viewerMenuCommands
            cropMenuCommands
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
}
