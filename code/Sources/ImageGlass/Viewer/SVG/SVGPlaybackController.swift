import Foundation
import Observation
import AppKit
import WebKit
import ImageGlassCore

/// Background fill applied behind the rendered SVG.
public enum SVGBackground: String, CaseIterable, Sendable {
    case transparent, white, black, checker

    var cssValue: String {
        switch self {
        case .transparent: return "transparent"
        case .white:       return "#ffffff"
        case .black:       return "#000000"
        case .checker:     return "var(--ig-checker)"
        }
    }
}

/// Drives the SVG viewer canvas. Holds the canonical playback / zoom state
/// for the active SVG; the canvas reads its observable fields. All actual
/// rendering is delegated to **WebKit** (animated path) or **NSImage /
/// SVGImageRep via Image I/O** (static fast-path) per `docs/svg.mdx §2.2`.
///
/// Transport control is implemented through the SVG SMIL DOM API
/// (`SVGSVGElement.pauseAnimations()` / `unpauseAnimations()` /
/// `setCurrentTime()`) reached via `WKWebView.evaluateJavaScript`. WebKit
/// honors those DOM calls even when page-level scripting is disabled,
/// which is how we play / pause animated SVGs without ever turning on JS
/// for the document itself (docs/svg.mdx §3.3).
@MainActor
@Observable
public final class SVGPlaybackController {

    // MARK: - Observable state

    public private(set) var currentURL: URL?
    public private(set) var kind: SVGKind = .static
    public private(set) var isPlaying: Bool = true
    public private(set) var loopOn: Bool = false
    public private(set) var rate: Double = 1.0
    public private(set) var zoom: Double = 1.0
    public private(set) var pan: CGSize = .zero
    public private(set) var viewBox: CGRect?
    public private(set) var allowScripts: Bool = false
    public var background: SVGBackground = .transparent
    public var showViewBoxOutline: Bool = false
    public private(set) var hasScripts: Bool = false
    public private(set) var loadError: String?

    /// Set by `SVGCanvasView` once a `WKWebView` is attached so the
    /// controller can dispatch transport calls. nil for static SVGs that
    /// use the NSImage fast-path renderer.
    public weak var webView: WKWebView?

    private var settings: SVGSettings
    private var currentData: Data?

    public init(settings: SVGSettings = SVGSettingsStore.shared.load()) {
        self.settings = settings
        self.background = SVGBackground(rawValue: settings.background) ?? .transparent
        self.showViewBoxOutline = settings.showViewBoxOutlineByDefault
        self.rate = settings.defaultRate
        self.loopOn = settings.defaultLoop
        self.allowScripts = settings.allowScriptsDefault
    }

    // MARK: - Load

