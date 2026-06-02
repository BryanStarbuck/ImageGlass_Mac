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
            panelMenuCommands
        }
    }

    // MARK: - View → Panels & Layout (spec §10)

    @CommandsBuilder
    private var panelMenuCommands: some Commands {
        CommandMenu("Panels") {
            Menu("Layout Preset") {
                ForEach(BuiltInPreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        state.panelLayout.applyPreset(preset.rawValue)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(preset.shortcutIndex)")),
                                      modifiers: [.control, .command])
                }
            }
            Divider()
            Button("Toggle File Panel") {
                state.panelLayout.togglePanel("file_panel")
            }
            .keyboardShortcut("l", modifiers: [.command])
            Button("Toggle Toolbar") {
                state.panelLayout.togglePanel("toolbar")
            }
            .keyboardShortcut("t", modifiers: [.option, .command])
            Button("Toggle Status Bar") {
                state.panelLayout.togglePanel("status_bar")
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
            Button("Toggle Metadata") {
                state.panelLayout.togglePanel("metadata")
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            Button("Toggle Histogram") {
                state.panelLayout.togglePanel("histogram")
            }
            Button("Toggle Gallery Strip") {
                state.panelLayout.togglePanel("gallery_strip")
            }
            Button("Toggle Scope Editor") {
                state.panelLayout.togglePanel("scope_editor")
            }
            Divider()
            Button("Reset Panel Positions") {
                state.panelLayout.resetToActivePreset()
            }
            .keyboardShortcut("0", modifiers: [.control, .command])
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
