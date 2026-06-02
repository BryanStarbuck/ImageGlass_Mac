import SwiftUI
import AppKit
import ImageGlassCore

/// Minimal viewer — AppKit `NSImageView` wrapped for SwiftUI.
/// macOS Image I/O handles JPEG / PNG / HEIC / GIF / TIFF / WebP / BMP / SVG
/// natively without third-party deps. Broader format support (RAW, JXL via
/// ImageMagick) is a future task.
struct ImageViewer: View {
    let filePath: String?

    var body: some View {
        Group {
            if let filePath, !filePath.isEmpty {
                ImageHostingView(filePath: AppPaths.expandTilde(filePath))
            } else {
                ContentUnavailableView(
                    "No image selected",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Pick a file from the panel on the left.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct ImageHostingView: NSViewRepresentable {
    let filePath: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.animates = true
        view.allowsCutCopyPaste = false
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let image = NSImage(contentsOfFile: filePath)
        nsView.image = image
        nsView.toolTip = filePath
    }
}
