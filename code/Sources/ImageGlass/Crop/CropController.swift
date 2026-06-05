import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImageGlassCore

/// Window-scoped controller for the crop tool (`docs/crop.mdx §5.1`).
///
/// Owns the live crop rectangle (in image pixel coordinates), the panel's
/// numeric / preset bindings, the keyboard nudge implementations, and
/// the four save paths (Crop, Save, Save As, Copy).
///
/// Observable so the SwiftUI panel rebinds whenever the rect or any
/// option changes. The overlay reads `rect` and `gridMode` directly.
@MainActor
@Observable
public final class CropController {

    // MARK: - Selection state

    /// Selection in image-pixel coordinates. `nil` when no rect drawn yet.
    public var rect: CGRect?

    public var aspectRatio: SelectionAspectRatio = .freeRatio
    public var aspectRatioValues: [Int] = [0, 0]
    public var lockAspect: Bool = false

    public var unitsDisplay: CropUnits = .pixels
    public var gridMode: CropGridMode = .thirds
    public var snapToGrid: Bool = true

    public var outputFormat: CropOutputFormat = .auto
    public var outputQuality: Int = 90
    public var preferLossless: Bool = true
    public var preserveMetadata: Bool = true
    public var stripGPS: Bool = false

    public var persistent: Bool = false

    /// True iff the tool is "open" (panel shown, overlay drawing).
    public var isActive: Bool = false

    /// Cached size of the active image. Updated by `bind(activeImage:path:)`.
    public var activeImageSize: CGSize = .zero
    public var activeImagePath: String?

    /// Last-applied selection across the session (for
    /// `useLastSelection` initial-selection policy).
    public var lastSelection: CGRect?

    /// Drag state machine — read by the overlay view to set cursors.
    public var dragState: CropDragState = .idle
    /// Which handle is currently being dragged (when `dragState == .resizing`).
    public var activeHandle: CropHandle?
    /// Click-origin in image coords for a fresh draw drag.
    public var drawAnchor: CGPoint?
    /// Offset (image coords) of the click within the rect for a move drag.
    public var moveAnchor: CGPoint?

    /// Initial-selection policy. Mirrored from settings on `open()`.
    public var initSelectionType: CropInitSelectionType = .select50Percent
    public var initCustomRect: CGRect?
    public var autoCenter: Bool = true

    /// Bridge that exposes the live selection to the in-process MCP
    /// `get_crop_selection` / `set_crop_selection` tools.
    private let session: CropSession

    public init(session: CropSession = .shared) {
        self.session = session
    }

    // MARK: - Lifecycle

    /// Open the crop tool, computing the initial rect per
    /// `initSelectionType`.
    public func open() {
        isActive = true
        let init0 = CropMath.initialRect(
            for: initSelectionType,
            imageSize: activeImageSize,
            customRect: initCustomRect,
            autoCenter: autoCenter,
            lastSelection: lastSelection
        )
        setRect(init0, syncSession: true)
        session.setAspectRatio(aspectRatio)
    }

    /// Close the crop tool, clearing the overlay and panel state.
    public func cancel() {
        isActive = false
        setRect(nil, syncSession: true)
        dragState = .idle
    }

