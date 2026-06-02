import Foundation

// MARK: - View mode

/// The five view modes of the File List panel.
/// Spec: `docs/list_of_files.mdx` §2.
public enum FileListViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case strip
    case grid
    case details
    case tree
    case column

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .strip:   return "Strip"
        case .grid:    return "Grid"
        case .details: return "Details"
        case .tree:    return "Tree"
        case .column:  return "Column"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .strip:   return "rectangle.split.3x1"
        case .grid:    return "square.grid.3x3"
        case .details: return "list.bullet.rectangle"
        case .tree:    return "list.bullet.indent"
        case .column:  return "rectangle.split.3x1.fill"
        }
    }
}

// MARK: - Thumb size

/// Thumbnail size buckets used by Grid mode.
/// Spec §2.3.
public enum FileListThumbSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small   // 64 px
    case medium  // 128 px
    case large   // 256 px
    case xl      // 512 px

    public var id: String { rawValue }

    /// Max side, in pixels, fed to `kCGImageSourceThumbnailMaxPixelSize`.
    public var pixelSide: Int {
        switch self {
        case .small:  return 64
        case .medium: return 128
        case .large:  return 256
        case .xl:     return 512
        }
    }

    /// On-screen point side used for SwiftUI frames.
    /// Mirrors `pixelSide` but caps Strip at 96 pt (handled separately).
    public var pointSide: CGFloat {
        CGFloat(pixelSide)
    }

    public var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xl:     return "XL"
        }
    }

    /// Default thumb size for Strip mode (spec §2.2).
    public static let strip: FileListThumbSize = .medium

    /// Default thumb side for the 24 px row icon in Details / Tree.
    public static let detailsRowSide: CGFloat = 24
}

// MARK: - Sort

/// Sort field. Spec §5.1.
public enum FileListSortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case dateModified
    case dateTaken
    case size
    case dimensions
    case type
    case rating
    case random

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .dateTaken:    return "Date Taken"
        case .size:         return "Size"
        case .dimensions:   return "Dimensions"
        case .type:         return "Type"
        case .rating:       return "Rating"
        case .random:       return "Random"
        }
    }
}

public enum FileListSortDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case ascending, descending
    public var id: String { rawValue }

    public var label: String {
        self == .ascending ? "Ascending" : "Descending"
    }
}

/// User-visible sort selection. Persisted per panel instance.
public struct FileListSortDescriptor: Equatable, Codable, Sendable {
    public var field: FileListSortField
    public var direction: FileListSortDirection
    /// Stable seed for `.random` so re-renders stay stable across one scope load.
    public var randomSeed: UInt64

    public init(
        field: FileListSortField = .name,
        direction: FileListSortDirection = .ascending,
        randomSeed: UInt64 = 0x12345678
    ) {
        self.field = field
        self.direction = direction
        self.randomSeed = randomSeed
    }

    public static let `default` = FileListSortDescriptor()
}
