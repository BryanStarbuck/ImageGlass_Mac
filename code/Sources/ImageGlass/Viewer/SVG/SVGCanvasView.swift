import SwiftUI
import AppKit
import WebKit
import ImageGlassCore

/// SwiftUI view that hosts the SVG renderer. Dispatches between the
/// animated (WKWebView) and static (NSImage) paths chosen by
/// `SVGPlaybackController.load`.
///
/// The static path uses **`NSImage` + `SVGImageRep`** — Apple's public
/// SVG-to-bitmap pipeline added in macOS 13 and exercised by Quick Look
/// internally. The animated path uses **WKWebView** — the same engine
/// Safari uses — wrapped in a sandboxed HTML shell (docs/svg.mdx §3).
public struct SVGCanvasView: View {
    @Bindable var state: AppState
    @Bindable var controller: SVGPlaybackController
    let path: String

    @State private var plan: SVGRenderPlan = .empty

    public init(state: AppState,
                controller: SVGPlaybackController,
                path: String) {
        self.state = state
        self.controller = controller
        self.path = path
    }

    public var body: some View {
        ZStack {
            if let err = controller.loadError {
                ContentUnavailableView {
                    Label("SVG preview unavailable",
                          systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else {
                switch plan {
                case .empty:
                    Color.clear
                case .animated(let html, let baseURL):
                    SVGWebView(html: html,
                               baseURL: baseURL,
                               controller: controller)
                case .static(let url, _):
                    SVGStaticView(url: url, controller: controller)
                }
            }
        }
        .background(backgroundView)
        .onAppear { reload() }
        .onChange(of: path) { _, _ in reload() }
        .focusable()
        .focusEffectDisabled()
        // Spacebar = Play / Pause (svg.mdx §4 + §10.2).
        .onKeyPress(.space) {
            controller.playPauseToggle()
            return .handled
        }
        .onKeyPress("l") {
            controller.toggleLoop()
            return .handled
        }
        .onKeyPress("s") {
            saveSnapshot()
            return .handled
        }
        .onKeyPress(.escape) {
            controller.resetZoom()
            return .handled
        }
    }

    private var backgroundView: some View {
        switch controller.background {
        case .transparent: return AnyView(Color.clear)
        case .white:       return AnyView(Color.white)
        case .black:       return AnyView(Color.black)
        case .checker:     return AnyView(CheckerboardBackground())
        }
    }

    private func reload() {
        let _trace = PerformanceLog.shared.start(
            "SVG.Render",
            extra: [("path", path)]
        )
        defer { _trace.finish() }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        plan = controller.load(url)
    }

    private func saveSnapshot() {
        controller.snapshotCurrentFrame { cg in
            guard let cg else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            let base = (path as NSString).lastPathComponent
            panel.nameFieldStringValue = "\(base).png"
            if panel.runModal() == .OK, let dest = panel.url {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dest)
                }
            }
        }
    }
}

// MARK: - WKWebView host (animated path)

private struct SVGWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    @Bindable var controller: SVGPlaybackController

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Sandbox lockdown (docs/svg.mdx §3.8).
        config.websiteDataStore = .nonPersistent()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = controller.allowScripts
        config.defaultWebpagePreferences = prefs
        if #available(macOS 14, *) {
            config.allowsInlinePredictions = false
        }
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        // Wait until layout has a non-zero size before loading — the SVG
        // viewport-percentage CSS depends on it.
        wv.loadHTMLString(html, baseURL: baseURL)
        // Hand the web view to the controller so it can dispatch
        // transport / zoom commands.
        Task { @MainActor in
            controller.webView = wv
            wv.pageZoom = CGFloat(controller.zoom)
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // Replace contents whenever the HTML changes (load() rewraps).
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(html, baseURL: baseURL)
        }
        wv.pageZoom = CGFloat(controller.zoom)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let controller: SVGPlaybackController
        var lastHTML: String = ""

        init(controller: SVGPlaybackController) {
            self.controller = controller
        }

        // Forbid any navigation away from our HTML shell (docs/svg.mdx
        // §3.8). The initial `loadHTMLString` arrives as `.other`; any
        // subsequent navigation request is cancelled.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        // No new windows.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil
        }

        // After load finishes, pause if the controller is in pause state.
        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                if controller.isPlaying {
                    controller.play()
                } else {
                    controller.pause()
                }
                if controller.rate != 1.0 {
                    controller.setRate(controller.rate)
                }
            }
        }
    }
}

// MARK: - NSImage host (static fast-path)

private struct SVGStaticView: NSViewRepresentable {
    let url: URL
    @Bindable var controller: SVGPlaybackController

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image == nil || v.toolTip != url.path {
            v.image = NSImage(contentsOf: url)
            v.toolTip = url.path
        }
        // CGAffineTransform on the layer gives us a cheap zoom for the
        // static path. The vector source is re-rendered by AppKit at any
        // scale so quality stays crisp.
        v.wantsLayer = true
        v.layer?.contentsGravity = .resizeAspect
        v.layer?.setAffineTransform(
            CGAffineTransform(scaleX: CGFloat(controller.zoom),
                              y: CGFloat(controller.zoom))
        )
    }
}

// MARK: - Checkerboard background

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let tile: CGFloat = 16
            for y in stride(from: 0, to: size.height, by: tile) {
                for x in stride(from: 0, to: size.width, by: tile) {
                    let dark = (Int(x / tile) + Int(y / tile)) % 2 == 0
                    let c: Color = dark ? .gray.opacity(0.4) : .gray.opacity(0.15)
                    ctx.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                             with: .color(c))
                }
            }
        }
    }
}
