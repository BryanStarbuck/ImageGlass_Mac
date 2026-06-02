import SwiftUI
import AppKit
import ImageIO
import ImageGlassCore

/// Floating overlay with the displayed image's dimensions, file size,
/// and format / UTI. Toggle via `ViewerState.showInfoOverlay`.
struct ImageInfoOverlay: View {
    let filePath: String?
    var frameCount: Int = 1
    var currentFrameIndex: Int = 0
    var isAnimated: Bool = false

    var body: some View {
        if let filePath, let info = ImageInfo.load(path: filePath) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                HStack(spacing: 10) {
                    Text("\(info.width) x \(info.height)")
                    Text(info.formatLabel)
                    Text(info.sizeLabel)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                if frameCount > 1 {
                    Text(frameLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .padding(10)
        }
    }

    private var frameLine: String {
        let kind = isAnimated ? "animation" : "frames"
        return "\(kind): \(currentFrameIndex + 1) / \(frameCount)"
    }
}

struct ImageInfo {
    var name: String
    var width: Int
    var height: Int
    var byteSize: UInt64
    var formatLabel: String

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    static func load(path: String) -> ImageInfo? {
        let expanded = AppPaths.expandTilde(path)
        let url = URL(fileURLWithPath: expanded)
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else { return nil }

        let attrs: [FileAttributeKey: Any]?
        do {
            attrs = try fm.attributesOfItem(atPath: expanded)
        } catch {
            ErrorLog.log("attributesOfItem failed for \(expanded)",
                         error: error,
                         class: "ImageInfo")
            attrs = nil
        }
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        var width = 0, height = 0
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            width  = (props[kCGImagePropertyPixelWidth]  as? Int) ?? 0
            height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        } else {
            ErrorLog.log("CGImageSourceCreateWithURL / property read failed for \(url.path)",
                         class: "ImageInfo")
        }

        let ext = url.pathExtension.uppercased()
        let format = ext.isEmpty ? "unknown" : ext

        return ImageInfo(
            name: url.lastPathComponent,
            width: width,
            height: height,
            byteSize: size,
            formatLabel: format
        )
    }
}
