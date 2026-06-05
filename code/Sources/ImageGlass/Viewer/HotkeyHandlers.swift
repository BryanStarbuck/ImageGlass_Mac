import SwiftUI
import AppKit
import ImageGlassCore

/// Shared hotkey surface from `docs/hotkeys.mdx`. Attached to both the
/// viewer canvas and the Directory Panel so the bare-letter and arrow
/// bindings fire under either focus context (spec §3 / §4.2).
///
/// Text-field-focus suppression (spec §3) happens automatically — when
/// a `TextField` is first responder, SwiftUI routes the keystrokes to
/// the field and these `.onKeyPress` blocks never see them.
struct ImageGlassHotkeysModifier: ViewModifier {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState

    func body(content: Content) -> some View {
        content
            .onKeyPress(.leftArrow,  phases: .down) { handleArrow(.left,  $0) }
            .onKeyPress(.rightArrow, phases: .down) { handleArrow(.right, $0) }
            .onKeyPress(.upArrow,    phases: .down) { handleArrow(.up,    $0) }
            .onKeyPress(.downArrow,  phases: .down) { handleArrow(.down,  $0) }
            .onKeyPress("c", phases: .down) { handleZoomKey($0, action: .center) }
            // slideshow.mdx §10A — bare `M` is the new home for
            // Normalize zoom (the v0 `N` binding moved to navigation).
            // Both cases routed for symmetry with `i`/`I`.
            .onKeyPress("m", phases: .down) { handleZoomKey($0, action: .normalize) }
            .onKeyPress("M", phases: .down) { handleZoomKey($0, action: .normalize) }
            .onKeyPress("z", phases: .down) { handleZoomKey($0, action: .fit) }
            .onKeyPress("w", phases: .down) { handleZoomKey($0, action: .width) }
            .onKeyPress("=", phases: .down) { handleZoomKey($0, action: .zoomIn) }
            .onKeyPress("+", phases: .down) { handleZoomKey($0, action: .zoomIn) }
            .onKeyPress("-", phases: .down) { handleZoomKey($0, action: .zoomOut) }
            // include_checks.mdx §4 — bare `I` cycles the focused
            // row's include state. Modifier-suppression matches the
            // zoom keys: any non-Shift modifier yields .ignored so
            // menu chords (⌃1/⌃2/⌃3 in §7) still route through the
            // menu bar.
            .onKeyPress("i", phases: .down) { handleIncludeKey($0) }
            .onKeyPress("I", phases: .down) { handleIncludeKey($0) }
            // slideshow.mdx §10A — bare `N` (next) and `P` (previous)
            // step `AppState.selectedFile` through
            // `AppState.orderedNavigationFiles` (the file-tree's
            // top-down visible order, excluded files filtered out).
            // The keys use the same cursor the slideshow uses, so
            // pressing N during a running slideshow re-anchors the
            // controller exactly like a panel-row click does (§2A).
            .onKeyPress("n", phases: .down) { handleSelectKey($0, direction: .next) }
            .onKeyPress("N", phases: .down) { handleSelectKey($0, direction: .next) }
            .onKeyPress("p", phases: .down) { handleSelectKey($0, direction: .previous) }
            // Shift+`P` is the relocated Copy-Path binding
            // (slideshow.mdx §10A header). `.onKeyPress("P")` only
            // matches the shifted character, so this routes solely
            // to copy-path while bare `p` routes to previous-image.
            .onKeyPress("P", phases: .down) { handleCopyPathKey($0) }
    }

    private enum ArrowDir { case left, right, up, down }
    private enum ZoomKey { case zoomIn, zoomOut, center, normalize, fit, width }
    private enum SelectDir { case next, previous }