    /// Inspect the file, classify it, and prepare a fresh render.
    /// Returns the HTML wrapper to load into the WebKit renderer for
    /// animated SVGs, or nil for static SVGs that take the NSImage path.
    public func load(_ url: URL) -> SVGRenderPlan {
        loadError = nil
        currentURL = url

        // Pre-flight: catch Git LFS pointers, iCloud / Dropbox placeholders,
        // broken symlinks, and permission issues with a user-actionable
        // message instead of rendering a tiny text file as an empty SVG.
        let pre = LoadDiagnostics.diagnose(url: url)
        if pre != .ok {
            loadError = pre.userMessage
            ErrorLog.log("SVG preflight rejected [\(pre.tag)] \(url.path)",
                         class: "SVGPlaybackController")
            LoadDiagnostics.requestDownloadIfPossible(url: url)
            currentData = nil
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Fall back through the same diagnoser so iCloud / Dropbox
            // placeholders that raced past the pre-check still produce
            // the right message.
            let post = LoadDiagnostics.diagnoseAfterDecodeFailure(
                url: url,
                decoderHint: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            loadError = post.userMessage
            ErrorLog.log("SVG load failed [\(post.tag)]", error: error,
                         class: "SVGPlaybackController")
            currentData = nil
            return .empty
        }
        currentData = data

        // Detect static vs. animated.
        let detected = SVGDetection.detectKind(data: data)
        kind = detected
        hasScripts = SVGDetection.containsScript(data)

        // ViewBox for "Zoom to ViewBox".
        if let s = String(data: data, encoding: .utf8) {
            viewBox = SVGDetection.viewBox(in: s)
        } else {
            viewBox = nil
        }

        // Restore per-file state (loop, allowScripts, rate).
        let perFile = SVGPerFileStateStore.shared
            .get(for: AppPaths.contractTilde(url.path))
        loopOn = settings.rememberLoopPerFile ? perFile.loop : settings.defaultLoop
        rate = perFile.rate > 0 ? perFile.rate : settings.defaultRate
        allowScripts = perFile.allowScripts || settings.allowScriptsDefault

        // Reset transient state.
        zoom = 1.0
        pan = .zero
        isPlaying = settings.autoplayOnSelect

        // Static fast-path?
        let smallEnough = data.count < 256 * 1024
        let canUseStaticPath =
            !settings.alwaysUseWebKit &&
            settings.useFastStaticPathWhenSafe &&
            detected == .static &&
            smallEnough

        if canUseStaticPath {
            return .static(url: url, data: data)
        }

        // Animated path — build the sandboxed HTML wrapper.
        let html = SVGHTMLWrapper.wrap(
            svgString: String(data: data, encoding: .utf8) ?? "",
            allowScripts: allowScripts,
            background: background,
            showViewBoxOutline: showViewBoxOutline
        )
        return .animated(html: html, baseURL: url.deletingLastPathComponent())
    }

    // MARK: - Transport

    public func playPauseToggle() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard kind == .animated else { return }
        isPlaying = true
        runJS("""
        (function(){
          try { document.documentElement.unpauseAnimations(); } catch(e){}
          if (window.ig_setRate) ig_setRate(\(rate));
        })();
        """)
    }

    public func pause() {
        guard kind == .animated else { return }
        isPlaying = false
        runJS("""
        (function(){
          try { document.documentElement.pauseAnimations(); } catch(e){}
        })();
        """)
    }

    public func stopAndRewind() {
        runJS("""
        (function(){
          try {
            document.documentElement.setCurrentTime(0);
            document.documentElement.pauseAnimations();
          } catch(e){}
        })();
        """)
        isPlaying = false
    }

    public func setLoop(_ on: Bool) {
        loopOn = on
        persistPerFileState()
    }

    public func toggleLoop() { setLoop(!loopOn) }

    public func setRate(_ r: Double) {
        rate = max(0.25, min(2.0, r))
        runJS("if (window.ig_setRate) ig_setRate(\(rate));")
        persistPerFileState()
    }

    // MARK: - Zoom / pan

    public func setZoom(_ z: Double) {
        zoom = max(0.05, min(32, z))
        webView?.pageZoom = CGFloat(zoom)
    }

    public func zoomIn() { setZoom(zoom * 1.25) }
    public func zoomOut() { setZoom(zoom / 1.25) }

    public func resetZoom() {
        setZoom(1.0)
        pan = .zero
    }

    public func fitZoom() {
        guard let vb = viewBox, let wv = webView else {
            setZoom(1.0); return
        }
        let bounds = wv.bounds.size
        guard bounds.width > 0, bounds.height > 0,
              vb.width > 0, vb.height > 0 else {
            setZoom(1.0); return
        }
        let z = min(bounds.width / vb.width, bounds.height / vb.height)
        setZoom(Double(z))
    }

    public func fillZoom() {
        guard let vb = viewBox, let wv = webView else {
            setZoom(1.0); return
        }
        let bounds = wv.bounds.size
        guard bounds.width > 0, bounds.height > 0,
              vb.width > 0, vb.height > 0 else {
            setZoom(1.0); return
        }
        let z = max(bounds.width / vb.width, bounds.height / vb.height)
        setZoom(Double(z))
    }

