import Foundation
import CoreGraphics

// MARK: - Aspect Ratio

/// Aspect-ratio modes for the crop tool.
/// Mirrors upstream `SelectionAspectRatio` from `Enums.cs` (lines 157–171).
public enum AspectRatio: Equatable, Codable, Sendable, CustomStringConvertible {
    case free
    /// User-defined custom ratio (e.g. 16:9 entered manually).
    case custom(w: Int, h: Int)
    /// Resolved from the current source image's W:H.
    case original
    /// One of the named presets (1:1, 4:3, 16:9, ...).
    case ratio(w: Int, h: Int)

    /// Standard presets shown in the panel popup, in display order.
    public static let presets: [AspectRatio] = [
        .free,
        .custom(w: 16, h: 9),
        .original,
        .ratio(w: 1, h: 1),
        .ratio(w: 1, h: 2),
        .ratio(w: 2, h: 1),
        .ratio(w: 2, h: 3),
        .ratio(w: 3, h: 2),
        .ratio(w: 3, h: 4),
        .ratio(w: 4, h: 3),
        .ratio(w: 9, h: 16),
        .ratio(w: 16, h: 9),
    ]

    /// Resolves the numeric W:H ratio against the given source size.
    /// Returns nil for `.free` (no constraint) or invalid custom values.
    public func resolved(sourceWidth: Int, sourceHeight: Int) -> (w: Int, h: Int)? {
        switch self {
        case .free:
            return nil
        case .custom(let w, let h), .ratio(let w, let h):
            return (w > 0 && h > 0) ? (w, h) : nil
        case .original:
            return (sourceWidth > 0 && sourceHeight > 0) ? (sourceWidth, sourceHeight) : nil
        }
    }

    public var description: String {
        switch self {
        case .free:                    return "Free"
        case .custom(let w, let h):    return "Custom \(w):\(h)"
        case .original:                return "Original"
        case .ratio(let w, let h):     return "\(w):\(h)"
        }
    }

    // Codable

    private enum CodingKeys: String, CodingKey { case kind, w, h }
    private enum Kind: String, Codable { case free, custom, original, ratio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .free:     self = .free
        case .original: self = .original
        case .custom:
            self = .custom(
                w: try c.decode(Int.self, forKey: .w),
                h: try c.decode(Int.self, forKey: .h)
            )
        case .ratio:
            self = .ratio(
                w: try c.decode(Int.self, forKey: .w),
                h: try c.decode(Int.self, forKey: .h)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .free:
            try c.encode(Kind.free, forKey: .kind)
        case .original:
            try c.encode(Kind.original, forKey: .kind)
        case .custom(let w, let h):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
        case .ratio(let w, let h):
            try c.encode(Kind.ratio, forKey: .kind)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
        }
    }
}

// MARK: - Crop Rectangle

/// Integer-pixel crop rectangle in *source image* coordinates (top-left
/// origin). All math intentionally stays in `Int` so we never accidentally
/// drift between client space and image space.
public struct CropRect: Equatable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = Int(rect.origin.x.rounded())
        self.y = Int(rect.origin.y.rounded())
        self.width = Int(rect.size.width.rounded())
        self.height = Int(rect.size.height.rounded())
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var isValid: Bool { width > 0 && height > 0 }

    /// Clamp the rectangle so it fits inside `[0, 0] .. [sourceW, sourceH]`.
    /// Width/height shrink before x/y shift, matching the user's mental model
    /// when dragging from an off-image starting point.
    public func clamped(toSourceWidth sw: Int, sourceHeight sh: Int) -> CropRect {
        guard sw > 0 && sh > 0 else { return self }
        var r = self

        // Normalize negative widths (drag-up-and-left → still produces a rect).
        if r.width < 0 {
            r.x += r.width
            r.width = -r.width
        }
        if r.height < 0 {
            r.y += r.height
            r.height = -r.height
        }

        // Clip x and y to the image bounds.
        if r.x < 0 {
            r.width += r.x
            r.x = 0
        }
        if r.y < 0 {
            r.height += r.y
            r.y = 0
        }

        // Clip width/height so the right/bottom edges land on the image.
        if r.x + r.width > sw {
            r.width = sw - r.x
        }
        if r.y + r.height > sh {
            r.height = sh - r.y
        }

        // Final safety: never negative.
        r.width = max(0, r.width)
        r.height = max(0, r.height)
        return r
    }

    /// A centered rectangle covering `percent` (0.0 ... 1.0) of each axis.
    public static func centered(
        percent: Double,
        sourceWidth sw: Int,
        sourceHeight sh: Int
    ) -> CropRect {
        let p = max(0.0, min(1.0, percent))
        let w = Int((Double(sw) * p).rounded())
        let h = Int((Double(sh) * p).rounded())
        return CropRect(x: (sw - w) / 2, y: (sh - h) / 2, width: w, height: h)
    }

    /// A centered rectangle matching the given W:H ratio, scaled to fit
    /// inside the source.
    public static func centeredRatio(
        w ratioW: Int,
        h ratioH: Int,
        sourceWidth sw: Int,
        sourceHeight sh: Int
    ) -> CropRect {
        guard ratioW > 0, ratioH > 0, sw > 0, sh > 0 else {
            return CropRect(x: 0, y: 0, width: sw, height: sh)
        }
        // Scale to the largest rect with the ratio that fits inside [sw, sh].
        let sourceRatio = Double(sw) / Double(sh)
        let targetRatio = Double(ratioW) / Double(ratioH)
        let w: Int
        let h: Int
        if targetRatio > sourceRatio {
            // Width-limited.
            w = sw
            h = Int((Double(sw) / targetRatio).rounded())
        } else {
            // Height-limited.
            h = sh
            w = Int((Double(sh) * targetRatio).rounded())
        }
        return CropRect(x: (sw - w) / 2, y: (sh - h) / 2, width: w, height: h)
    }
}

