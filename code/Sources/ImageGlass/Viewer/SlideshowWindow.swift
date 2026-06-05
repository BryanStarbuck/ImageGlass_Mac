import AppKit
import SwiftUI
import ImageGlassCore

/// A separate window that walks through `state.resolvedFiles` on a timer.
/// The viewer state inside the slideshow is independent (its own zoom +
/// view settings) so toggling things doesn't disturb the main window.
///
/// Contract spelled out in `docs/use_cases/slideshow.mdx` —
///   * §1–§3: `S` (and `⌥⌘S`) toggle this controller via `toggle()`.
///   * §4.7: interval changes in Settings apply on the next advance.
///   * §6: every advance re-applies the slideshow zoom mode (handled
///     by `CanvasHost.updateNSView`, which resets zoom/pan on every
///     `selectedFile` change).
///   * §7: `settings.slideshow.loop` controls wrap-vs-stop at the end
///     of the file list.
///   * §1.4 / §2.4 / §3.4 / §7.4 / §8.4: every state transition is
///     journaled to `log.log` so external auditors and XCUITests can
///     verify the run from the log alone.
@MainActor
final class SlideshowController {
    static let shared = SlideshowController()

    private var window: NSWindow?
    private var countdownTimer: Timer?
    private var hostingState: ViewerState?
    private var appState: AppState?
    private var nextAdvanceAt: Date?

    /// Audit bookkeeping per run. Reset on `start`, used by `stop`
    /// to write the `app=slideshow.stop advances=N elapsed_s=…` line.
    private var runCorr: String = ""
    private var runStart: Date = .distantPast
    private var advanceCount: Int = 0

    /// True while a slideshow window is open and advancing.
    /// `slideshow.mdx` §1.3 and §3.4 use this as the toggle pivot —
    /// `S` branches to `start` or `stop` on its value.
    var isRunning: Bool { window != nil }

    private init() {}

    /// `slideshow.mdx` §1–§3 — single entry point for every UI surface
    /// (`S` key, Space-on-image, View ▸ Start/Stop Slideshow,
    /// MCP `set_slideshow`). Reads
    /// `settings.slideshow.interval_seconds` so the GUI Settings
    /// slider is the source of truth for the interval. The `source`
    /// argument is recorded verbatim in the `tool=slideshow.toggle`
    /// audit line so an external observer can identify the trigger.
    func toggle(appState: AppState, source: String) {
        if isRunning {
            stop(reason: "user_toggle", source: source)
        } else {
            start(
                appState: appState,
                seconds: appState.settings.slideshow.interval_seconds,
                source: source
            )
        }
    }

