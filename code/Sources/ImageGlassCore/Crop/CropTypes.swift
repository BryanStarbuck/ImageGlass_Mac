import Foundation

/// Aspect-ratio presets for the crop selection. Names mirror upstream
/// `SelectionAspectRatio` (`Source/Components/ImageGlass.Base/Types/Enums.cs:157`)
/// so settings, MCP arguments, and on-disk side-files round-trip with
/// the Windows build.
public enum SelectionAspectRatio: String, Codable, CaseIterable, Sendable {
    case freeRatio   = "FreeRatio"
    case original    = "Original"
    case custom      = "Custom"
    case ratio1_1    = "Ratio1_1"
    case ratio1_2    = "Ratio1_2"
    case ratio2_1    = "Ratio2_1"
    case ratio2_3    = "Ratio2_3"
    case ratio3_2    = "Ratio3_2"
    case ratio3_4    = "Ratio3_4"
    case ratio4_3    = "Ratio4_3"
    case ratio9_16   = "Ratio9_16"
    case ratio16_9   = "Ratio16_9"

    /// (w, h) ratio components. `freeRatio` and `original` and `custom`
    /// return `nil` (the controller substitutes the image's or the
    /// custom-field aspect at apply time).
    public var components: (w: Int, h: Int)? {
        switch self {
        case .freeRatio, .original, .custom: return nil
        case .ratio1_1:  return (1, 1)
        case .ratio1_2:  return (1, 2)
        case .ratio2_1:  return (2, 1)
        case .ratio2_3:  return (2, 3)
        case .ratio3_2:  return (3, 2)
        case .ratio3_4:  return (3, 4)
        case .ratio4_3:  return (4, 3)
        case .ratio9_16: return (9, 16)
        case .ratio16_9: return (16, 9)
        }
    }

    public var displayName: String {
        switch self {
        case .freeRatio: return "Free"
        case .original:  return "Original"
        case .custom:    return "Custom"
        case .ratio1_1:  return "1:1"
        case .ratio1_2:  return "1:2"
        case .ratio2_1:  return "2:1"
        case .ratio2_3:  return "2:3"
        case .ratio3_2:  return "3:2"
        case .ratio3_4:  return "3:4"
        case .ratio4_3:  return "4:3"
        case .ratio9_16: return "9:16"
        case .ratio16_9: return "16:9"
        }
    }
}

/// Grid overlay drawn inside the selection. Five modes, matching upstream
/// crop tool (`docs/crop.mdx §2.2`).
public enum CropGridMode: String, Codable, CaseIterable, Sendable {
    case none
    case thirds
    case goldenRatio
    case goldenSpiralDiagonals
    case grid8

    /// Next mode in cycle for the `G` keypress (`docs/crop.mdx §2.4`).
    public var next: CropGridMode {
        let all = CropGridMode.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// Output writer selection. `auto` lets the pipeline pick the source
/// format; explicit values force re-encode. See `docs/crop.mdx §4.2`.
public enum CropOutputFormat: String, Codable, CaseIterable, Sendable {
    case auto
    case jpeg
    case png
    case webp
    case heic
    case avif
    case tiff
}

/// Initial-selection policy (`docs/crop.mdx §3`).
public enum CropInitSelectionType: String, Codable, CaseIterable, Sendable {
    case useLastSelection
    case customArea
    case selectAll
    case selectNone
    case select10Percent
    case select20Percent
    case select25Percent
    case select30Percent
    case selectOneThird
    case select40Percent
    case select50Percent
    case select60Percent
    case selectTwoThirds
    case select70Percent
    case select75Percent
    case select80Percent
    case select90Percent

    /// Returns the implied centered fraction (e.g. 0.5 for `select50Percent`)
    /// or `nil` for non-percent modes.
    public var percentFraction: Double? {
        switch self {
        case .select10Percent: return 0.10
        case .select20Percent: return 0.20
        case .select25Percent: return 0.25
        case .select30Percent: return 0.30
        case .selectOneThird:  return 1.0 / 3.0
        case .select40Percent: return 0.40
        case .select50Percent: return 0.50
        case .select60Percent: return 0.60
        case .selectTwoThirds: return 2.0 / 3.0
        case .select70Percent: return 0.70
        case .select75Percent: return 0.75
        case .select80Percent: return 0.80
        case .select90Percent: return 0.90
        default: return nil
        }
    }
}

/// UI display unit for the X/Y/W/H number fields. Internal state stays
/// in pixels (`docs/crop.mdx §2.3`).
public enum CropUnits: String, Codable, CaseIterable, Sendable {
    case pixels
    case percent
}

/// Which of the eight resize handles is being dragged. The four edge
/// handles let the user constrain one axis; the four corners let aspect
/// ratio constraints reshape both axes.
public enum CropHandle: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
}

/// High-level drag state (`docs/crop.mdx §2.6`).
public enum CropDragState: String, Codable, Sendable {
    case idle
    case drawing
    case moving
    case resizing
}
