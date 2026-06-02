import Foundation
import Observation
import AVFoundation
import AVKit
import AppKit
import CoreImage
import UniformTypeIdentifiers
import ImageGlassCore

/// Owns the `AVPlayer` for a single viewer window. Implements every
/// transport, mute, loop, rate, frame-step, and snapshot operation listed
/// in `docs/videos.mdx §3` so the menu, the canvas, and the MCP surface
/// all bind to the same observable instance.
///
/// Delegates ALL decoding to AVFoundation / VideoToolbox — the spec's
/// "use as much of the macOS developer platform as possible" mandate
/// (docs/videos.mdx §3.7 hardware decode).
@MainActor
@Observable
public final class VideoPlaybackController {

    // MARK: - Public observable state

    public private(set) var currentURL: URL?
    public private(set) var isPlaying: Bool = false
    public private(set) var isMuted: Bool = false
    public private(set) var volume: Float = 1.0
    public private(set) var rate: Float = 1.0
    public private(set) var loopOn: Bool = false
    public private(set) var duration: Double = 0
    public private(set) var currentTime: Double = 0
    public private(set) var loadError: String?
    public private(set) var isPiPActive: Bool = false

    // Last-known dimensions / codec for the MCP `video_describe` surface.
    public private(set) var pixelWidth: Int = 0
    public private(set) var pixelHeight: Int = 0
    public private(set) var nominalFrameRate: Float = 0
    public private(set) var hasAudio: Bool = false

    /// Underlying player. Exposed so `VideoCanvasView` can hand it to
    /// `AVPlayerView.player`. Recreated on every `load()` when a loop
    /// switch requires upgrading to `AVQueuePlayer`.
    public private(set) var player: AVPlayer = AVPlayer()

    // MARK: - Private state

    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var mutedObserver: NSKeyValueObservation?
    private var volumeObserver: NSKeyValueObservation?
    private var settings: VideoSettings

    public init(settings: VideoSettings = VideoSettingsStore.shared.load()) {
        self.settings = settings
        self.isMuted = settings.defaultMuted
        self.player.isMuted = settings.defaultMuted
        self.player.volume = 1.0
        self.volume = 1.0
        installPlayerObservers()
    }

    deinit {
        // AppKit / AVFoundation will tear down the player when the last
        // reference drops; we just have to detach the periodic observer.
        // Swift 6 actor isolation: `timeObserver`, `endObserver`, and
        // `player` are main-actor-isolated; reach them via a nonisolated
        // dispatch hop so deinit (which can fire on any thread) does not
        // touch isolated state directly.
        let p = unsafelyUnwrappedPlayer
        let t = unsafelyUnwrappedTimeObserver
        let e = unsafelyUnwrappedEndObserver
        if let t { p.removeTimeObserver(t) }
        if let e { NotificationCenter.default.removeObserver(e) }
    }

    /// Nonisolated mirrors so `deinit` can release the observers without
    /// crossing the actor boundary. Kept in sync by `installPlayerObservers`.
    private nonisolated(unsafe) var unsafelyUnwrappedPlayer: AVPlayer { player }
    private nonisolated(unsafe) var unsafelyUnwrappedTimeObserver: Any? { timeObserver }
    private nonisolated(unsafe) var unsafelyUnwrappedEndObserver: NSObjectProtocol? { endObserver }

    // MARK: - Load

    /// Replace the current item with the asset at `url`. Returns when the
    /// AVAsset reports `isPlayable`; throws `VideoError.unplayable` if not.
    public func load(_ url: URL) async {
        loadError = nil
        currentURL = url

        // MKV / WebM require the optional plugin (docs/videos.mdx §9).
        if VideoFormats.requiresPlugin(url), !settings.mkvSupportEnabled {
            loadError = VideoError.pluginRequired(url).errorDescription
            return
        }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        do {
            // Swift 6's async asset loading API. Available since macOS 13.
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                loadError = VideoError.unplayable(url).errorDescription
                return
            }
            let duration = try await asset.load(.duration)
            self.duration = CMTimeGetSeconds(duration).isFinite
                ? CMTimeGetSeconds(duration) : 0

            // Gather metadata for `video_describe`. Best-effort: a file
            // missing a video track still plays as audio-only.
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let first = videoTracks.first {
                let size = try await first.load(.naturalSize)
                pixelWidth = Int(size.width)
                pixelHeight = Int(size.height)
                let rate = try await first.load(.nominalFrameRate)
                nominalFrameRate = rate
            } else {
                pixelWidth = 0
                pixelHeight = 0
                nominalFrameRate = 0
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            hasAudio = !audioTracks.isEmpty
        } catch {
            loadError = VideoError.loadFailed(url, error.localizedDescription)
                .errorDescription
            ErrorLog.log("VideoPlaybackController.load",
                         error: error,
                         class: "VideoPlaybackController")
            return
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        if #available(macOS 14, *) {
            item.appliesPerFrameHDRDisplayMetadata = true
        }

        // Per-file state restore (docs/videos.mdx §5.1).
        let perFile = VideoPerFileStateStore.shared
            .get(for: AppPaths.contractTilde(url.path))
        loopOn = settings.rememberLoopPerFile ? perFile.loop : settings.defaultLoop

        rebuildPlayer(for: item)

        if settings.autoplayOnSelect {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        rate = player.rate
    }

    /// Tear down the player and free the current item. Called when the
    /// viewer switches to a non-video file (docs/videos.mdx §12 acceptance
    /// criterion 9).
    public func unload() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        rateObserver?.invalidate()
        statusObserver?.invalidate()
        mutedObserver?.invalidate()
        volumeObserver?.invalidate()
        looper = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentURL = nil
        duration = 0
        currentTime = 0
        pixelWidth = 0
        pixelHeight = 0
        nominalFrameRate = 0
        hasAudio = false
    }