    /// Open the slideshow window and start advancing. The empty-list
    /// guard surfaces a `tool=slideshow.toggle ok=false
    /// err=no_files_available` audit line so external observers see
    /// the attempted toggle and the reason it produced nothing
    /// (slideshow.mdx §8.4).
    func start(appState: AppState, seconds: Double, source: String) {
        // Idempotent restart: if a previous run is still up, tear it
        // down so we don't end up with two slideshow windows. The
        // stop here records `reason=user_toggle` because the new
        // start is itself driven by the user.
        if isRunning {
            stop(reason: "user_toggle", source: source)
        }

        let corr = MCPAuditLogger.newCorrelationId()

        guard !appState.resolvedFiles.isEmpty else {
            MCPAuditLogger.shared.logSlideshowToggle(
                on: true, interval: seconds, source: source,
                corr: corr, ok: false, err: "no_files_available"
            )
            return
        }

        let viewerState = ViewerState()
        viewerState.zoomMode = .fit
        viewerState.slideshowSeconds = seconds
        viewerState.slideshowRemaining = seconds
        viewerState.isSlideshowRunning = true

        let root = SlideshowRoot(state: appState, viewer: viewerState)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "ImageGlass Slideshow"
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 960, height: 720))
        win.center()
        win.makeKeyAndOrderFront(nil)

        self.window = win
        self.hostingState = viewerState
        self.appState = appState
        self.runCorr = corr
        self.runStart = Date()
        self.advanceCount = 0

        MCPAuditLogger.shared.logSlideshowToggle(
            on: true, interval: seconds, source: source,
            corr: corr, ok: true
        )

        scheduleTick(every: seconds)
    }

    func setInterval(_ seconds: Double) {
        hostingState?.slideshowSeconds = seconds
        if window != nil { scheduleTick(every: seconds) }
    }

    /// Convenience that records `reason=user_toggle`. Kept so legacy
    /// callers (and the MCP `set_slideshow(on:false)` path) can stop
    /// without needing to know the reason taxonomy.
    func stop() {
        stop(reason: "user_toggle", source: "key:S")
    }

    /// Tear down the slideshow. `reason` is recorded in the
    /// `app=slideshow.stop` audit line; pass `end_of_list` when the
    /// caller has detected the no-wrap end-of-list condition, otherwise
    /// `user_toggle`. `source` is only used when a paired
    /// `tool=slideshow.toggle on=false` line is emitted (i.e. when the
    /// user explicitly hit a stop UI). End-of-list stops are silent on
    /// the `tool=` surface.
    func stop(reason: String, source: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        nextAdvanceAt = nil

        let runWasActive = window != nil
        let corr = runCorr
        let elapsed = runWasActive ? Date().timeIntervalSince(runStart) : 0
        let advances = advanceCount

        window?.close()
        window = nil
        hostingState?.isSlideshowRunning = false
        hostingState?.slideshowRemaining = 0
        hostingState = nil
        let interval = appState?.settings.slideshow.interval_seconds ?? 0
        appState = nil
        runCorr = ""
        runStart = .distantPast
        advanceCount = 0

        guard runWasActive else { return }

        // User-initiated stops write a paired toggle line so the
        // session looks symmetric in the log; end-of-list auto-stops
        // skip it (there's no UI surface to attribute).
        if reason == "user_toggle" {
            MCPAuditLogger.shared.logSlideshowToggle(
                on: false, interval: interval, source: source,
                corr: corr, ok: true
            )
        }
        MCPAuditLogger.shared.logSlideshowStop(
            reason: reason,
            advances: advances,
            elapsedSeconds: elapsed,
            corr: corr
        )
    }

    /// Re-arm the countdown for a full `seconds` interval. Used after
    /// each advance and when the user dials a new interval.
    private func scheduleTick(every seconds: Double) {
        countdownTimer?.invalidate()
        guard seconds > 0 else { return }
        nextAdvanceAt = Date().addingTimeInterval(seconds)
        hostingState?.slideshowRemaining = seconds
        // Tick at 10 Hz so the countdown number ticks smoothly.
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown() }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    private func tickCountdown() {
        guard let state = hostingState, let target = nextAdvanceAt else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            advance()
        } else {
            state.slideshowRemaining = remaining
        }
    }

    /// Advance to the next image. Honors `settings.slideshow.loop`:
    /// when loop is on the controller wraps to file index 0 at the end
    /// of the list; when loop is off the controller stops with
    /// `reason=end_of_list`. Either way, an `app=slideshow.advance`
    /// line is written before any wrap/stop decision lands in the log
    /// so verifiers can see the last from/to pair.
    private func advance() {
        guard let appState, let state = hostingState else { return }
        let files = appState.resolvedFiles
        let loop = appState.settings.slideshow.loop
        let interval = appState.settings.slideshow.interval_seconds

        let fromPath = appState.selectedFile ?? ""
        // Determine the target index without mutating `selectedFile`
        // yet, so we can decide loop/stop with full information.
        let currentIdx = files.firstIndex(of: fromPath)
        let nextIdx: Int?
        var wrapped = false
        if let idx = currentIdx {
            if idx < files.count - 1 {
                nextIdx = idx + 1
            } else if loop {
                nextIdx = 0
                wrapped = true
            } else {
                nextIdx = nil // end of list, no wrap → stop
            }
        } else {
            nextIdx = files.first.map { _ in 0 }
        }

        guard let target = nextIdx else {
            // slideshow.mdx §7.7 — auto-stop at end of list, loop off.
            stop(reason: "end_of_list", source: "")
            return
        }

        let toPath = files[target]
        appState.selectedFile = toPath
        advanceCount += 1

        MCPAuditLogger.shared.logSlideshowAdvance(
            from: fromPath,
            to: toPath,
            interval: interval,
            zoomMode: zoomModeLabel(state.zoomMode),
            wrap: wrapped,
            corr: runCorr
        )

        // slideshow.mdx §4.7 — mid-show interval edits apply to the
        // next interval, not the current countdown. Re-read the
        // setting here so the GUI slider / text field updates take
        // effect at the next advance boundary.
        if abs(interval - state.slideshowSeconds) > 0.0001 {
            state.slideshowSeconds = interval
        }
        scheduleTick(every: state.slideshowSeconds)
    }

    /// Short label used in the audit log so a grep on `zoom_mode=fit`
    /// works. ZoomMode is a String-backed enum whose `rawValue` is
    /// already the short lowercase name (`auto`, `lock`, `width`,
    /// `height`, `fit`, `fill`).
    private func zoomModeLabel(_ mode: ZoomMode) -> String {
        mode.rawValue
    }
}

private struct SlideshowRoot: View {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ImageViewer(state: state, viewer: viewer)
                .background(Color.black)
            countdownBadge
                .padding(14)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    SlideshowController.shared.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop slideshow")
            }
            ToolbarItem {
                HStack {
                    Image(systemName: "timer")
                    Stepper(value: $viewer.slideshowSeconds, in: 1...60, step: 1) {
                        Text("\(Int(viewer.slideshowSeconds))s")
                            .monospacedDigit()
                    }
                    .onChange(of: viewer.slideshowSeconds) { _, new in
                        SlideshowController.shared.setInterval(new)
                    }
                }
            }
        }
    }

    /// Spec: "Slideshow ... with configurable countdown timers." The badge
    /// shows seconds remaining until the next slide, ticking at 10 Hz.
    private var countdownBadge: some View {
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
}
