import Foundation

/// Color formats displayed by the in-canvas Color Picker overlay.
/// Spec §"Information & Metadata": Color Picker tool with **multiple
/// color formats**. Mirrors the formats upstream ImageGlass surfaces.
public enum ColorFormat: String, CaseIterable, Sendable, Codable {
    case hex
    case hexA
    case rgb
    case rgba
    case hsl
    case hsv
    case cmyk

    public var label: String {
        switch self {
        case .hex:  return "HEX"
        case .hexA: return "HEX with Alpha"
        case .rgb:  return "RGB"
        case .rgba: return "RGBA"
        case .hsl:  return "HSL"
        case .hsv:  return "HSV"
        case .cmyk: return "CMYK"
        }
    }
}

public enum ColorFormatting {

    public static func format(_ color: RGBA, as fmt: ColorFormat) -> String {
        switch fmt {
        case .hex:
            return String(format: "#%02X%02X%02X", color.r, color.g, color.b)
        case .hexA:
            return String(format: "#%02X%02X%02X%02X", color.r, color.g, color.b, color.a)
        case .rgb:
            return "rgb(\(color.r), \(color.g), \(color.b))"
        case .rgba:
            let a = (Double(color.a) / 255.0)
            return "rgba(\(color.r), \(color.g), \(color.b), \(roundedAlpha(a)))"
        case .hsl:
            let h = toHSL(color)
            return "hsl(\(Int(round(h.h))), \(Int(round(h.s * 100)))%, \(Int(round(h.l * 100)))%)"
        case .hsv:
            let v = toHSV(color)
            return "hsv(\(Int(round(v.h))), \(Int(round(v.s * 100)))%, \(Int(round(v.v * 100)))%)"
        case .cmyk:
            let c = toCMYK(color)
            return "cmyk(\(Int(round(c.c * 100)))%, \(Int(round(c.m * 100)))%, \(Int(round(c.y * 100)))%, \(Int(round(c.k * 100)))%)"
        }
    }

    private static func roundedAlpha(_ a: Double) -> String {
        // Two-decimal-place alpha so screenshots and screenshots-of-CSS match.
        return String(format: "%.2f", a)
    }

    // MARK: - Conversions

    /// Returns hue in [0, 360), saturation/lightness in [0, 1].
    public static func toHSL(_ c: RGBA) -> (h: Double, s: Double, l: Double) {
        let r = Double(c.r) / 255.0
        let g = Double(c.g) / 255.0
        let b = Double(c.b) / 255.0
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let l = (maxV + minV) / 2.0
        let delta = maxV - minV
        if delta == 0 { return (0, 0, l) }
        let s = l < 0.5 ? delta / (maxV + minV) : delta / (2 - maxV - minV)
        let h: Double
        switch maxV {
        case r: h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        case g: h = 60 * (((b - r) / delta) + 2)
        default: h = 60 * (((r - g) / delta) + 4)
        }
        let hue = h < 0 ? h + 360 : h
        return (hue, s, l)
    }

    /// Returns hue in [0, 360), saturation/value in [0, 1].
    public static func toHSV(_ c: RGBA) -> (h: Double, s: Double, v: Double) {
        let r = Double(c.r) / 255.0
        let g = Double(c.g) / 255.0
        let b = Double(c.b) / 255.0
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let v = maxV
        let s = maxV == 0 ? 0 : delta / maxV
        let h: Double
        if delta == 0 {
            h = 0
        } else {
            switch maxV {
            case r: h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            case g: h = 60 * (((b - r) / delta) + 2)
            default: h = 60 * (((r - g) / delta) + 4)
            }
        }
        let hue = h < 0 ? h + 360 : h
        return (hue, s, v)
    }

    public static func toCMYK(_ c: RGBA) -> (c: Double, m: Double, y: Double, k: Double) {
        let r = Double(c.r) / 255.0
        let g = Double(c.g) / 255.0
        let b = Double(c.b) / 255.0
        let k = 1 - max(r, g, b)
        guard k < 1 else { return (0, 0, 0, 1) }
        let cc = (1 - r - k) / (1 - k)
        let mm = (1 - g - k) / (1 - k)
        let yy = (1 - b - k) / (1 - k)
        return (cc, mm, yy, k)
    }
}