// MARK: - Grid Mode

/// Composition grid options drawn inside the selection rectangle.
public enum GridMode: String, Codable, CaseIterable, Sendable {
    case none
    case thirds
    case goldenRatio
    case diagonals
    case grid8
}

// MARK: - Default Selection

/// How a fresh selection is initialized when an image loads.
/// Mirrors upstream `DefaultSelectionType` (`CropToolConfig.cs` lines 152–172).
public enum DefaultSelectionType: Equatable, Codable, Sendable {
    case none
    case lastUsed
    case percent(Double)
    case customRect(CropRect)

    private enum CodingKeys: String, CodingKey { case kind, value, rect }
    private enum Kind: String, Codable { case none, lastUsed, percent, customRect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:        self = .none
        case .lastUsed:    self = .lastUsed
        case .percent:
            let v = try c.decode(Double.self, forKey: .value)
            self = .percent(v)
        case .customRect:
            let r = try c.decode(CropRect.self, forKey: .rect)
            self = .customRect(r)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:               try c.encode(Kind.none, forKey: .kind)
        case .lastUsed:           try c.encode(Kind.lastUsed, forKey: .kind)
        case .percent(let v):
            try c.encode(Kind.percent, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .customRect(let r):
            try c.encode(Kind.customRect, forKey: .kind)
            try c.encode(r, forKey: .rect)
        }
    }

