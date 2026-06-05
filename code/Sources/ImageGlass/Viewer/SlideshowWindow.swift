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

    /// One slideshow run per window (multi_window.mdx §7). Window 1 can
    /// be cycling a UX-design tour while window 2 is hand-stepping
    /// family photos; both timers tick independently and write to
    /// their own per-window YAML on quit.
    private struct Run {
        let windowID: Int
        var window: NSWindow?
        var countdownTimer: Timer?
        var hostingState: ViewerState?
        var appState: AppState?
        var nextAdvanceAt: Date?
        var runCorr: String = ""
        var runStart: Date = .distantPast
        var advanceCount: Int = 0
    }

    /// Keyed by `window_id`. Absent key ⇒ no slideshow running in
    /// that window.
    private var runs: [Int: Run] = [:]

    /// Aggregate "is any window currently running a slideshow"
    /// (multi_window.mdx §7.3). Used by the View menu's
    /// Start/Stop label which currently has a single toggle.
    var isRunning: Bool { !runs.isEmpty }

    /// Per-window predicate (multi_window.mdx §7.1). The Window menu's
    /// Slideshow indicator and quit-time `wasRunningOnQuit` flag use
    /// this.
    func isRunning(windowID: Int) -> Bool { runs[windowID] != nil }

    /// Resolve the implicit MCP / menu target window for slideshow
    /// commands (multi_window.mdx §7.2). Falls back to window 1 when
    /// the registry has no frontmost yet (very early launch, tests).
    private func resolveTargetWindowID() -> Int {
        WindowRegistry.shared.frontmostWindowID
            ?? WindowRegistry.shared.windows.keys.sorted().first
            ?? 1
    }

    private init() {}

    /// `slideshow.mdx` §1–§3 — single entry point for every UI surface
    /// (`S` key, Space-on-image, View ▸ Start/Stop Slideshow,
    /// MCP `set_slideshow`). Reads
    /// `settings.slideshow.interval_seconds` so the GUI Settings
    /// slider is the source of truth for the interval. The `source`
    /// argument is recorded verbatim in the `tool=slideshow.toggle`
    /// audit line so an external observer can identify the trigger.
    ///
    /// multi_window.mdx §7.2 — per-window. When `windowID` is nil the
    /// frontmost window is the implicit target.
    func toggle(appState: AppState, source: String, windowID: Int? = nil) {
        let target = windowID ?? resolveTargetWindowID()
        if isRunning(windowID: target) {
            stop(windowID: target, reason: "user_toggle", source: source)
        } else {
            start(
                appState: appState,
                seconds: appState.settings.slideshow.interval_seconds,
                source: source,
                windowID: target
            )
        }
    }

    /// Open the slideshow window and start advancing. The empty-list
    /// guard surfaces a `tool=slideshow.toggle ok=false
    /// err=no_files_available` audit line so external observers see
    /// the attempted toggle and the reason it produced nothing
    /// (slideshow.mdx §8.4).
    ///
    /// multi_window.mdx §7 — per-window. `windowID` is the window the
    /// run is attributed to (audit, persistence on quit). When omitted
    /// the frontmost window is used. Two windows can have independent
    /// runs at the same time.
    func start(appState: AppState, seconds: Double, source: String, windowID: Int? = nil) {
        let target = windowID ?? resolveTargetWindowID()
        let _trace = PerformanceLog.shared.start(
            "Slideshow.Start",
            extra: [
                ("source", source),
                ("interval_s", String(seconds)),
                ("window_id", String(target)),
            ]
        )
        defer { _trace.finish() }
        // Idempotent restart for the *same* window: if a previous run
        // is still up in this window, tear it down so we don't end up
        // with two slideshow windows for one. The stop here records
        // `reason=user_toggle` because the new start is itself driven
        // by the user. Other windows' runs are untouched (§7.3).
        if isRunning(windowID: target) {
            stop(windowID: target, reason: "user_toggle", source: source)
        }

        let corr = MCPAuditLogger.newCorrelationId()

        // slideshow.mdx §1A + §8 — gate the start on the same
        // ordered, filtered navigation list the advance loop walks.
        // Bare `resolvedFiles` would pass when every file is
        // excluded, which would race the user into a single
        // `no_in_scope_files` advance failure instead of the clean
        // `no_files_available` toggle audit line §8.4 expects.
        guard !appState.orderedNavigationFiles.isEmpty else {
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

        let root = SlideshowRoot(state: appState, viewer: viewerState, windowID: target)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "ImageGlass Slideshow — Window \(target)"
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 960, height: 720))
        win.center()
        win.makeKeyAndOrderFront(nil)

        var run = Run(windowID: target)
        run.window = win
        run.hostingState = viewerState
        run.appState = appState
        run.runCorr = corr
        run.runStart = Date()
        run.advanceCount = 0
        runs[target] = run

        // multi_window.mdx §7.1 — mark the per-window slideshow as
        // running in-memory. Persistence of `wasRunningOnQuit`
        // happens on quit-time flush (§7.4 / §11.2).
        if let windowState = WindowRegistry.shared.window(id: target) {
            windowState.slideshow.isRunning = true
            windowState.slideshow.lastAdvancedAt = nil
        }

        MCPAuditLogger.shared.logSlideshowToggle(
            on: true, interval: seconds, source: source,
            corr: corr, ok: true
        )

        scheduleTick(windowID: target, every: seconds)
    }

    /// Adjust the interval for the **frontmost** window's run.
    func setInterval(_ seconds: Double) {
        setInterval(seconds, windowID: resolveTargetWindowID())
    }

    /// Per-window interval setter (multi_window.mdx §7).
    func setInterval(_ seconds: Double, windowID: Int) {
        guard let run = runs[windowID] else { return }
        run.hostingState?.slideshowSeconds = seconds
        if run.window != nil { scheduleTick(windowID: windowID, every: seconds) }
    }

    /// Convenience that records `reason=user_toggle` on the frontmost
    /// window. Kept so legacy callers (and the MCP
    /// `set_slideshow(on:false)` path) can stop without needing to
    /// know the reason taxonomy or the window id.
    func stop() {
        stop(windowID: resolveTargetWindowID(),
             reason: "user_toggle",
             source: "key:S")
    }

    /// Frontmost-window stop with an explicit reason / source.
    func stop(reason: String, source: String) {
        stop(windowID: resolveTargetWindowID(), reason: reason, source: source)
    }

    /// Tear down the slideshow for one specific window. `reason` is
    /// recorded in the `app=slideshow.stop` audit line; pass
    /// `end_of_list` when the caller has detected the no-wrap
    /// end-of-list condition, otherwise `user_toggle`. `source` is
    /// only used when a paired `tool=slideshow.toggle on=false` line
    /// is emitted (i.e. when the user explicitly hit a stop UI).
    /// End-of-list stops are silent on the `tool=` surface.
    ///
    /// multi_window.mdx §7 — only the named window's run is torn
    /// down. Other windows' runs are unaffected.
    func stop(windowID: Int, reason: String, source: String) {
        let _trace = PerformanceLog.shared.start(
            "Slideshow.Stop",
            extra: [
                ("reason", reason),
                ("source", source),
                ("window_id", String(windowID)),
            ]
        )
        defer { _trace.finish() }
        guard var run = runs[windowID] else { return }
        run.countdownTimer?.invalidate()
        run.countdownTimer = nil
        run.nextAdvanceAt = nil

        let runWasActive = run.window != nil
        let corr = run.runCorr
        let elapsed = runWasActive ? Date().timeIntervalSince(run.runStart) : 0
        let advances = run.advanceCount

        run.window?.close()
        run.window = nil
        run.hostingState?.isSlideshowRunning = false
        run.hostingState?.slideshowRemaining = 0
        run.hostingState = nil
        let interval = run.appState?.settings.slideshow.interval_seconds ?? 0
        run.appState = nil
        runs.removeValue(forKey: windowID)

        // multi_window.mdx §7.1 / §7.4 — drop the per-window in-memory
        // running flag. The persisted `wasRunningOnQuit` is updated by
        // the quit-time flush, not here, so a manual stop mid-session
        // still records "was not running on quit" at next launch.
        if let windowState = WindowRegistry.shared.window(id: windowID) {
            windowState.slideshow.isRunning = false
            windowState.slideshow.isPaused = false
        }

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
    private func scheduleTick(windowID: Int, every seconds: Double) {
        guard var run = runs[windowID] else { return }
        run.countdownTimer?.invalidate()
        guard seconds > 0 else { runs[windowID] = run; return }
        run.nextAdvanceAt = Date().addingTimeInterval(seconds)
        run.hostingState?.slideshowRemaining = seconds
        // Tick at 10 Hz so the countdown number ticks smoothly.
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown(windowID: windowID) }
        }
        RunLoop.main.add(t, forMode: .common)
        run.countdownTimer = t
        runs[windowID] = run
    }

    private func tickCountdown(windowID: Int) {
        guard let run = runs[windowID],
              let state = run.hostingState,
              let target = run.nextAdvanceAt else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            advance(windowID: windowID)
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
    ///
    /// slideshow.mdx §0A + §1A + §2A — the controller re-reads
    /// `appState.selectedFile` and `appState.orderedNavigationFiles`
    /// on **every** tick. A panel-row click during a running
    /// slideshow changes `selectedFile`, and the next advance steps
    /// from the clicked file. The navigation list is the file-tree's
    /// depth-first, top-down visible order — the same list `N`, `P`,
    /// `↑`, `↓` walk — already filtered to drop excluded /
    /// inherit-excluded files (`passesFilter == false`).
    ///
    /// include_checks.mdx §10 — when walker roots exist, additionally
    /// filter through `IncludeStateController.effectiveState` so a
    /// folder-level `.exclude` override is honored even if the row's
    /// `passesFilter` flag predates the override.
    private func advance(windowID: Int) {
        let _trace = PerformanceLog.shared.start(
            "Slideshow.Advance",
            extra: [("window_id", String(windowID))]
        )
        defer { _trace.finish() }
        guard var run = runs[windowID],
              let appState = run.appState,
              let state = run.hostingState else { return }
        let ordered = appState.orderedNavigationFiles
        let walkerRoots = appState.walkerRoots
        let files: [String] = walkerRoots.isEmpty
            ? ordered
            : ordered.filter { Self.isInScope(path: $0, roots: walkerRoots) }
        let loop = appState.settings.slideshow.loop
        let interval = appState.settings.slideshow.interval_seconds

        let fromPath = appState.selectedFile ?? ""

        // §10.3 — every in-scope file got carved out. Stop with a
        // distinct reason so the audit log records the cause.
        if files.isEmpty {
            stop(windowID: windowID, reason: "no_in_scope_files", source: "")
            return
        }

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
            // §2A.5 — current selection is not in the navigation list
            // (excluded mid-run, ad-hoc dropped file, or pre-click
            // path from elsewhere). Re-enter at index 0.
            nextIdx = 0
        }

        guard let targetIdx = nextIdx else {
            // slideshow.mdx §7.7 — auto-stop at end of list, loop off.
            stop(windowID: windowID, reason: "end_of_list", source: "")
            return
        }

        let toPath = files[targetIdx]
        appState.selectedFile = toPath
        run.advanceCount += 1
        runs[windowID] = run

        // multi_window.mdx §7.1 — mirror the advance into the
        // WindowState so the next quit-time flush records the correct
        // `currentIndex` and the audit log can later prove which
        // window did the advance.
        if let windowState = WindowRegistry.shared.window(id: windowID) {
            windowState.slideshow.currentIndex = targetIdx
            windowState.slideshow.lastAdvancedAt = Date()
        }

        MCPAuditLogger.shared.logSlideshowAdvance(
            from: fromPath,
            to: toPath,
            interval: interval,
            zoomMode: zoomModeLabel(state.zoomMode),
            wrap: wrapped,
            corr: run.runCorr
        )

        // slideshow.mdx §4.7 — mid-show interval edits apply to the
        // next interval, not the current countdown. Re-read the
        // setting here so the GUI slider / text field updates take
        // effect at the next advance boundary.
        if abs(interval - state.slideshowSeconds) > 0.0001 {
            state.slideshowSeconds = interval
        }
        scheduleTick(windowID: windowID, every: state.slideshowSeconds)
    }

    /// Short label used in the audit log so a grep on `zoom_mode=fit`
    /// works. ZoomMode is a String-backed enum whose `rawValue` is
    /// already the short lowercase name (`auto`, `lock`, `width`,
    /// `height`, `fit`, `fill`).
    private func zoomModeLabel(_ mode: ZoomMode) -> String {
        mode.rawValue
    }

    /// include_checks.mdx §9.1 — a file is in scope iff it both
    /// passes the existing filter (already true for everything in
    /// `resolvedFiles`) AND its effective include state is
    /// `.include`. Used by the slideshow picker (§10) and the
    /// arrow-key navigation (§10.4).
    static func isInScope(path: String, roots: [RootDirectory]) -> Bool {
        guard let root = IncludeStateController.root(for: path, in: roots) else {
            return true
        }
        let relative = IncludePath.relative(absolutePath: path, root: root.path)
        return root.effectiveState(for: relative) == .include
    }
}

private struct SlideshowRoot: View {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState
    let windowID: Int

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
                    SlideshowController.shared.stop(
                        windowID: windowID,
                        reason: "user_toggle",
                        source: "menu:slideshow_toolbar"
                    )
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
                        SlideshowController.shared.setInterval(new, windowID: windowID)
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
