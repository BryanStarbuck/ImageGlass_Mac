import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageGlassCore

/// SwiftUI view that takes ownership of one selected video URL, drives the
/// shared `VideoPlaybackController`, and hosts the native AVKit player.
///
/// The actual player chrome — floating transport bar, time / scrubber,
/// fullscreen toggle, Picture-in-Picture, AirPlay — is delivered by
/// `AVPlayerView` from AVKit. The spec mandate to "use as much of the
/// macOS developer platform as possible" is satisfied by *not* writing
/// our own transport bar.
public struct VideoCanvasView: View {
    @Bindable var state: AppState
    @Bindable var controller: VideoPlaybackController
    let path: String

    public init(state: AppState,
                controller: VideoPlaybackController,
                path: String) {
        self.state = state
        self.controller = controller
        self.path = path
    }

    public var body: some View {
        ZStack {
            if let err = controller.loadError {
                ContentUnavailableView {
                    Label("Video preview unavailable",
                          systemImage: "video.slash")
                } description: {
                    Text(err)
                }
            } else {
                AVPlayerViewRepresentable(controller: controller)
            }
        }
        .background(Color.black)
        .onAppear {
            Task { @MainActor in
                await controller.load(URL(fileURLWithPath:
                    AppPaths.expandTilde(path)))
            }
        }
        .onChange(of: path) { _, newPath in
            Task { @MainActor in
                await controller.load(URL(fileURLWithPath:
                    AppPaths.expandTilde(newPath)))
            }
        }
        .onDisappear {
            controller.unload()
        }
        .focusable()
        .focusEffectDisabled()
        // Spacebar = Play / Pause (videos.mdx §1.2 + §11.2). When focus is
        // on the Directory Panel the parent ImageViewer's onKeyPress chain
        // wins instead.
        .onKeyPress(.space) {
            controller.playPauseToggle()
            return .handled
        }
        .onKeyPress("m") {
            controller.toggleMuted()
            return .handled
        }
        .onKeyPress("l") {
            controller.toggleLoop()
            return .handled
        }
        .onKeyPress("j") {
            controller.setRate(0.5)
            return .handled
        }
        .onKeyPress("k") {
            controller.setRate(1.0)
            return .handled
        }
        .onKeyPress("s") {
            saveSnapshot()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleArrow(.right)
        }
        .onKeyPress(.leftArrow) {
            handleArrow(.left)
        }
        .onKeyPress(.upArrow) {
            controller.nudgeVolume(by: 0.05)
            return .handled
        }
        .onKeyPress(.downArrow) {
            controller.nudgeVolume(by: -0.05)
            return .handled
        }
    }

    // MARK: - Snapshot

    private func saveSnapshot() {
        Task { @MainActor in
            do {
                let img = try await controller.snapshotCurrentFrame()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png, .jpeg, .tiff]
                let base = (path as NSString).lastPathComponent
                let stamp = Int(controller.currentTime * 1000)
                panel.nameFieldStringValue = "\(base)-frame-\(stamp).png"
                if panel.runModal() == .OK, let dest = panel.url {
                    let rep = NSBitmapImageRep(cgImage: img)
                    let data = rep.representation(using: .png, properties: [:])
                    try? data?.write(to: dest)
                }
            } catch {
                ErrorLog.log("video snapshot failed",
                             error: error,
                             class: "VideoCanvasView")
            }
        }
    }

    private enum Arrow { case left, right }
    private func handleArrow(_ a: Arrow) -> KeyPress.Result {
        let mods = NSEvent.modifierFlags
        let shift = mods.contains(.shift)
        let opt = mods.contains(.option)
        let signed: Double = (a == .right) ? 1 : -1
        if opt {
            controller.skip(by: signed * 30); return .handled
        }
        if shift {
            controller.skip(by: signed * 5); return .handled
        }
        controller.step(byFrames: Int(signed))
        return .handled
    }
}

// MARK: - AVKit AVPlayerView bridge

/// Hosts the AppKit-native `AVPlayerView`. We deliberately use
/// `AVPlayerView` (AppKit) and not SwiftUI's `VideoPlayer` because the
/// AppKit control ships the floating transport, fullscreen toggle, PiP
/// affordance, and AirPlay button out of the box (docs/videos.mdx §3.1).
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    @Bindable var controller: VideoPlaybackController

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        if #available(macOS 13, *) {
            v.showsTimecodes = true
        }
        v.videoGravity = .resizeAspect
        v.player = controller.player
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        // The player reference can change when loop is toggled (we swap
        // AVPlayer ↔ AVQueuePlayer inside the controller).
        if v.player !== controller.player {
            v.player = controller.player
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, AVPlayerViewDelegate, @unchecked Sendable {
        let controller: VideoPlaybackController
        init(controller: VideoPlaybackController) {
            self.controller = controller
        }

        func playerViewWillStartPictureInPicture(_ playerView: AVPlayerView) {
            Task { @MainActor in self.controller.setPiPActive(true) }
        }

        func playerViewDidStopPictureInPicture(_ playerView: AVPlayerView) {
            Task { @MainActor in self.controller.setPiPActive(false) }
        }
    }
}
