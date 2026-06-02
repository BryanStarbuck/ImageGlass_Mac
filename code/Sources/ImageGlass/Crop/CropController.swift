import Foundation
import Observation
import CoreGraphics
import ImageIO
import AppKit
import ImageGlassCore

/// Live state of the Crop tool for one open image window.
///
/// Spec reference: `docs/crop.mdx` section 4.1. Holds the selection
/// rectangle (in source-image coordinates), aspect-ratio mode, modifier
/// keys, and grid/snap options. Mutations happen on the main actor only;
/// the SwiftUI panel binds to this object directly.
@MainActor
@Observable
public final class CropController {

    // MARK: Image being cropped

    /// Absolute path to the active image, if any.
    public var imagePath: String?
    /// Source pixel dimensions of the active image. (0, 0) means "no image."
    public var sourceWidth: Int = 0
    public var sourceHeight: Int = 0

    // MARK: Selection state

    /// Selection in *source image* coordinates. nil means "no selection."
    public var selection: CropRect?

    /// Active aspect-ratio constraint.
    public var aspectRatio: AspectRatio = .free

    /// Custom aspect ratio input (used when `aspectRatio == .custom`).
    public var customAspectW: Int = 16
    public var customAspectH: Int = 9

    public var lockAspect: Bool = false
    public var gridMode: GridMode = .thirds
    public var snapToPixel: Bool = true
    public var snapToEdges: Bool = false
    public var snapEdgeGravityPx: Int = 8
    public var persistAcrossImages: Bool = false
    public var losslessJPEGWhenPossible: Bool = true
    public var stripMetadataOnSave: Bool = false

    public var defaultSelection: DefaultSelectionType = .percent(0.5)

    // Live modifier-key state — pushed by the canvas view.
    public var shiftHeld: Bool = false   // forces 1:1
    public var optionHeld: Bool = false  // resize from center

    // Drag state machine.
    public enum Action: Equatable {
        case none
        case drawing
        case resizing(SelectionResizer.Kind)
        case moving
    }
    public var action: Action = .none

    /// MCU-rounded outline (dashed) — populated when the user has
    /// Lossless JPEG mode on and the rectangle isn't already aligned.
    public var mcuRoundedOutline: CropRect?

    /// Cached MCU info for the current JPEG (nil for non-JPEG inputs).
    private var jpegMCU: JPEGLosslessCrop.MCUInfo?

    // MARK: Init

    public init() {
        let cfg = CropConfigStore.load()
        applyConfig(cfg)
    }

    /// Refresh from on-disk crop.json.
    public func reloadConfig() {
        applyConfig(CropConfigStore.load())
    }

    private func applyConfig(_ cfg: CropConfig) {
        aspectRatio = cfg.aspectRatio
        if cfg.customAspect.count >= 2 {
            customAspectW = cfg.customAspect[0]
            customAspectH = cfg.customAspect[1]
        }
        lockAspect = cfg.lockAspect
        gridMode = cfg.gridMode
        snapToPixel = cfg.snapToPixel
        snapToEdges = cfg.snapToEdges
        snapEdgeGravityPx = cfg.snapEdgeGravityPx
        persistAcrossImages = cfg.persistAcrossImages
        losslessJPEGWhenPossible = cfg.losslessJPEGWhenPossible
        stripMetadataOnSave = cfg.stripMetadataOnSave
        defaultSelection = cfg.defaultSelection
    }

    /// Snapshot the current settings back to disk.
    public func saveConfig() {
        var cfg = CropConfigStore.load()
        cfg.aspectRatio = aspectRatio
        cfg.customAspect = [customAspectW, customAspectH]
        cfg.lockAspect = lockAspect
        cfg.gridMode = gridMode
        cfg.snapToPixel = snapToPixel
        cfg.snapToEdges = snapToEdges
        cfg.snapEdgeGravityPx = snapEdgeGravityPx
        cfg.persistAcrossImages = persistAcrossImages
        cfg.losslessJPEGWhenPossible = losslessJPEGWhenPossible
        cfg.stripMetadataOnSave = stripMetadataOnSave
        cfg.defaultSelection = defaultSelection
        if let sel = selection { cfg.lastUsedSelection = sel }
        try? CropConfigStore.save(cfg)
    }

    // MARK: - Image load

