import Foundation
import CoreGraphics

/// Color channel isolation. The pixel transform is pure math that can be unit
/// tested without an image context. The Viewer subsystem applies the same
/// transform via a CIColorMatrix filter on the GPU.
public enum ColorChannel: String, CaseIterable, Sendable, Codable {
    case all
    case red
    case green
    case blue
    case alpha

    public var label: String {
        switch self {
        case .all:   return "All channels"
        case .red:   return "Red only"
        case .green: return "Green only"
        case .blue:  return "Blue only"
        case .alpha: return "Alpha as gray"
        }
    }
}

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public enum ColorChannelMath {

    /// Apply channel isolation to a single 8-bit RGBA pixel.
    /// - `.all`   pass-through.
    /// - `.red`   show R on the red channel, zero out G and B.
    /// - `.green` show G on the green channel, zero out R and B.
    /// - `.blue`  show B on the blue channel, zero out R and G.
    /// - `.alpha` render the alpha channel as gray, fully opaque.
    public static func apply(_ channel: ColorChannel, to pixel: RGBA) -> RGBA {
        switch channel {
        case .all:
            return pixel
        case .red:
            return RGBA(r: pixel.r, g: 0, b: 0, a: pixel.a)
        case .green:
            return RGBA(r: 0, g: pixel.g, b: 0, a: pixel.a)
        case .blue:
            return RGBA(r: 0, g: 0, b: pixel.b, a: pixel.a)
        case .alpha:
            return RGBA(r: pixel.a, g: pixel.a, b: pixel.a, a: 255)
        }
    }

    /// The 4x5 color matrix used by Core Image's `CIColorMatrix` filter.
    /// Returned as four RGBA vectors (R-out, G-out, B-out, A-out) plus bias.
    /// Each vector reads as (r-coeff, g-coeff, b-coeff, a-coeff).
    public static func ciColorMatrix(_ channel: ColorChannel)
        -> (rVec: (CGFloat, CGFloat, CGFloat, CGFloat),
            gVec: (CGFloat, CGFloat, CGFloat, CGFloat),
            bVec: (CGFloat, CGFloat, CGFloat, CGFloat),
            aVec: (CGFloat, CGFloat, CGFloat, CGFloat),
            bias: (CGFloat, CGFloat, CGFloat, CGFloat))
    {
        switch channel {
        case .all:
            return ((1,0,0,0), (0,1,0,0), (0,0,1,0), (0,0,0,1), (0,0,0,0))
        case .red:
            return ((1,0,0,0), (0,0,0,0), (0,0,0,0), (0,0,0,1), (0,0,0,0))
        case .green:
            return ((0,0,0,0), (0,1,0,0), (0,0,0,0), (0,0,0,1), (0,0,0,0))
        case .blue:
            return ((0,0,0,0), (0,0,0,0), (0,0,1,0), (0,0,0,1), (0,0,0,0))
        case .alpha:
            // Map alpha into RGB as a grayscale visualization.
            return ((0,0,0,1), (0,0,0,1), (0,0,0,1), (0,0,0,0), (0,0,0,1))
        }
    }
}
