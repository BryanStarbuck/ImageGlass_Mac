import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state = AppState()

    // Owns the AppDelegate that overrides `orderFrontStandardAboutPanel`
    // so the default Apple About panel is replaced by `AboutView`, and
    // routes Finder file-open / dock-reopen / Open Recent through to the
    // running `AppState`. See `AboutWindow.swift`.
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
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let dir = AppPaths.appSupportDir.appendingPathComponent("clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url)
            state.openExternalFile(url: url)
        } catch {
            NSLog("Paste image write failed: \(error)")
        }
    }
}

/// SwiftUI helper that materialises the system's recent-document list
/// into menu items. Uses `NSDocumentController.shared.recentDocumentURLs`
/// — the same backing store the AppKit Open Recent menu would use if the
/// app shipped as an `NSDocument`-based app.
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
