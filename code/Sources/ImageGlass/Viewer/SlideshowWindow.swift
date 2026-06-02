import AppKit
import SwiftUI
import ImageGlassCore

/// A separate window that walks through `state.resolvedFiles` on a timer.
/// The viewer state inside the slideshow is independent (its own zoom + view
/// settings) so toggling things doesn't disturb the main window.
@MainActor
final class SlideshowController {
    static let shared = SlideshowController()

    private var window: NSWindow?
    private var countdownTimer: Timer?
    private var hostingState: ViewerState?
    private var appState: AppState?
    private var nextAdvanceAt: Date?

    private init() {}

    func start(appState: AppState, seconds: Double) {
        stop()
        guard !appState.resolvedFiles.isEmpty else { return }

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

        scheduleTick(every: seconds)
    }

    func setInterval(_ seconds: Double) {
        hostingState?.slideshowSeconds = seconds
        if window != nil { scheduleTick(every: seconds) }
    }

    func stop() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        nextAdvanceAt = nil
        window?.close()
        window = nil
        hostingState?.isSlideshowRunning = false
        hostingState?.slideshowRemaining = 0
        hostingState = nil
        appState = nil
    }

    /// Re-arm the countdown for a full `seconds` interval. Used after each
    /// advance and when the user dials a new interval.
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

    private func advance() {
        guard let appState, let state = hostingState else { return }
        appState.selectNext(wrap: true)
        scheduleTick(every: state.slideshowSeconds)
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
