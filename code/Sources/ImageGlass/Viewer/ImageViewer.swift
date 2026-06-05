import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageGlassCore

/// Top-level viewer. Wraps the AppKit `ImageCanvasView`, layers SwiftUI
/// overlays (info card, color-picker readout), wires keyboard navigation,
/// and accepts drag-and-drop. Designed to be hosted by ContentView and
/// also embedded in standalone Full Screen / Slideshow windows.
struct ImageViewer: View {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState
    /// Optional crop hook — owned by the crop agent. When non-nil, a
    /// crop-overlay view can render on top of the canvas. We expose it as a
    /// trailing closure so this file does not depend on the crop subsystem.
    var cropOverlay: (() -> AnyView)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let path = state.selectedFile {
                MediaCanvasDispatcher(state: state, viewer: viewer, path: path)
                    .onDrop(of: [.fileURL], delegate: FileDropDelegate(state: state))
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.leftArrow)  { handleArrow(.left)  }
                    .onKeyPress(.rightArrow) { handleArrow(.right) }
                    .onKeyPress(.upArrow)    { handleArrow(.up)    }
                    .onKeyPress(.downArrow)  { handleArrow(.down)  }
                    .onKeyPress(.space)      { handleSpace() }
                    .onKeyPress(.escape) {
                        if state.crop.isActive { state.crop.cancel(); return .handled }
                        return .ignored
                    }
                    .onKeyPress("g") {
                        if state.crop.isActive { state.crop.cycleGrid(); return .handled }
                        return .ignored
                    }
                    .onKeyPress("1") { if state.crop.isActive { state.crop.aspectRatio = .freeRatio;  return .handled }; return .ignored }
                    .onKeyPress("2") { if state.crop.isActive { state.crop.aspectRatio = .ratio1_1;   return .handled }; return .ignored }
                    .onKeyPress("3") { if state.crop.isActive { state.crop.aspectRatio = .ratio4_3;   return .handled }; return .ignored }
                    .onKeyPress("4") { if state.crop.isActive { state.crop.aspectRatio = .ratio3_2;   return .handled }; return .ignored }
                    .onKeyPress("5") { if state.crop.isActive { state.crop.aspectRatio = .ratio16_9;  return .handled }; return .ignored }
                    .onChange(of: state.selectedFile) { _, path in
                        // Refresh crop selection on image change (spec §2.7).
                        state.crop.bind(activeImage: nil, path: path)
                    }
                if let cropOverlay { cropOverlay() }
                if state.crop.isActive {
                    CropOverlay(controller: state.crop)
                }
            } else {
                emptyState
                    .onDrop(of: [.fileURL], delegate: FileDropDelegate(state: state))
            }

            VStack(alignment: .leading, spacing: 6) {
                if viewer.showInfoOverlay {
                    ImageInfoOverlay(
                        filePath: state.selectedFile,
                        frameCount: viewer.frameCount,
                        currentFrameIndex: viewer.currentFrameIndex,
                        isAnimated: viewer.isAnimated
                    )
                }
                if viewer.showColorPicker {
                    ColorPickerOverlay(
                        pixel: viewer.hoverPixel,
                        color: viewer.hoverColor,
                        format: $viewer.colorFormat
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Canvas background behind the image — the design's page-gray
        // (`IG.canvas`), adapting to light / dark so the image reads cleanly.
        .background(IG.canvasC)
        // Floating glass zoom cluster (design: canvas.jsx), bottom-center,
        // auto-hiding when the pointer is idle. Only while an image is shown.
        .overlay(alignment: .bottom) {
            if state.selectedFile != nil {
                ViewerZoomControls(viewer: viewer, visible: controlsVisible)
                    .padding(.bottom, 22)
                    .onHover { hovering in if hovering { pokeControls() } }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { pokeControls() }
        }
        .onChange(of: state.selectedFile) { _, _ in pokeControls() }
    }

    // MARK: - Auto-hiding controls

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private func pokeControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { controlsVisible = false }
        }
    }

    /// Spacebar. videos.mdx §11.2 / svg.mdx §10.2 — focus-context rule:
    /// when the current file is a video, Space toggles play/pause; when
    /// it is an animated SVG, Space toggles SVG animation; otherwise
    /// fall back to the existing image-canvas behavior (zoom to actual).
    private func handleSpace() -> KeyPress.Result {
        guard let path = state.selectedFile else {
            viewer.zoomToActual(); return .handled
        }
        switch MediaKind.detect(path: path) {
        case .video:
            state.video.playPauseToggle()
            return .handled
        case .svg:
            if state.svg.kind == .animated {
                state.svg.playPauseToggle()
                return .handled
            }
            return .ignored
        case .image:
            viewer.zoomToActual()
            return .handled
        }
    }

    /// Arrow-key handler. When the crop tool is active, arrows nudge /
    /// grow the selection per docs/crop.mdx §2.4. Otherwise they
    /// navigate to prev / next image.
    private enum ArrowDir { case left, right, up, down }
    private func handleArrow(_ dir: ArrowDir) -> KeyPress.Result {
        if state.crop.isActive {
            let mods = NSEvent.modifierFlags
            let shift = mods.contains(.shift)
            let cmd = mods.contains(.command)
            let mag: CGFloat = shift ? 10 : 1
            switch (cmd, dir) {
            case (false, .left):  state.crop.nudge(dx: -mag, dy: 0); return .handled
            case (false, .right): state.crop.nudge(dx:  mag, dy: 0); return .handled
            case (false, .up):    state.crop.nudge(dx: 0, dy: -mag); return .handled
            case (false, .down):  state.crop.nudge(dx: 0, dy:  mag); return .handled
            case (true,  .left):  state.crop.grow(dw: -mag, dh: 0); return .handled
            case (true,  .right): state.crop.grow(dw:  mag, dh: 0); return .handled
            case (true,  .up):    state.crop.grow(dw: 0, dh: -mag); return .handled
            case (true,  .down):  state.crop.grow(dw: 0, dh:  mag); return .handled
            }
        }
        // Left/Right step image-by-image (spec menus.mdx). Up/Down jump
        // folder-to-folder — to the first image of the prev/next folder —
        // so the user can skip whole subprojects/pages in a meeting.
        switch dir {
        case .left:  state.selectPrevious();       return .handled
        case .right: state.selectNext();           return .handled
        case .up:    state.selectPreviousFolder(); return .handled
        case .down:  state.selectNextFolder();     return .handled
        }
    }

    /// Empty-viewer placeholder per `docs/use_cases/mcp_file.mdx` §9.2:
    /// "a centered placeholder reading `No image previewed` in the theme's
    /// secondary-label color. No stale image remains on the canvas."
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No image previewed", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
        } description: {
            Text("Drag an image into the window or pick a file from the panel on the left.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Media kind dispatch

/// Pick the right canvas for the selected file. Static images render
/// through the existing `CanvasHost`; videos go to `VideoCanvasView`
/// (AVKit `AVPlayerView`); SVGs go to `SVGCanvasView` (WKWebView or
/// NSImage). Detection uses UTType + extension via
/// `MediaKind.detect(path:)`.
private struct MediaCanvasDispatcher: View {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState
    let path: String

    var body: some View {
        // Bryan: temporarily route every selection through the static
        // image canvas. The SVG and video canvases are disabled for
        // now; restoring them is a switch back to `MediaKind.detect`.
        CanvasHost(state: state, viewer: viewer)
    }
}

// MARK: - SwiftUI ↔ AppKit canvas bridge

private struct CanvasHost: NSViewRepresentable {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState

    func makeNSView(context: Context) -> ImageCanvasView {
        let v = ImageCanvasView()
        v.onUserTransform = { pan, zoom, mode in
            viewer.panOffset = pan
            viewer.lockedZoom = zoom
            viewer.zoomMode = mode
        }
        v.onHover = { pixel, color in
            viewer.hoverPixel = pixel
            viewer.hoverColor = color
        }
        v.onFrameSourceChanged = { fs in
            viewer.frameCount = fs?.frameCount ?? 1
            viewer.isAnimated = fs?.isAnimated ?? false
            viewer.currentFrameIndex = 0
            viewer.isAnimationPaused = false
        }
        v.onFrameAdvanced = { idx in
            viewer.currentFrameIndex = idx
        }
        return v
    }

    func updateNSView(_ v: ImageCanvasView, context: Context) {
        // Always reload when `selectedFile` changes. Previously this
        // compared `v.toolTip` to the new path, which broke silently
        // whenever `toolTip` was reset out from under us — and the
        // canvas would refuse to load even though a fresh file was
        // selected in the file tree. Tracking `loadedPath` on the
        // view itself removes the side-channel.
        //
        // The expanded path is also re-validated against the filesystem
        // here (in addition to inside setImage). A `state.selectedFile`
        // that is a bare filename or a stale path produces a single
        // log line and the canvas falls back to "no image" rather than
        // silently presenting an empty cyan window.
        let resolvedPath = state.selectedFile.map { AppPaths.expandTilde($0) }
        if v.loadedPath != resolvedPath {
            if let raw = state.selectedFile, let expanded = resolvedPath {
                let result = ImageCanvasView.validate(path: expanded)
                if result != .ok {
                    ErrorLog.log("CanvasHost.updateNSView: invalid selectedFile (\(result)) raw='\(raw)' expanded='\(expanded)'",
                                 class: "CanvasHost")
                }
            }
            v.setImage(path: resolvedPath)
            v.toolTip = resolvedPath
            // ViewerState carries the user's current zoom/pan across
            // image changes via SwiftUI. That breaks the "every new
            // image opens fit-to-window, centered" contract — a previous
            // pan-and-zoom from the last image survives into the next
            // one and the new image lands off-screen. Resetting here
            // (in the host, on the SwiftUI side) is the only place that
            // sticks, because `updateNSView` runs again right after and
            // would otherwise stamp the old values back onto the view.
            Task { @MainActor in
                viewer.zoomMode = .fit
                viewer.lockedZoom = 1.0
                viewer.panOffset = .zero
                viewer.rotationQuarterTurns = 0
                viewer.flipHorizontal = false
                viewer.flipVertical = false
            }
        }
        v.zoomMode = viewer.zoomMode
        v.lockedZoom = viewer.lockedZoom
        v.panOffset = viewer.panOffset
        v.rotationQuarterTurns = viewer.rotationQuarterTurns
        v.flipHorizontal = viewer.flipHorizontal
        v.flipVertical = viewer.flipVertical
        v.smoothInterpolation = viewer.smoothInterpolation
        v.colorChannel = viewer.colorChannel
        v.showColorPicker = viewer.showColorPicker
        v.currentFrameIndex = viewer.currentFrameIndex
        v.isAnimationPaused = viewer.isAnimationPaused
    }
}

// MARK: - Drag-and-drop

private struct FileDropDelegate: DropDelegate {
    @Bindable var state: AppState

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard let first = providers.first else { return false }
        _ = first.loadObject(ofClass: URL.self) { url, error in
            if let error {
                ErrorLog.log("FileDropDelegate loadObject failed",
                             error: error,
                             class: "FileDropDelegate")
            }
            guard let url else { return }
            Task { @MainActor in
                state.openExternalFile(url: url)
            }
        }
        return true
    }
}