    // MARK: - Transport

    public func playPauseToggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    public func play() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func stopAndRewind() {
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaying = false
        currentTime = 0
    }

    public func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let cm = CMTime(seconds: max(0, min(seconds, duration)),
                        preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Frame step. Uses `AVPlayerItem.step(byCount:)` — Apple's native API
    /// for trick-play; the player must be paused first per AVFoundation
    /// docs.
    public func step(byFrames count: Int) {
        guard let item = player.currentItem else { return }
        if isPlaying { pause() }
        item.step(byCount: count)
    }

    public func setRate(_ r: Float) {
        rate = max(0.25, min(2.0, r))
        if isPlaying {
            player.rate = rate
        } else {
            // AVPlayer.rate also unpauses — only assign when the user
            // expects playback.
            player.rate = 0
        }
    }

    // MARK: - Audio

    public func setMuted(_ muted: Bool) {
        // Use `isMuted` rather than zeroing `volume` so the unmute restore
        // preserves the slider position (docs/videos.mdx §5.3).
        player.isMuted = muted
        isMuted = muted
    }

    public func toggleMuted() { setMuted(!isMuted) }

    public func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        player.volume = clamped
        volume = clamped
    }

    public func nudgeVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    // MARK: - Loop

    public func setLoop(_ on: Bool) {
        guard loopOn != on else { return }
        loopOn = on
        // The looper / queue-player swap happens inside rebuildPlayer for
        // simplicity — we re-attach with the current item.
        if let item = player.currentItem {
            rebuildPlayer(for: item.copy() as! AVPlayerItem)
            player.play()
            isPlaying = true
        }
        persistPerFileState()
    }

    public func toggleLoop() { setLoop(!loopOn) }

    // MARK: - Snapshot

    /// Synchronously rasterize the current frame to a CGImage. Uses
    /// `AVAssetImageGenerator` — Apple's recommended path that honors
    /// `preferredTrackTransform` (Live Photo / rotated content).
    public func snapshotCurrentFrame() async throws -> CGImage {
        guard let url = currentURL else {
            throw VideoError.noActiveItem
        }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cmTime = player.currentTime()
        do {
            if #available(macOS 13, *) {
                let result = try await gen.image(at: cmTime)
                return result.image
            } else {
                var actual = CMTime.zero
                let cg = try gen.copyCGImage(at: cmTime, actualTime: &actual)
                return cg
            }
        } catch {
            throw VideoError.snapshotFailed(url, error.localizedDescription)
        }
    }

    // MARK: - Picture in Picture

    /// PiP is owned by the canvas's `AVPlayerView` — this setter records
    /// state and is called back by the canvas's PiP delegate.
    public func setPiPActive(_ active: Bool) {
        isPiPActive = active
    }

    // MARK: - Persistence

    private func persistPerFileState() {
        guard let url = currentURL, settings.rememberLoopPerFile else { return }
        let state = VideoPerFileState(
            loop: loopOn,
            muted: isMuted,
            rate: Double(rate)
        )
        VideoPerFileStateStore.shared
            .set(state, for: AppPaths.contractTilde(url.path))
    }

    // MARK: - Player rebuild (handles loop on/off)

    /// Build the right kind of player for the current loop preference.
    /// When loop is off we use a plain `AVPlayer`; when loop is on we use
    /// `AVQueuePlayer` + `AVPlayerLooper`, which is Apple's official path
    /// for gapless looping (no end-of-track black flash).
    private func rebuildPlayer(for item: AVPlayerItem) {
        // Detach old observers — they were attached to the previous player.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        rateObserver?.invalidate()
        statusObserver?.invalidate()
        mutedObserver?.invalidate()
        volumeObserver?.invalidate()
        looper = nil

        let oldMuted = isMuted
        let oldVolume = volume

        if loopOn {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            player = AVPlayer(playerItem: item)
        }

        player.isMuted = oldMuted
        player.volume = oldVolume
        installPlayerObservers()
    }

    private func installPlayerObservers() {
        // 10 Hz periodic time observer drives the scrubber / overlay.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(t).isFinite
                ? CMTimeGetSeconds(t) : 0
        }

        // End-of-item handler. Only meaningful when loop is off; when loop
        // is on AVPlayerLooper handles the restart.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.loopOn {
                    self.isPlaying = false
                }
            }
        }

        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self, let r = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = r != 0
                if r != 0 { self.rate = r }
            }
        }
        mutedObserver = player.observe(\.isMuted, options: [.new]) { [weak self] _, change in
            guard let self, let m = change.newValue else { return }
            Task { @MainActor [weak self] in self?.isMuted = m }
        }
        volumeObserver = player.observe(\.volume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue else { return }
            Task { @MainActor [weak self] in self?.volume = v }
        }
    }
}
