import Foundation
import UniformTypeIdentifiers

/// Whether an SVG document is animated (SMIL / CSS / scripted) or static.
public enum SVGKind: String, Sendable, Hashable {
    case animated
    case `static`
}

/// SVG-level detection helpers — kind, viewBox, script-presence.
///
/// All detection works on string scans of the file contents. We
/// deliberately do **not** run a full XML parse — the goal is fast
/// dispatch before either renderer (WKWebView or NSImage) decides what
/// to do (docs/svg.mdx §3.6).
public enum SVGDetection {

    /// Maximum file size we will attempt to scan in-memory. SVGs above
    /// this size are conservatively classified as `.animated` so they
    /// route through the full WebKit renderer.
    public static let scanSizeLimit: Int = 8 * 1024 * 1024  // 8 MB

    /// Substrings that indicate an animated SVG. Case-insensitive match.
    /// Includes SMIL elements, CSS animation declarations, and any
    /// `<script>` tag — anything with a script element is treated as
    /// potentially animated since a script can mutate the DOM at runtime.
    public static let animatedNeedles: [String] = [
        "<animate", "<animatetransform", "<animatemotion",
        "<set ", "<set/>", "<set>",
        "@keyframes", "animation:", "animation-name:",
        "transition:", "<script"
    ]

    /// Detect static vs. animated by scanning the file.
    public static func detectKind(at url: URL) -> SVGKind {
        let _trace = PerformanceLog.shared.start(
            "SVG.Detect",
            extra: [("path", url.path)]
        )
        defer { _trace.finish() }
        guard let data = try? Data(contentsOf: url) else { return .animated }
        return detectKind(data: data)
    }

    public static func detectKind(data: Data) -> SVGKind {
        if data.count > scanSizeLimit { return .animated }
        guard let string = String(data: data, encoding: .utf8) else {
            // Try the lenient ASCII fallback — SVGs are required to be
            // UTF-8 but some tooling emits Latin-1.
            guard let lenient = String(data: data, encoding: .isoLatin1) else {
                return .animated
            }
            return detectKind(string: lenient)
        }
        return detectKind(string: string)
    }

    public static func detectKind(string: String) -> SVGKind {
        let lower = string.lowercased()
        for needle in animatedNeedles {
            if lower.contains(needle) { return .animated }
        }
        return .static
    }

    /// Whether the file contains any `<script>` element — used to decide
    /// whether the per-file "Allow Scripts" banner needs to appear before
    /// JS is turned on for the WKWebView.
    public static func containsScript(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.lowercased().contains("<script")
    }

    /// Parse a viewBox from the root `<svg>` element. Returns `nil` when
    /// no viewBox is present (the SVG is sized by its explicit width /
    /// height attributes instead). Useful for `svg_viewbox_zoom`
    /// (docs/svg.mdx §8) and for the "Zoom to ViewBox" menu item.
    public static func viewBox(in string: String) -> CGRect? {
        // Locate the SVG root tag.
        guard let svgRange = string.range(
                of: "<svg",
                options: [.caseInsensitive, .literal]) else {
            return nil
        }
        let after = string[svgRange.upperBound...]
        guard let endOfTag = after.firstIndex(of: ">") else { return nil }
        let attrs = after[..<endOfTag]
        // Extract the viewBox="x y w h" attribute value.
        guard let vbRange = attrs.range(
                of: "viewBox",
                options: [.caseInsensitive, .literal]) else { return nil }
        let rest = attrs[vbRange.upperBound...]
        guard let openQuote = rest.firstIndex(where: { $0 == "\"" || $0 == "'" })
        else { return nil }
        let quoteChar = rest[openQuote]
        let afterQuote = rest[rest.index(after: openQuote)...]
        guard let closeQuote = afterQuote.firstIndex(of: quoteChar) else {
            return nil
        }
        let valueStr = String(afterQuote[..<closeQuote])
        let parts = valueStr
            .components(separatedBy: CharacterSet(charactersIn: " ,"))
            .compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1],
                      width: parts[2], height: parts[3])
    }
}
