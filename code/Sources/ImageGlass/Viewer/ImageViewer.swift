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
                    // hotkeys.mdx §4 + §5 — shared arrow + bare-letter
                    // zoom bindings (also attached to the Directory
                    // Panel so they work under either focus context).
                    .imageGlassHotkeys(state: state, viewer: viewer)
                    .onKeyPress(.space)      { handleSpace() }
                    .onKeyPress(.escape) {
                        if state.crop.isActive { state.crop.cancel(); return .handled }
                        return .ignored
                    }
                    // slideshow.mdx §1 / §3 / §5 — bare `S` lives in
                    // ImageGlassHotkeysModifier so it fires from the
                    // file tree too.
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
                        // `viewer.loadError` is image-canvas state. Clear it
                        // on any selection change so a prior image's error
                        // never lingers as a full-frame overlay on top of
                        // the next file — which previously covered SVGs
                        // and videos whenever the user clicked from a
                        // failed image to a working SVG / video.
                        viewer.loadError = nil
                    }
                if let cropOverlay { cropOverlay() }
                if state.crop.isActive {
                    CropOverlay(controller: state.crop)
                }
            } else {
                emptyState
                    .onDrop(of: [.fileURL], delegate: FileDropDelegate(state: state))
                    .focusable()
                    .focusEffectDisabled()
                    // hotkeys.mdx §4 + §5 — even with no file selected,
                    // the bare-letter bindings (S for slideshow, N / P
                    // for next / previous) must still work when focus
                    // is in the viewer pane. Without this attachment
                    // the empty-state view swallowed the keystrokes
                    // and only the Cmd+Option menu shortcut worked.
                    .imageGlassHotkeys(state: state, viewer: viewer)
                    .onKeyPress(.space) { handleSpace() }
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
            // Image-canvas state only: SVG and video have their own
            // ContentUnavailableView. Gating on `.image` keeps a stale or
            // racing `viewer.loadError` from covering an SVG / video canvas
            // that loaded fine.
            if let path = state.selectedFile,
               MediaKind.detect(path: path) == .image,
               let err = viewer.loadError {
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
        // slideshow.mdx §6 — countdown badge overlays the top-right of
        // the main viewer while a slideshow run is active in this
        // window. The slideshow no longer opens a new NSWindow; it
        // takes over the current viewer in place.
        .overlay(alignment: .topTrailing) {
            if viewer.isSlideshowRunning {
                slideshowCountdownBadge
                    .padding(14)
            }
        }
    }

    /// Countdown badge shown in the top-right corner while a slideshow
    /// run is active in this window. Ticks at 10 Hz via
    /// `viewer.slideshowRemaining`.
    private var slideshowCountdownBadge: some View {
        let remaining = max(0, viewer.slideshowRemaining)
        return HStack(spacing: 6) {
            Image(systemName: "timer")
            Text(String(format: "%0.1fs", remaining))
                .monospacedDigit()
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
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
        // docs/right_click.mdx §7.7 / §9.3 — stamp host references so
        // the canvas's `menu(for:)` can resolve the right AppState +
        // ViewerState without a global.
        v.hostState = state
        v.hostViewer = viewer
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
            let _loadTrace = PerformanceLog.shared.start(
                "Image.Load",
                extra: [("path", resolvedPath ?? "")]
            )
            defer { _loadTrace.finish() }
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
            //
            // hotkeys.mdx §6.1 — Zoom to Width persists across image
            // changes. Width mode keeps the rescale (so a fresh tall
            // mockup also fills the viewport horizontally) and re-arms
            // the top-align pass.
            Task { @MainActor in
                let preserveWidth = (viewer.zoomMode == .width)
                viewer.lockedZoom = 1.0
                viewer.panOffset = .zero
                viewer.rotationQuarterTurns = 0
                viewer.flipHorizontal = false
                viewer.flipVertical = false
                if preserveWidth {
                    viewer.zoomMode = .width
                    viewer.pendingScrollToTop = true
                } else {
                    viewer.zoomMode = .fit
                }
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