    /// Materialize this default into a concrete `CropRect` for an image.
    public func resolve(
        sourceWidth: Int,
        sourceHeight: Int,
        lastUsed: CropRect?
    ) -> CropRect? {
        switch self {
        case .none:
            return nil
        case .lastUsed:
            return lastUsed?.clamped(toSourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .percent(let p):
            return CropRect.centered(percent: p, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .customRect(let r):
            return r.clamped(toSourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
    }
}

// MARK: - Selection Resizer (eight-handle hit-test math)

/// Hit-region info for the eight selection handles. Mirrors upstream
/// `SelectionResizerType` (`ViewerCanvas.cs` lines 443–454).
public struct SelectionResizer: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Z-order priority for hit testing — corners over edges, matches
        /// upstream priority BR → TL → BL → TR → R → B → L → T.
        public var hitPriority: Int {
            switch self {
            case .bottomRight: return 0
            case .topLeft:     return 1
            case .bottomLeft:  return 2
            case .topRight:    return 3
            case .right:       return 4
            case .bottom:      return 5
            case .left:        return 6
            case .top:         return 7
            }
        }
    }

    public let kind: Kind
    /// Visible handle region (small dot) in client space.
    public let indicatorRect: CGRect
    /// Larger hit-test region (≈ 1.3× the indicator) in client space.
    public let hitRect: CGRect

    /// Resizer size from upstream config (`CropToolConfig` default 12pt).
    /// Hit size is `resizerSize * 1.3`.
    public static let defaultResizerSize: CGFloat = 12.0
    public static let hitFactor: CGFloat = 1.3

    /// Build the eight resizers around a rectangle in client space.
    /// `tooSmallFactor` matches upstream auto-hide threshold:
    /// edge handles disappear when the rect side is shorter than 5× the
    /// indicator (upstream lines 1875–1883).
    public static func eight(
        around rect: CGRect,
        resizerSize: CGFloat = defaultResizerSize,
        tooSmallFactor: CGFloat = 5.0
    ) -> [SelectionResizer] {
        let s = resizerSize
        let h = s * hitFactor
        let halfS = s / 2.0
        let halfH = h / 2.0

        let cx = rect.midX
        let cy = rect.midY
        let l = rect.minX
        let r = rect.maxX
        let t = rect.minY
        let b = rect.maxY

        func ind(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - halfS, y: y - halfS, width: s, height: s)
        }
        func hit(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - halfH, y: y - halfH, width: h, height: h)
        }

        var out: [SelectionResizer] = [
            .init(kind: .topLeft,     indicatorRect: ind(l, t), hitRect: hit(l, t)),
            .init(kind: .topRight,    indicatorRect: ind(r, t), hitRect: hit(r, t)),
            .init(kind: .bottomLeft,  indicatorRect: ind(l, b), hitRect: hit(l, b)),
            .init(kind: .bottomRight, indicatorRect: ind(r, b), hitRect: hit(r, b)),
        ]

        // Edge midpoints — only emitted when the rect side is long enough.
        let minSide = s * tooSmallFactor
        if rect.width >= minSide {
            out.append(.init(kind: .top,    indicatorRect: ind(cx, t), hitRect: hit(cx, t)))
            out.append(.init(kind: .bottom, indicatorRect: ind(cx, b), hitRect: hit(cx, b)))
        }
        if rect.height >= minSide {
            out.append(.init(kind: .left,  indicatorRect: ind(l, cy), hitRect: hit(l, cy)))
            out.append(.init(kind: .right, indicatorRect: ind(r, cy), hitRect: hit(r, cy)))
        }
        return out
    }

    /// Return the first resizer whose hit rect contains `point`, picking by
    /// `Kind.hitPriority` when multiple match.
    public static func hitTest(_ resizers: [SelectionResizer], at point: CGPoint) -> SelectionResizer? {
        let hits = resizers.filter { $0.hitRect.contains(point) }
        return hits.min { $0.kind.hitPriority < $1.kind.hitPriority }
    }
}

// MARK: - Aspect Lock helpers

public enum CropMath {
    /// Constrain a candidate W,H so it matches a target aspect ratio.
    /// `axis` decides which dimension we trust: `.horizontal` keeps width
    /// (and recomputes height), `.vertical` keeps height. `.either` keeps
    /// whichever side is larger relative to the ratio.
    public enum LockAxis { case horizontal, vertical, either }

    public static func lockRatio(
        width: Int,
        height: Int,
        ratioW: Int,
        ratioH: Int,
        axis: LockAxis = .either
    ) -> (w: Int, h: Int) {
        guard ratioW > 0, ratioH > 0 else { return (max(0, width), max(0, height)) }
        let w = max(0, width)
        let h = max(0, height)
        let r = Double(ratioW) / Double(ratioH)

        let lockHoriz: Bool = {
            switch axis {
            case .horizontal: return true
            case .vertical:   return false
            case .either:
                // Pick the axis that requires shrinking the *other* side.
                // i.e. prefer keeping the larger side.
                let hFromW = Double(w) / r
                let wFromH = Double(h) * r
                return abs(Double(h) - hFromW) <= abs(Double(w) - wFromH)
            }
        }()

        if lockHoriz {
            return (w, max(1, Int((Double(w) / r).rounded())))
        } else {
            return (max(1, Int((Double(h) * r).rounded())), h)
        }
    }

    /// Snap a value to the nearest multiple of `step`.
    public static func snap(_ v: Int, to step: Int) -> Int {
        guard step > 1 else { return v }
        let rem = v % step
        if rem == 0 { return v }
        let half = step / 2
        return rem >= half ? v + (step - rem) : v - rem
    }

    /// Snap an edge to the image bound when within `gravity` pixels.
    public static func snapToEdge(_ value: Int, bound: Int, gravity: Int) -> Int {
        if value < gravity { return 0 }
        if abs(bound - value) <= gravity { return bound }
        return value
    }
}