    public func zoomToViewBox() {
        guard viewBox != nil else { resetZoom(); return }
        setZoom(1.0)
        runJS("""
        (function(){
          try {
            var svg = document.querySelector('svg');
            if (svg && svg.viewBox && svg.viewBox.baseVal) {
              var vb = svg.viewBox.baseVal;
              svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
              svg.style.width = '100%';
              svg.style.height = '100%';
            }
          } catch(e){}
        })();
        """)
    }

    // MARK: - Background / overlay toggles

    public func setBackground(_ b: SVGBackground) {
        background = b
        runJS("if (window.ig_setBackground) ig_setBackground('\(b.cssValue)');")
    }

    public func toggleViewBoxOutline() {
        showViewBoxOutline.toggle()
        runJS("if (window.ig_setViewBoxOutline) ig_setViewBoxOutline(\(showViewBoxOutline ? "true" : "false"));")
    }

    // MARK: - Scripts (security-sensitive)

    /// Toggle per-file script execution. Triggers a one-time confirmation
    /// banner the first time it is enabled per `docs/svg.mdx §3.1`.
    /// `confirmed` must be true to grant the permission — callers gate
    /// this behind a `confirm` sheet on first toggle.
    public func setAllowScripts(_ allow: Bool, confirmed: Bool) {
        guard !allow || confirmed else { return }
        allowScripts = allow
        persistPerFileState()
    }

    // MARK: - Snapshot

    /// Rasterize the current view to a CGImage via the system's preferred
    /// path:
    ///   * animated → `WKWebView.takeSnapshot(with:)` (Apple-supplied),
    ///   * static   → `NSImage(contentsOf:)` rendered into a `CGContext`.
    public func snapshotCurrentFrame(width: Int? = nil,
                                     completion: @escaping (CGImage?) -> Void) {
        if kind == .animated, let wv = webView {
            let cfg = WKSnapshotConfiguration()
            if let w = width {
                cfg.snapshotWidth = NSNumber(value: w)
            }
            wv.takeSnapshot(with: cfg) { image, error in
                if let error {
                    ErrorLog.log("SVG WKWebView snapshot failed", error: error,
                                 class: "SVGPlaybackController")
                }
                let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                completion(cg)
            }
            return
        }
        guard let url = currentURL,
              let img = NSImage(contentsOf: url) else {
            completion(nil); return
        }
        let size = img.size
        let w = width.map { CGFloat($0) } ?? size.width
        let scale = size.width > 0 ? w / size.width : 1.0
        let outW = Int((size.width * scale).rounded())
        let outH = Int((size.height * scale).rounded())
        guard outW > 0, outH > 0 else { completion(nil); return }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { completion(nil); return }
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = g
        img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))
        NSGraphicsContext.restoreGraphicsState()
        completion(ctx.makeImage())
    }

    // MARK: - Persistence

    private func persistPerFileState() {
        guard let url = currentURL, settings.rememberLoopPerFile else { return }
        let state = SVGPerFileState(loop: loopOn,
                                    rate: rate,
                                    allowScripts: allowScripts)
        SVGPerFileStateStore.shared
            .set(state, for: AppPaths.contractTilde(url.path))
    }

    // MARK: - JS dispatch

    private func runJS(_ js: String) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(js) { _, error in
            if let error {
                ErrorLog.log("SVG evaluateJavaScript failed",
                             error: error,
                             class: "SVGPlaybackController")
            }
        }
    }
}

/// The renderer plan returned by `SVGPlaybackController.load`. The canvas
/// view dispatches on this enum to pick between WebKit and NSImage.
public enum SVGRenderPlan: Sendable {
    case empty
    case animated(html: String, baseURL: URL)
    case `static`(url: URL, data: Data)
}

/// HTML wrapper for the animated path. The wrapper is small, deterministic,
/// and CSP-locked-down per `docs/svg.mdx §3.2`.
public enum SVGHTMLWrapper {

