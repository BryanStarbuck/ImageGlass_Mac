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
                    .onKeyPress(.leftArrow,  phases: .down) { handleArrow(.left,  $0) }
                    .onKeyPress(.rightArrow, phases: .down) { handleArrow(.right, $0) }
                    .onKeyPress(.upArrow,    phases: .down) { handleArrow(.up,    $0) }
                    .onKeyPress(.downArrow,  phases: .down) { handleArrow(.down,  $0) }
                    .onKeyPress(.space)      { handleSpace() }
                    .onKeyPress(.escape) {
                        if state.crop.isActive { state.crop.cancel(); return .handled }
                        return .ignored
                    }
                    // hotkeys.mdx §5 — bare-letter zoom hotkeys. Only fire
                    // when no modifier is held so ⌘C / ⌘W keep their menu
                    // bindings (Copy, Close Window).
                    .onKeyPress("c", phases: .down) { handleZoomKey($0, action: .center) }
                    .onKeyPress("n", phases: .down) { handleZoomKey($0, action: .normalize) }
                    .onKeyPress("z", phases: .down) { handleZoomKey($0, action: .fit) }
                    .onKeyPress("w", phases: .down) { handleZoomKey($0, action: .width) }
                    .onKeyPress("=", phases: .down) { handleZoomKey($0, action: .zoomIn) }
                    .onKeyPress("+", phases: .down) { handleZoomKey($0, action: .zoomIn) }
                    .onKeyPress("-", phases: .down) { handleZoomKey($0, action: .zoomOut) }
                    // slideshow.mdx §1 / §3 / §5 — bare `S` toggles the
                    // slideshow on or off. Focus-aware via onKeyPress
                    // (text fields keep `s` for typing) and modifier-
                    // gated so `⌘S` (Save), `⇧⌘S` (Save As), `⌥⌘S`
                    // (View ▸ Toggle Slideshow menu shortcut) pass
                    // through to their menu items untouched.
                    .onKeyPress("s", phases: .down) { handleSlideshowKey($0) }
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

            // On-canvas error card — replaces the blank gray when a file is
            // selected but can't be displayed (Git LFS placeholder, etc.).
            if state.selectedFile != nil, let err = viewer.loadError {
                loadErrorCard(err)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Spacebar. videos.mdx §11.2 / svg.mdx §10.2 / slideshow.mdx §10.2
    /// — focus-context rule: when the current file is a video, Space
    /// toggles play/pause; when it is an animated SVG, Space toggles
    /// SVG animation; otherwise (image, or no selection yet) Space
    /// falls back to the slideshow toggle so it stays useful as the
    /// upstream-ImageGlass Space-starts-slideshow shortcut.
    private func handleSpace() -> KeyPress.Result {
        guard let path = state.selectedFile else {
            SlideshowController.shared.toggle(appState: state, source: "key:Space")
            return .handled
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
            // Static SVGs share the image fallback.
            SlideshowController.shared.toggle(appState: state, source: "key:Space")
            return .handled
        case .image:
            SlideshowController.shared.toggle(appState: state, source: "key:Space")
            return .handled
        }
    }

    /// Arrow-key handler. Behavior depends on the modifier:
    /// * Crop active — preserved from docs/crop.mdx §2.4 (nudge / grow).
    /// * `⌃` held — pan the viewer by 15% of viewport (hotkeys.mdx §4.3).
    /// * Bare — tree navigation: ↑/↓ step through visible rows, ←
    ///   collapses/parents, → expands/steps-in (hotkeys.mdx §4.1).
    private enum ArrowDir { case left, right, up, down }
    private func handleArrow(_ dir: ArrowDir, _ press: KeyPress) -> KeyPress.Result {
        if state.crop.isActive {
            let mods = press.modifiers
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
        // ⌃-arrow → viewport pan. hotkeys.mdx §4.3. Step is read from
        // Settings ▸ Viewer ▸ Pan step (percent of viewport).
        if press.modifiers.contains(.control) {
            let step = CGFloat(max(state.settings.viewer.pan_step_percent, 1) / 100.0)
            switch dir {
            case .left:  viewer.requestPan(dx: -step, dy:  0); return .handled
            case .right: viewer.requestPan(dx:  step, dy:  0); return .handled
            case .up:    viewer.requestPan(dx:  0,    dy: -step); return .handled
            case .down:  viewer.requestPan(dx:  0,    dy:  step); return .handled
            }
        }
        // Bare arrows: walk the visible tree (mix of folders + files).
        // hotkeys.mdx §4.1.
        switch dir {
        case .left:  state.arrowLeft();  return .handled
        case .right: state.arrowRight(); return .handled
        case .up:    state.arrowUp();    return .handled
        case .down:  state.arrowDown();  return .handled
        }
    }

    /// Bare-letter zoom hotkeys. hotkeys.mdx §5. Returns `.ignored`
    /// (so `⌘C` etc. still route to menu items) whenever a modifier
    /// other than Shift is held.
    private enum ZoomKey { case zoomIn, zoomOut, center, normalize, fit, width }
    private func handleZoomKey(_ press: KeyPress, action: ZoomKey) -> KeyPress.Result {
        // Crop overlay owns most letter keys — let them through.
        guard !state.crop.isActive else { return .ignored }
        // Allow Shift (so `+` reaches us as Shift-`=`), but not ⌘/⌥/⌃.
        let blocking: EventModifiers = [.command, .option, .control]
        if !press.modifiers.intersection(blocking).isEmpty { return .ignored }
        let step = state.settings.viewer.zoom_step_percent
        let lastRaw = UserDefaults.standard.string(forKey: ViewerState.lastZoomModeKey)
        let last = lastRaw.flatMap(ZoomMode.init(rawValue:))
        switch action {
        case .zoomIn:    viewer.zoomIn(stepPercent: step)
        case .zoomOut:   viewer.zoomOut(stepPercent: step)
        case .center:    viewer.centerImage()
        case .normalize: viewer.normalizeZoom(
            mode: state.settings.viewer.default_zoom_on_open,
            lastMode: last
        )
        case .fit:       viewer.zoomToFit()
        case .width:     viewer.zoomToWidth()
        }
        return .handled
    }

    /// slideshow.mdx §1 / §3 / §5 — the bare `S` key. `onKeyPress` is
    /// only delivered when the viewer is the first responder; text
    /// fields, search fields, and `WKWebView` text inputs keep `s` for
    /// typing because they consume the key-down before the focusable
    /// canvas sees it. Any of ⌘/⌥/⌃ on `S` falls through to
    /// `keyboardShortcut` so the menu items (Save, Save As, Toggle
    /// Slideshow) keep their bindings.
    private func handleSlideshowKey(_ press: KeyPress) -> KeyPress.Result {
        if state.crop.isActive { return .ignored }
        let blocking: EventModifiers = [.command, .option, .control]
        if !press.modifiers.intersection(blocking).isEmpty { return .ignored }
        SlideshowController.shared.toggle(appState: state, source: "key:S")
        return .handled
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

    /// Centered card shown when a file is selected but couldn't be displayed.
    /// Names the reason (e.g. Git LFS placeholder) so the user can act
    /// instead of staring at a blank canvas.
    private func loadErrorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Can't display this image")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IG.textC)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(IG.text2C)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let path = state.selectedFile {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(IG.text3C)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 340)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(IG.glassLineC, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
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
        // Route each selection to the right canvas: SVGs render through
        // SVGCanvasView (WKWebView / NSImage), videos through VideoCanvasView
        // (AVKit), everything else through the static image canvas.
        switch MediaKind.detect(path: path) {
        case .svg:
            SVGCanvasView(state: state, controller: state.svg, path: path)
        case .video:
            VideoCanvasView(state: state, controller: state.video, path: path)
        case .image:
            CanvasHost(state: state, viewer: viewer)
        }
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
            // Surface load failures on the canvas. If a file is selected but
            // produced no image (Git LFS placeholder, unreadable, corrupt),
            // compute the actionable reason for the on-canvas error card.
            let failed = (v.sourceImage == nil && v.frameSource == nil)
            let reason = (failed && resolvedPath != nil)
                ? FrameSource.failureReason(forPath: resolvedPath!)
                : nil
            Task { @MainActor in viewer.loadError = reason }
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

        // hotkeys.mdx §6.1 — Zoom to Width snaps the viewer to the top of
        // the image. Consume the pending flag here (the canvas has the
        // viewport size, ViewerState does not). Defer the clear to the
        // next runloop tick so this updateNSView pass does not mutate the
        // observable mid-render.
        if viewer.pendingScrollToTop {
            v.scrollToTopOfImage()
            Task { @MainActor in viewer.pendingScrollToTop = false }
        }

        // hotkeys.mdx §4.3 — ⌃-arrow pan, expressed as fractions of the
        // viewport. The canvas converts to points using its own bounds.
        let pend = viewer.pendingPanFraction
        if pend != .zero {
            v.panByFraction(dx: pend.width, dy: pend.height)
            Task { @MainActor in viewer.pendingPanFraction = .zero }
        }
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
