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
    private var timer: Timer?
    private var hostingState: ViewerState?
    private var appState: AppState?

    private init() {}

    func start(appState: AppState, seconds: Double) {
        stop()
        guard !appState.resolvedFiles.isEmpty else { return }

        let viewerState = ViewerState()
        viewerState.zoomMode = .fit
        viewerState.slideshowSeconds = seconds
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
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
        hostingState?.isSlideshowRunning = false
        hostingState = nil
        appState = nil
    }

    private func scheduleTick(every seconds: Double) {
        timer?.invalidate()
        guard seconds > 0 else { return }
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func advance() {
        guard let appState else { return }
        appState.selectNext(wrap: true)
    }
}

private struct SlideshowRoot: View {
    @Bindable var state: AppState
    @Bindable var viewer: ViewerState

    var body: some View {
        ImageViewer(state: state, viewer: viewer)
            .background(Color.black)
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
}