    public static func wrap(svgString: String,
                            allowScripts: Bool,
                            background: SVGBackground,
                            showViewBoxOutline: Bool) -> String {
        // When scripts are NOT allowed, strip any `<script>` block from
        // the SVG before injecting it — CSP would block them at runtime
        // but defense-in-depth removes them up-front.
        let svgBody = allowScripts
            ? svgString
            : stripScriptElements(svgString)

        let scriptCSP = allowScripts ? "'unsafe-inline'" : "'none'"

        let injected = SVGHTMLWrapper.injectedTransportScript

        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\
        default-src 'none'; \
        img-src data:; \
        style-src 'unsafe-inline'; \
        script-src \(scriptCSP); \
        connect-src 'none'; \
        ">
        <style>
          :root {
            --ig-checker: repeating-conic-gradient(#cccccc 0% 25%, #ffffff 0% 50%) 50% / 20px 20px;
          }
          html, body {
            margin: 0; padding: 0;
            background: \(background.cssValue);
            overflow: hidden;
            width: 100%; height: 100%;
          }
          svg {
            width: 100%; height: 100%;
            display: block;
          }
          .ig-viewbox-outline svg {
            outline: 1px dashed rgba(255, 0, 0, 0.5);
            outline-offset: -1px;
          }
        </style>
        </head>
        <body class="\(showViewBoxOutline ? "ig-viewbox-outline" : "")">
        \(svgBody)
        \(allowScripts ? "<script>\(injected)</script>" : "")
        </body></html>
        """
    }

    /// Injected only when JS is enabled — provides the `ig_setRate`,
    /// `ig_setBackground`, `ig_setViewBoxOutline` helpers the controller
    /// calls through `evaluateJavaScript`.
    private static let injectedTransportScript = """
    (function(){
      window.ig_setRate = function(r) {
        try {
          var svg = document.documentElement;
          if (svg && svg.setCurrentTime) {
            // SMIL animations honor a CSS multiplier via tick-stepping.
            if (window.__igRateInterval) clearInterval(window.__igRateInterval);
            var last = performance.now();
            window.__igRateInterval = setInterval(function(){
              var now = performance.now();
              var dt = (now - last) / 1000;
              last = now;
              try {
                var t = svg.getCurrentTime() + dt * (r - 1);
                svg.setCurrentTime(t);
              } catch(e){}
            }, 16);
          }
          // CSS animations: set animation-duration multiplier.
          document.documentElement.style.setProperty('animation-duration-scale', String(1.0 / r));
        } catch(e){}
      };
      window.ig_setBackground = function(css) {
        try { document.body.style.background = css; } catch(e){}
      };
      window.ig_setViewBoxOutline = function(on) {
        try {
          if (on) document.body.classList.add('ig-viewbox-outline');
          else document.body.classList.remove('ig-viewbox-outline');
        } catch(e){}
      };
    })();
    """

    /// Remove every `<script>...</script>` block. Case-insensitive,
    /// handles self-closing tags. Defensive: keep at top of file so any
    /// reviewer can see the redaction rule on its own.
    public static func stripScriptElements(_ s: String) -> String {
        var out = s
        // Loop until no more script tags remain.
        while let openRange = out.range(
                of: "<script",
                options: [.caseInsensitive]) {
            let after = out[openRange.upperBound...]
            // Find either the close `</script>` or a self-closing `/>`.
            let closeIdx: String.Index?
            if let close = after.range(
                of: "</script>",
                options: [.caseInsensitive]) {
                closeIdx = close.upperBound
            } else if let selfClose = after.range(of: "/>") {
                closeIdx = selfClose.upperBound
            } else {
                // Malformed — strip everything from `<script` onward.
                closeIdx = nil
            }
            if let end = closeIdx {
                out.removeSubrange(openRange.lowerBound..<end)
            } else {
                out.removeSubrange(openRange.lowerBound..<out.endIndex)
                break
            }
        }
        return out
    }
}