    /// Bind a new image. Resets or reinitializes the selection per the
    /// `defaultSelection` policy.
    public func loadImage(at path: String?) {
        guard let path, !path.isEmpty else {
            imagePath = nil
            sourceWidth = 0
            sourceHeight = 0
            selection = nil
            jpegMCU = nil
            mcuRoundedOutline = nil
            return
        }

        let expanded = AppPaths.expandTilde(path)
        imagePath = expanded
        if let dim = try? CropPipeline.readDimensions(of: expanded) {
            sourceWidth = dim.width
            sourceHeight = dim.height
        } else {
            sourceWidth = 0
            sourceHeight = 0
        }

        // Initialize the selection from the default policy.
        let lastUsed = CropConfigStore.load().lastUsedSelection
        selection = defaultSelection.resolve(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            lastUsed: lastUsed
        )

        loadMCUInfoIfJPEG(path: expanded)
        recomputeMCURounded()
    }

    private func loadMCUInfoIfJPEG(path: String) {
        jpegMCU = nil
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "jpg" || ext == "jpeg" else { return }
        // Read the first 65 KB — SOF markers are well within that on
        // virtually every real JPEG.
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 65_536)) ?? Data()
        jpegMCU = JPEGLosslessCrop.detectMCU(jpegData: header)
    }

    private func recomputeMCURounded() {
        guard let sel = selection,
              losslessJPEGWhenPossible,
              let mcu = jpegMCU,
              sourceWidth > 0, sourceHeight > 0 else {
            mcuRoundedOutline = nil
            return
        }
        if JPEGLosslessCrop.isAligned(sel, mcu: mcu, sourceWidth: sourceWidth, sourceHeight: sourceHeight) {
            mcuRoundedOutline = nil
        } else {
            mcuRoundedOutline = JPEGLosslessCrop.roundToMCU(sel, mcu: mcu, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
    }

    // MARK: - Selection mutations

    public func setSelection(_ rect: CropRect?) {
        if let r = rect {
            selection = clampAndSnap(r)
        } else {
            selection = nil
        }
        recomputeMCURounded()
        publishLiveSelection()
    }

    public func reset() {
        selection = nil
        mcuRoundedOutline = nil
        publishLiveSelection()
    }

    /// Nudge the selection by (dx, dy) source-pixels.
    public func nudge(dx: Int, dy: Int) {
        guard var s = selection else { return }
        s.x += dx
        s.y += dy
        setSelection(s)
    }

    /// Resize the selection by (dw, dh) source-pixels (anchored top-left).
    public func resizeBy(dw: Int, dh: Int) {
        guard var s = selection else { return }
        s.width = max(1, s.width + dw)
        s.height = max(1, s.height + dh)
        if lockAspect, let ratio = effectiveRatio() {
            let r = CropMath.lockRatio(width: s.width, height: s.height, ratioW: ratio.w, ratioH: ratio.h)
            s.width = r.w
            s.height = r.h
        }
        setSelection(s)
    }

    /// Editable numeric fields commit through this method.
    public func setNumeric(x: Int? = nil, y: Int? = nil, w: Int? = nil, h: Int? = nil) {
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        var s = selection ?? CropRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        if let x = x { s.x = x }
        if let y = y { s.y = y }
        if let w = w { s.width = max(1, w) }
        if let h = h { s.height = max(1, h) }
        if lockAspect, let ratio = effectiveRatio() {
            let r = CropMath.lockRatio(width: s.width, height: s.height, ratioW: ratio.w, ratioH: ratio.h)
            s.width = r.w
            s.height = r.h
        }
        setSelection(s)
    }

    /// One-tap preset: none, 25%, 50%, 66.66%, all.
    public func applyPreset(_ kind: PresetKind) {
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        switch kind {
        case .none:
            setSelection(nil)
        case .percent(let p):
            setSelection(CropRect.centered(percent: p, sourceWidth: sourceWidth, sourceHeight: sourceHeight))
        case .all:
            setSelection(CropRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }
    }

    public enum PresetKind: Equatable {
        case none
        case percent(Double)
        case all
    }

    // MARK: - Drag state machine

    /// Called when the user mouse-downs on the canvas at `imagePoint`
    /// (source-image coords).
    public func beginDraw(at imagePoint: CGPoint) {
        action = .drawing
        let start = CropRect(x: Int(imagePoint.x), y: Int(imagePoint.y), width: 1, height: 1)
        setSelection(start)
    }

    /// Called when the user drags from `start` to `current` (both in
    /// image coords) with `action == .drawing`.
    public func updateDraw(from start: CGPoint, to current: CGPoint) {
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)
        var rect = CropRect(x: Int(x), y: Int(y), width: max(1, Int(w)), height: max(1, Int(h)))
        // Shift forces square.
        if shiftHeld {
            let side = min(rect.width, rect.height)
            rect.width = side
            rect.height = side
        } else if lockAspect, let ratio = effectiveRatio() {
            let r = CropMath.lockRatio(width: rect.width, height: rect.height, ratioW: ratio.w, ratioH: ratio.h)
            rect.width = r.w
            rect.height = r.h
        }
        setSelection(rect)
    }

    public func endDrag() {
        action = .none
        // Persist last-used selection when in lastUsed/persistAcrossImages mode.
        if persistAcrossImages, let sel = selection {
            var cfg = CropConfigStore.load()
            cfg.lastUsedSelection = sel
            try? CropConfigStore.save(cfg)
        }
    }

    // MARK: - Apply crop (in-memory only — no disk write)

    /// Crop the on-screen image to the current selection. Returns the
    /// cropped `CGImage`; the caller is responsible for swapping it into
    /// the viewer and registering an undo step.
    @discardableResult
    public func applyCrop() throws -> CGImage {
        guard let sel = selection else {
            throw CropPipelineError.invalidRectangle("no selection")
        }
        guard let imagePath else {
            throw CropPipelineError.sourceNotFound("no image loaded")
        }
        // Re-decode from disk so we don't carry orientation-baked surprises.
        let url = URL(fileURLWithPath: imagePath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CropPipelineError.sourceUnreadable(imagePath)
        }
        return try CropPipeline.cropCGImage(cg, to: sel)
    }

    // MARK: - Save / Save-As / Copy

    public struct SaveOptions {
        public var outputURL: URL?
        public var format: OutputFormat
        public var quality: Double
        public var stripMetadata: Bool
        public init(
            outputURL: URL? = nil,
            format: OutputFormat = .auto,
            quality: Double = 0.92,
            stripMetadata: Bool = false
        ) {
            self.outputURL = outputURL
            self.format = format
            self.quality = quality
            self.stripMetadata = stripMetadata
        }
    }

    public func save(_ options: SaveOptions = SaveOptions()) throws -> CropResult {
        guard let sel = selection else { throw CropPipelineError.invalidRectangle("no selection") }
        guard let imagePath else { throw CropPipelineError.sourceNotFound("no image loaded") }

        let opts = CropOptions(
            format: options.format,
            quality: options.quality,
            losslessJPEG: losslessJPEGWhenPossible,
            stripMetadata: options.stripMetadata || stripMetadataOnSave,
            overwrite: true
        )
        return try CropPipeline.cropFile(
            inputPath: imagePath,
            rect: sel,
            outputPath: options.outputURL?.path,
            options: opts
        )
    }

    /// Crop, then push to the system pasteboard as TIFF + PNG.
    public func copyToPasteboard() throws {
        let cropped = try applyCrop()
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: cropped)
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
    }

    // MARK: - Helpers

    /// The numeric W:H ratio currently in force, or nil for `.free`.
    public func effectiveRatio() -> (w: Int, h: Int)? {
        switch aspectRatio {
        case .free:                       return nil
        case .custom:                     return (customAspectW, customAspectH)
        case .original:                   return (sourceWidth, sourceHeight)
        case .ratio(let w, let h):        return (w, h)
        }
    }

    /// Apply clamp + pixel snap + edge snap to a candidate rectangle.
    private func clampAndSnap(_ rect: CropRect) -> CropRect {
        var r = rect
        if snapToPixel {
            // Snap origin to integer (already integer); snap right/bottom too.
            // Nothing further needed since `CropRect` is already Int-typed.
        }
        if snapToEdges, sourceWidth > 0, sourceHeight > 0 {
            r.x = CropMath.snapToEdge(r.x, bound: sourceWidth, gravity: snapEdgeGravityPx)
            r.y = CropMath.snapToEdge(r.y, bound: sourceHeight, gravity: snapEdgeGravityPx)
            let right = r.x + r.width
            let bottom = r.y + r.height
            let snappedRight = CropMath.snapToEdge(right, bound: sourceWidth, gravity: snapEdgeGravityPx)
            let snappedBottom = CropMath.snapToEdge(bottom, bound: sourceHeight, gravity: snapEdgeGravityPx)
            r.width = max(1, snappedRight - r.x)
            r.height = max(1, snappedBottom - r.y)
        }
        if sourceWidth > 0, sourceHeight > 0 {
            r = r.clamped(toSourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
        return r
    }

    // MARK: - MCP plumbing

    /// Publish the current selection state to `crop-live.json` so the
    /// out-of-process MCP server can read it via `get_crop_selection`.
    public func publishLiveSelection() {
        let live = LiveCropSelection(
            imagePath: imagePath,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            selection: selection,
            aspectRatio: aspectRatio.description,
            apply: false,
            updatedAt: Date()
        )
        try? LiveCropSelection.save(live)
    }

    /// Pull the latest MCP-side `set_crop_selection` write and apply it.
    /// Returns true if the file's selection was applied.
    @discardableResult
    public func pullLiveSelectionFromDisk() -> Bool {
        guard let live = LiveCropSelection.load() else { return false }
        if let sel = live.selection {
            setSelection(sel)
            return true
        }
        return false
    }
}