    /// hotkeys.mdx §4: arrow handling. ⌃-arrow pans the viewer; bare
    /// arrows walk the tree (file rows mirror into `state.selectedFile`).
    /// Crop mode keeps its nudge/grow semantics from docs/crop.mdx §2.4.
    private func handleArrow(_ dir: ArrowDir, _ press: KeyPress) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "Hotkey.Handle",
            extra: [("key", "arrow:\(dir)")]
        )
        defer { _trace.finish() }
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
        if press.modifiers.contains(.control) {
            let step = CGFloat(max(state.settings.viewer.pan_step_percent, 1) / 100.0)
            switch dir {
            case .left:  viewer.requestPan(dx: -step, dy:  0); return .handled
            case .right: viewer.requestPan(dx:  step, dy:  0); return .handled
            case .up:    viewer.requestPan(dx:  0,    dy: -step); return .handled
            case .down:  viewer.requestPan(dx:  0,    dy:  step); return .handled
            }
        }
        switch dir {
        case .left:  state.arrowLeft();  return .handled
        case .right: state.arrowRight(); return .handled
        case .up:    state.arrowUp();    return .handled
        case .down:  state.arrowDown();  return .handled
        }
    }

    /// actions.mdx §5 — Shift+`P` copies the absolute path of the
    /// currently loaded viewer file. (The bare `P` binding now goes
    /// to previous-image — slideshow.mdx §10A.) Suppression: any
    /// non-Shift modifier yields `.ignored` so the `⌘P` Print chord
    /// still routes through the menu bar. Crop mode also suppresses
    /// the key — the user is in the crop interaction loop.
    private func handleCopyPathKey(_ press: KeyPress) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "Hotkey.Handle",
            extra: [("key", "shift+P:copyPath")]
        )
        defer { _trace.finish() }
        guard !state.crop.isActive else { return .ignored }
        let blocking: EventModifiers = [.command, .option, .control]
        if !press.modifiers.intersection(blocking).isEmpty { return .ignored }
        guard state.selectedFile != nil else { return .ignored }
        _ = FileActions.copyFilePath(state: state, source: .keyP)
        return .handled
    }

    /// slideshow.mdx §10A — bare `N` / `P` step the global selection
    /// cursor through `AppState.orderedNavigationFiles` (next /
    /// previous). Honors `settings.viewer.wrap_at_ends`. Skips
    /// excluded and inherit-excluded files because the navigation
    /// list already drops them (§1A.2). Suppression: any non-Shift
    /// modifier yields `.ignored` so menu chords still route. Crop
    /// mode suppresses the keys — the user is mid-task.
    private func handleSelectKey(_ press: KeyPress, direction: SelectDir) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "Hotkey.Handle",
            extra: [("key", "select:\(direction)")]
        )
        defer { _trace.finish() }
        guard !state.crop.isActive else { return .ignored }
        let blocking: EventModifiers = [.command, .option, .control]
        if !press.modifiers.intersection(blocking).isEmpty { return .ignored }
        let wrap = state.settings.viewer.wrap_at_ends
        switch direction {
        case .next:     state.selectNext(wrap: wrap)
        case .previous: state.selectPrevious(wrap: wrap)
        }
        return .handled
    }

    /// include_checks.mdx §4 — bare `I` cycles the focused row's
    /// include state. Sub-rows cycle through three states; root rows
    /// flip between two (§1.0). Suppression: any non-Shift modifier
    /// yields `.ignored` so menu chords elsewhere still route through.
    /// Crop mode suppresses the key entirely (the user is mid-task).
    private func handleIncludeKey(_ press: KeyPress) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "Hotkey.Handle",
            extra: [("key", "I:cycleInclude")]
        )
        defer { _trace.finish() }
        guard !state.crop.isActive else { return .ignored }
        let blocking: EventModifiers = [.command, .option, .control]
        if !press.modifiers.intersection(blocking).isEmpty { return .ignored }
        let target = state.treeNav.activeRow ?? state.selectedFile
        guard let path = target else { return .ignored }
        _ = IncludeStateController.cycle(
            absolutePath: path,
            appState: state
        )
        return .handled
    }

    /// hotkeys.mdx §5: bare-letter zoom keys. Returns `.ignored`
    /// whenever a non-Shift modifier is held so the `⌘C`/`⌘W` menu
    /// chords still route to the menu bar.
    private func handleZoomKey(_ press: KeyPress, action: ZoomKey) -> KeyPress.Result {
        let _trace = PerformanceLog.shared.start(
            "Hotkey.Handle",
            extra: [("key", "zoom:\(action)")]
        )
        defer { _trace.finish() }
        guard !state.crop.isActive else { return .ignored }
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
}

extension View {
    /// Attach the shared hotkey set (hotkeys.mdx §4 + §5). Apply to any
    /// SwiftUI surface that should accept the bindings — currently the
    /// viewer canvas and the Directory Panel.
    func imageGlassHotkeys(state: AppState, viewer: ViewerState) -> some View {
        modifier(ImageGlassHotkeysModifier(state: state, viewer: viewer))
    }
}