    /// Image switched (Next/Previous or panel selection change).
    public func bind(activeImage cgImage: CGImage?, path: String?) {
        activeImagePath = path
        session.setImagePath(path)
        if let img = cgImage {
            activeImageSize = CGSize(width: img.width, height: img.height)
        } else if let path,
                  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            activeImageSize = CGSize(width: w, height: h)
        } else {
            activeImageSize = .zero
        }
        guard isActive else { return }
        if persistent, let r = rect {
            setRect(CropMath.clip(r, to: activeImageSize), syncSession: true)
        } else {
            // Spec §2.7: non-persistent → clear selection; tool stays open.
            setRect(nil, syncSession: true)
        }
    }

    // MARK: - Rect mutation

    /// Centralized setter so we can keep `CropSession` in sync.
    public func setRect(_ r: CGRect?, syncSession: Bool = true) {
        rect = r
        if syncSession { session.setRect(r) }
    }

    /// Consume any pending selection that an MCP client proposed.
    /// The viewer calls this from its run-loop tick.
    public func consumePendingFromMCP() {
        guard let pending = session.consumePending() else { return }
        if !isActive { open() }
        if let a = pending.aspectRatio {
            aspectRatio = a
            session.setAspectRatio(a)
        }
        setRect(CropMath.clip(pending.rect, to: activeImageSize), syncSession: true)
    }

    /// The (w, h) aspect components used for the current selection,
    /// or nil if free. Honors `lockAspect`.
    public var effectiveAspect: (w: CGFloat, h: CGFloat)? {
        guard lockAspect || aspectRatio != .freeRatio else { return nil }
        return CropMath.ratioComponents(
            for: aspectRatio == .freeRatio ? .ratio1_1 : aspectRatio,
            imageSize: activeImageSize,
            customW: aspectRatioValues[0],
            customH: aspectRatioValues[1]
        )
    }

    /// Aspect for a drag, taking transient Shift into account.
    public func dragAspect(shift: Bool) -> (w: CGFloat, h: CGFloat)? {
        if lockAspect, let a = effectiveAspect { return a }
        if shift {
            if let a = CropMath.ratioComponents(
                for: aspectRatio == .freeRatio ? .ratio1_1 : aspectRatio,
                imageSize: activeImageSize,
                customW: aspectRatioValues[0],
                customH: aspectRatioValues[1]
            ) {
                return a
            }
            return (1, 1)
        }
        if aspectRatio != .freeRatio, let a = effectiveAspect { return a }
        return nil
    }

    // MARK: - Keyboard

    public func nudge(dx: CGFloat, dy: CGFloat) {
        guard let r = rect else { return }
        setRect(CropMath.nudge(rect: r, dx: dx, dy: dy, imageSize: activeImageSize))
    }

    public func grow(dw: CGFloat, dh: CGFloat) {
        guard let r = rect else { return }
        setRect(CropMath.grow(rect: r, dw: dw, dh: dh, imageSize: activeImageSize))
    }

    public func cycleGrid() { gridMode = gridMode.next }

    public func resetSelection() {
        let init0 = CropMath.initialRect(
            for: initSelectionType,
            imageSize: activeImageSize,
            customRect: initCustomRect,
            autoCenter: autoCenter,
            lastSelection: lastSelection
        )
        setRect(init0)
    }

    // MARK: - Output

    public enum CropError: Error, LocalizedError {
        case noSelection
        case noActiveImage
        case unsupportedSource

        public var errorDescription: String? {
            switch self {
            case .noSelection: return "There is no crop selection."
            case .noActiveImage: return "There is no active image to crop."
            case .unsupportedSource: return "The current image cannot be cropped."
            }
        }
    }

    /// In-app replace. Returns the cropped CGImage so the viewer can
    /// swap its source. The caller is responsible for pushing onto the
    /// window's `UndoManager`.
    public func applyAndReplace() throws -> CGImage {
        let _trace = PerformanceLog.shared.start(
            "Crop.Apply",
            extra: [("mode", "replace")]
        )
        defer { _trace.finish() }
        guard var r = rect else { throw CropError.noSelection }
        guard let path = activeImagePath else { throw CropError.noActiveImage }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CropError.unsupportedSource
        }
        r = CropMath.clip(snapToGrid ? CropMath.snapToIntegerPixels(r) : r, to: activeImageSize)
        guard let cropped = cg.cropping(to: r) else { throw CropError.unsupportedSource }
        lastSelection = r
        return cropped
    }

    @discardableResult
    public func applySaveInPlace() throws -> URL {
        let _trace = PerformanceLog.shared.start(
            "Crop.Apply",
            extra: [("mode", "save_in_place")]
        )
        defer { _trace.finish() }
        guard let path = activeImagePath else { throw CropError.noActiveImage }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        let format = outputFormatForSource(url: url)
        let result = try runPipeline(outputURL: url, format: format)
        lastSelection = rect
        return URL(fileURLWithPath: result.outputPath)
    }

    /// Returns the URL the user picked, or nil if they canceled.
    @discardableResult
    public func applySaveAs() throws -> URL? {
        let _trace = PerformanceLog.shared.start(
            "Crop.Apply",
            extra: [("mode", "save_as")]
        )
        defer { _trace.finish() }
        guard let path = activeImagePath else { throw CropError.noActiveImage }
        guard rect != nil else { throw CropError.noSelection }
        let sourceURL = URL(fileURLWithPath: AppPaths.expandTilde(path))
        let resolvedFormat = CropPipeline.resolveFormat(outputFormat, sourceURL: sourceURL)
        let ext = CropPipeline.defaultExtension(for: resolvedFormat, sourceURL: sourceURL)
        let base = sourceURL.deletingPathExtension().lastPathComponent

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base)_cropped.\(ext)"
        panel.allowedContentTypes = utTypes(for: resolvedFormat)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outURL = panel.url else { return nil }
        let result = try runPipeline(outputURL: outURL, format: resolvedFormat)
        lastSelection = rect
        return URL(fileURLWithPath: result.outputPath)
    }

    public func copyToClipboard() throws {
        let cg = try applyAndReplace()  // also pops up nothing — just runs the crop in memory
        let rep = NSBitmapImageRep(cgImage: cg)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            pb.setData(tiff, forType: .tiff)
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pb.writeObjects([img])
    }

    // MARK: - Pipeline helpers

    private func runPipeline(outputURL: URL, format: CropOutputFormat) throws -> CropPipeline.Result {
        guard let r = rect else { throw CropError.noSelection }
        guard let path = activeImagePath else { throw CropError.noActiveImage }
        let inputURL = URL(fileURLWithPath: AppPaths.expandTilde(path))
        let cleaned = CropMath.clip(snapToGrid ? CropMath.snapToIntegerPixels(r) : r, to: activeImageSize)
        let options = CropPipeline.Options(
            format: format,
            quality: outputQuality,
            preferLossless: preferLossless,
            preserveMetadata: preserveMetadata,
            stripGPS: stripGPS
        )
        return try CropPipeline.crop(
            inputURL: inputURL,
            rect: cleaned,
            outputURL: outputURL,
            options: options
        )
    }

    private func outputFormatForSource(url: URL) -> CropOutputFormat {
        CropPipeline.resolveFormat(outputFormat, sourceURL: url)
    }

    private func utTypes(for format: CropOutputFormat) -> [UTType] {
        switch format {
        case .auto, .png:  return [.png]
        case .jpeg: return [.jpeg]
        case .webp: return [.webP]
        case .heic: return [.heic]
        case .avif: return [UTType("public.avif") ?? .image]
        case .tiff: return [.tiff]
        }
    }
}
